{
  description = "ccvm — run Claude Code in a completely ephemeral microVM with zero setup";

  inputs = {
    # Pinned to the STABLE release: the guest closure no longer needs unstable to track
    # claude-code (that now comes from the claude-code input below), so we trade churn for
    # the reproducibility/stability of a release channel.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # claude-code: the community nix-claude-code flake, which packages the latest claude-code
    # independently of the nixpkgs channel and stays current. Its `overlays.default` sets
    # `pkgs.claude-code`, so every existing `pkgs.claude-code` reference picks it up. Follows
    # our nixpkgs so it adds no second nixpkgs to the closure.
    claude-code = {
      url = "github:ryoppippi/nix-claude-code";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # treefmt-nix: one `nix fmt` entrypoint + a `nix flake check` formatting gate. Pinned to
    # follow our nixpkgs so it pulls no second nixpkgs into the closure.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      claude-code,
      treefmt-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true; # claude-code is unfree
          # `pkgs.claude-code` -> the community nix-claude-code build (latest, follows our nixpkgs).
          overlays = [ claude-code.overlays.default ];
        };

      # Default-config ccvm build products for each system (wrapper + guest artifacts).
      partsAll = forAllSystems (system: (import ./lib/mkccvm.nix { pkgs = pkgsFor system; }) { });

      # treefmt eval per system: nixfmt (Nix) + shfmt (wrapper & test shell scripts). Drives
      # both the `formatter` output (`nix fmt`) and the `checks.formatting` CI gate.
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule (pkgsFor system) ./treefmt.nix);

      # The mdBook documentation site (docs/). Pure Nix — no Node/Bun/npm — so the site is
      # byte-reproducible from a commit. Built with the mdbook-linkcheck2 backend, configured in
      # docs/book.toml as `[output.linkcheck2] warning-policy = "error"`, so a dead INTERNAL link
      # fails the build (and therefore `checks.docs`). External links are not followed — the build
      # sandbox has no network. The HTML lands at `<dest>/html`, which we copy to the derivation
      # root so `result/index.html` is the site entrypoint (the Pages workflow uploads it directly).
      docsFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.runCommand "ccvm-docs"
          {
            nativeBuildInputs = [
              pkgs.mdbook
              pkgs.mdbook-linkcheck2
            ];
            # mdbook-linkcheck2 eagerly builds an HTTPS client at startup and panics ("No CA
            # certificates were loaded") if none are present — even with `follow-web-links = false`,
            # so it never actually makes a request. Point it at a CA bundle to satisfy the builder.
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          }
          ''
            cp -r ${./docs} ./docs
            chmod -R u+w ./docs
            mdbook build ./docs -d "$PWD/build"
            cp -r "$PWD/build/html" "$out"
          '';
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
        guest-store = partsAll.${system}.storeImage; # ro squashfs /nix/store image
        guest-toplevel = partsAll.${system}.toplevel; # full guest system closure
        docs = docsFor system; # the mdBook documentation site (GitHub Pages artifact)
      });

      apps = forAllSystems (
        system:
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
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              qemu
              openssh
              shellcheck
              nixfmt
              mdbook # build/serve the docs site (`mdbook serve docs`)
              mdbook-linkcheck2 # internal-link checker backend used by `nix build .#docs`
            ];
          };
        }
      );

      # `nix fmt` formats the tree (nixfmt + shfmt); the same config gates CI as
      # `checks.formatting`, so running `nix flake check` catches unformatted files too.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # `nix flake check` builds the guest image, shellchecks the wrapper (via
      # writeShellApplication), and runs the host-side guarantee tests (secret hygiene,
      # config staging, verbatim argv, mode selection) against the real wrapper script
      # driven by its dry-run hook — see tests/.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          guest-image = partsAll.${system}.storeImage;
          wrapper = partsAll.${system}.wrapper;
          formatting = treefmtEval.${system}.config.build.check self;
          docs = docsFor system; # builds the site; fails on dead internal links (linkcheck2)
        }
        // (import ./tests { inherit pkgs; })
      );

      # The home-manager module that exposes programs.ccvm.* and installs `ccvm`. Exposed as
      # `homeModules` (NOT the older `homeManagerModules`): stock Nix recognizes `homeModules` as a
      # flake output, so `nix flake check` stays warning-free, whereas `homeManagerModules` triggers
      # an "unknown flake output" warning. Consume as `ccvm.homeModules.default`. (nixvim made the
      # same move; it only keeps a `homeManagerModules` alias — and thus the warning — for its
      # existing users, which ccvm has none of, so there is nothing to alias.)
      # Passed the claude-code input so the module can apply its overlay to the consumer's own
      # pkgs (a home-manager user's nixpkgs has no view of our inputs otherwise) — keeping the
      # standalone and home-manager paths on the same community claude-code build.
      homeModules.default = import ./modules/home-manager.nix { inherit claude-code; };
      homeModules.ccvm = self.homeModules.default;
    };
}
