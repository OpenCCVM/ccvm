# mkCcvm: turn a ccvm configuration into the `ccvm` host wrapper package.
#
# It evaluates the guest NixOS system (guest/default.nix) and extracts the four boot
# artifacts the wrapper needs — kernel, initrd, a read-only squashfs of the system
# closure, and the kernel cmdline — then bakes their store paths (plus the scalar
# config) into wrapper/ccvm.sh. The workspace 9p share and SSH port are NOT baked: they
# are only known at launch time, so the wrapper constructs those QEMU args at runtime
# (this is the microvm.nix runtime-share trap; see docs/design.md §3.8).
#
# Called from both the flake (standalone `nix run`) and the home-manager module, always
# with the caller's own `pkgs`, so guest and host stay on one nixpkgs.
{ pkgs }:
let
  lib = pkgs.lib;

  defaults = {
    package = pkgs.claude-code;
    autoUpdateFiles = true;
    memory = 4096;
    cores = 4;
    extraPackages = [ ];
    mountHostNixStore = false;
    apiKeyVariable = "ANTHROPIC_API_KEY";
    shareHostConfig = true;
    extraGuestModules = [ ];
  };
in
userConfig:
let
  config = defaults // userConfig;
  system = pkgs.stdenv.hostPlatform.system;

  guestSystem = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      ../guest/default.nix
      {
        nixpkgs.pkgs = pkgs;
        ccvm = {
          inherit (config) apiKeyVariable extraPackages
            shareHostConfig mountHostNixStore;
          claudePackage = config.package;
        };
      }
    ]
    ++ config.extraGuestModules;
  };

  gc = guestSystem.config;
  toplevel = gc.system.build.toplevel;
  kernel = "${gc.system.build.kernel}/${gc.system.boot.loader.kernelFile}";
  initrd = "${gc.system.build.initialRamdisk}/${gc.system.boot.loader.initrdFile}";

  # The full system closure as a read-only squashfs. Its root holds the store paths by
  # basename, so it mounts directly at /nix/store in the guest. zstd decompresses fast,
  # which matters for boot time.
  storeImage = pkgs.callPackage "${pkgs.path}/nixos/lib/make-squashfs.nix" {
    storeContents = [ toplevel ];
    comp = "zstd -Xcompression-level 6";
    fileName = "ccvm-store";
  };

  # Kernel cmdline for direct boot. init= points into the (now mounted) read-only store.
  append = lib.concatStringsSep " " (gc.boot.kernelParams ++ [ "init=${toplevel}/init" ]);

  wrapper = pkgs.writeShellApplication {
    name = "ccvm";
    runtimeInputs = with pkgs; [ qemu coreutils openssh gawk gnugrep ];
    text = builtins.replaceStrings
      [
        "@KERNEL@"
        "@INITRD@"
        "@STOREIMG@"
        "@APPEND@"
        "@MEMORY@"
        "@CORES@"
        "@MODE@"
        "@APIKEYVAR@"
        "@SHARECONFIG@"
        "@MOUNTHOSTSTORE@"
        "@HOSTSTOREPATH@"
      ]
      [
        kernel
        initrd
        "${storeImage}"
        append
        (toString config.memory)
        (toString config.cores)
        (if config.autoUpdateFiles then "rw" else "overlay")
        config.apiKeyVariable
        (if config.shareHostConfig then "1" else "0")
        (if config.mountHostNixStore then "1" else "0")
        (builtins.storeDir)
      ]
      (builtins.readFile ../wrapper/ccvm.sh);
  };
in
{
  inherit wrapper guestSystem toplevel storeImage append kernel initrd config;
  kernelParams = gc.boot.kernelParams;
}
