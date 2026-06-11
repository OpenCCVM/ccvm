{
  description = "ccvm — run Claude Code in a throw-away microVM with zero setup";

  inputs = {
    # nixos-unstable: claude-code is unfree and moves fast.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true; # claude-code is unfree
      };

      # Default-config ccvm build products for each system (wrapper + guest artifacts).
      partsAll = forAllSystems (system:
        (import ./lib/mkccvm.nix { pkgs = pkgsFor system; }) { });
    in
    {
      # `nix run github:jx-wi/ccvm` works standalone; defaults mirror native claude
      # (live host edits + shared host config), with isolation available opt-in.
      packages = forAllSystems (system: {
        ccvm = partsAll.${system}.wrapper;
        default = partsAll.${system}.wrapper;
        # Buildable guest artifacts, honestly typed as packages (derivations). The non-derivation
        # bring-up handles (kernel cmdline `append`, the evaluated `guestSystem` config) are
        # deliberately NOT flake outputs — introspect them with a direct `import ./lib/mkccvm.nix`
        # (recipe in CLAUDE.md, "Build / test / debug"), which keeps every output correctly typed.
        guest-store = partsAll.${system}.storeImage;  # ro squashfs /nix/store image
        guest-toplevel = partsAll.${system}.toplevel; # full guest system closure
      });

      apps = forAllSystems (system:
        let
          # `meta` on an app silences the `nix flake check` "lacks attribute 'meta'" warning
          # and gives `nix run`/search a description. Reuse the wrapper's package meta.
          app = {
            type = "app";
            program = "${partsAll.${system}.wrapper}/bin/ccvm";
            meta = partsAll.${system}.meta;
          };
        in
        {
          default = app;
          ccvm = app;
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [ qemu openssh shellcheck nixpkgs-fmt ];
          };
        });

      # `nix flake check` builds the guest image, shellchecks the wrapper (via
      # writeShellApplication), and runs the host-side guarantee tests (secret hygiene,
      # config staging, verbatim argv, mode selection) against the real wrapper script
      # driven by its dry-run hook — see tests/.
      checks = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          guest-image = partsAll.${system}.storeImage;
          wrapper = partsAll.${system}.wrapper;
        } // (import ./tests { inherit pkgs; }));

      # The home-manager module that exposes programs.ccvm.* and installs `ccvm`. Exposed as
      # `homeModules` (NOT the older `homeManagerModules`): stock Nix recognizes `homeModules` as a
      # flake output, so `nix flake check` stays warning-free, whereas `homeManagerModules` triggers
      # an "unknown flake output" warning. Consume as `ccvm.homeModules.default`. (nixvim made the
      # same move; it only keeps a `homeManagerModules` alias — and thus the warning — for its
      # existing users, which ccvm has none of, so there is nothing to alias.)
      homeModules.default = import ./modules/home-manager.nix;
      homeModules.ccvm = self.homeModules.default;
    };
}
