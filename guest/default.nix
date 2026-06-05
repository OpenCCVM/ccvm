# The ccvm guest: a minimal, fast-booting, fully ephemeral NixOS system.
#
# Root is a tmpfs (writable, RAM-backed, discarded on power-off); /nix/store is a
# read-only squashfs image attached as a virtio-blk device. Nothing the guest does
# survives a shutdown — there is no persistent disk anywhere (see docs/design.md).
#
# This module is evaluated by lib/mkccvm.nix, which extracts the kernel, initrd,
# store image and toplevel and boots them with a runtime-constructed QEMU command
# line (the workspace share and SSH port are only known at `ccvm` launch time, so
# they cannot be declared here — see the microvm.nix runtime-share trap, design.md).
{ config, lib, pkgs, ... }:
let
  cfg = config.ccvm;
in
{
  imports = [
    ./sshd.nix
    ./launcher.nix
  ];

  options.ccvm = {
    apiKeyVariable = lib.mkOption {
      type = lib.types.str;
      default = "ANTHROPIC_API_KEY";
      description = "Env var name carrying the Anthropic API key (sshd AcceptEnv).";
    };
    claudePackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.claude-code;
      description = "claude-code package to install in the guest (null omits it, for boot tests).";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available inside the guest.";
    };
    shareHostConfig = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Share the host's ~/.claude config read-only (reuse host login, settings, commands, memory).";
    };
    mountHostNixStore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Share the host /nix/store read-only instead of a self-contained image.";
    };
  };

  config = {
    system.stateVersion = "25.11";

    ##########################################################################
    # Boot: direct kernel boot, no bootloader. tmpfs root + ro squashfs store.
    ##########################################################################
    boot.loader.grub.enable = false;
    # systemd-initrd (the scripted initrd is deprecated, slated for removal in 26.11). It
    # mounts the tmpfs root + read-only squashfs /nix/store from generated units; the module
    # list below makes the virtio transports and squashfs/overlay available in the initrd.
    boot.initrd.systemd.enable = true;

    boot.initrd.availableKernelModules = [
      "virtio_pci" # q35 transport
      "virtio_mmio" # microvm transport
      "virtio_blk" # the store image drive
      "virtio_net"
      "virtio_console"
      "9p"
      "9pnet_virtio" # seed + workspace shares
      "squashfs"
      "overlay"
      "erofs"
    ];
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_mmio" "virtio_blk" ];
    boot.initrd.checkJournalingFS = false;

    # Direct kernel boot has no bootloader to supply a cmdline, so the wrapper passes
    # these (plus init=<toplevel>/init) via QEMU -append. Serial console = ttyS0, which
    # QEMU's microvm machine exposes via isa-serial and q35 via the 16550 UART.
    boot.kernelParams = [ "console=ttyS0" ];

    # Root in RAM; discarded on power-off. No size cap => defaults to 50% of VM RAM.
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
      neededForBoot = true;
    };
    # The whole system closure, read-only. Either a self-contained squashfs on the first
    # virtio-blk disk (default, max isolation) or the host store shared over 9p.
    fileSystems."/nix/store" =
      if cfg.mountHostNixStore then {
        device = "ccvm-nixstore";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "msize=1048576" "access=any" "ro" "cache=loose" ];
        neededForBoot = true;
      } else {
        device = "/dev/vda";
        fsType = "squashfs";
        options = [ "ro" ];
        neededForBoot = true;
      };
    boot.tmp.useTmpfs = true;

    ##########################################################################
    # Networking: slirp serves DHCP (10.0.2.x). networkd, no firewall (NAT'd).
    ##########################################################################
    networking.hostName = "ccvm";
    networking.useDHCP = false;
    networking.useNetworkd = true;
    systemd.network.enable = true;
    systemd.network.networks."10-lan" = {
      matchConfig.Type = "ether";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      # Bring it up fast; we don't need to block boot waiting on a lease beyond this.
      linkConfig.RequiredForOnline = "no";
    };
    services.resolved.enable = true;
    networking.firewall.enable = false;

    ##########################################################################
    # User: ccvm (uid 1000, matches a typical host user so 9p uid-passthrough
    # lets the agent write the workspace in rw mode). zsh with vi-mode.
    ##########################################################################
    users.mutableUsers = false;
    # Authentication is supplied at runtime via the seed (authorized_keys), not declared
    # here, so the lockout guard would fire a false positive.
    users.allowNoPasswordLogin = true;
    users.users.ccvm = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
      extraGroups = [ "wheel" ];
      shell = pkgs.zsh;
    };
    # Ephemeral VM: passwordless sudo is fine and helps debugging in --shell mode.
    security.sudo.wheelNeedsPassword = false;

    programs.zsh = {
      enable = true;
      # Minimal vi-mode so the debug shell demonstrates full terminal fidelity.
      interactiveShellInit = ''
        bindkey -v
        export KEYTIMEOUT=1
        bindkey -M vicmd 'k' up-line-or-history
        bindkey -M vicmd 'j' down-line-or-history
      '';
      promptInit = ''
        PROMPT='%F{cyan}ccvm%f:%F{blue}%~%f %# '
      '';
    };

    # zsh runs the interactive `zsh-newuser-install` wizard whenever the user has no
    # startup files; on our ephemeral tmpfs home that fires on every --shell launch and
    # blocks on a menu. A present (if minimal) ~/.zshrc is the canonical suppression. The
    # real interactive config still comes from the global /etc/zshrc (programs.zsh above).
    systemd.tmpfiles.rules = [
      "d /home/ccvm 0700 ccvm users -"
      "f /home/ccvm/.zshrc 0644 ccvm users - #ccvm:intentionally-minimal,see-/etc/zshrc"
    ];

    ##########################################################################
    # Packages: a sensible base toolchain + claude-code + user extras.
    # nodejs is intentionally omitted: the nixpkgs claude-code wraps its own
    # node runtime, so adding it here would double-include it.
    ##########################################################################
    environment.systemPackages =
      (with pkgs; [
        git
        openssh
        ripgrep
        fd
        jq
        curl
        cacert
        coreutils
        gnugrep
        gnused
        gnutar
        gzip
        which
        less
        vim
      ])
      ++ lib.optional (cfg.claudePackage != null) cfg.claudePackage
      ++ cfg.extraPackages;

    # HTTPS to api.anthropic.com et al.
    security.pki.certificateFiles = [ "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];

    ##########################################################################
    # Fast teardown + lean closure (boot speed is a feature).
    ##########################################################################
    systemd.settings.Manager.DefaultTimeoutStopSec = "5s";
    documentation.enable = false;
    documentation.man.enable = false;
    documentation.nixos.enable = false;
    services.udisks2.enable = false;
    # No mutable nix in the guest (store is read-only); skip the channel machinery.
    nix.enable = false;
  };
}
