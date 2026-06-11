# The ccvm guest: a minimal, fast-booting, fully ephemeral NixOS system.
#
# Root is a tmpfs (writable, RAM-backed, discarded on power-off); /nix/store is a
# read-only squashfs image attached as a virtio-blk device. Nothing the guest does
# survives a shutdown — there is no persistent disk anywhere (see CLAUDE.md).
#
# This module is evaluated by lib/mkccvm.nix, which extracts the kernel, initrd,
# store image and toplevel and boots them with a runtime-constructed QEMU command
# line (the workspace share and SSH port are only known at `ccvm` launch time, so
# they cannot be declared here — see the microvm.nix runtime-share trap, CLAUDE.md).
{ config, lib, pkgs, ... }:
let
  cfg = config.ccvm;

  # INITRD oneshot (nix.enable only): back the writable /nix/store overlay UPPER (/nix/.rw-store) with
  # the opt-in vmDiskSize encrypted disk instead of tmpfs, so a multi-GB `nix develop` doesn't OOM
  # guest RAM. It must run in the INITRD because /nix/store is neededForBoot — the overlay and its
  # upper are assembled before switch-root, so the post-boot seed service (which LUKS-es the disk
  # for /scratch) runs far too late. Strategy: mount-stacking + fail-open. The declarative tmpfs
  # /nix/.rw-store mounts first (we order After it via RequiresMountsFor); then IF the disk is
  # present we LUKS-format/open/mkfs it and mount it OVER that tmpfs, so the overlay's upperdir lands
  # on disk. Absent disk or ANY failure leaves the tmpfs upper (RAM) untouched — boot never bricks.
  # The LUKS key is generated in initrd /run (tmpfs RAM), never on 9p (host sees only ciphertext,
  # host sees only ciphertext), and shredded right after open. A marker in /run — which systemd preserves across
  # switch-root — tells the post-boot seed service the disk is already open, so it shares the SAME
  # pool for /scratch (binds a subdir) rather than reformatting. pbkdf2 keeps luksFormat fast (the
  # key is already 64 random bytes; a memory-hard KDF would only slow the initrd for no gain).
  storeDiskScript = pkgs.writeShellScript "ccvm-store-disk-setup" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.cryptsetup pkgs.e2fsprogs config.systemd.package ]}:$PATH
    target=/sysroot/nix/.rw-store
    log() { echo "ccvm-store-disk: $*" >&2; }

    # The initrd explicitly waits only for the STORE disk (vda, a declared fileSystem); our scratch
    # disk (vdb, serial=ccvm-scratch) is undeclared, so its /dev/disk/by-id symlink may still be
    # settling when we run. Let udev finish before probing. (udevadm is the sole reason
    # config.systemd.package is on PATH above — there is no narrower provider in nixpkgs, and systemd
    # is already in the initrd so it costs no extra closure. It's best-effort anyway: the find_dev
    # retry loop below is the real safety net if the settle is unavailable or times out.)
    udevadm settle --timeout=10 2>/dev/null || true

    # Prefer the stable by-id symlink; fall back to scanning /sys/block/*/serial (kernel-provided,
    # not udev — so it's there as soon as virtio_blk has probed the device).
    find_dev() {
      [ -e /dev/disk/by-id/virtio-ccvm-scratch ] && { echo /dev/disk/by-id/virtio-ccvm-scratch; return 0; }
      for b in /sys/block/*; do
        [ -r "$b/serial" ] || continue
        [ "$(cat "$b/serial" 2>/dev/null)" = ccvm-scratch ] && { echo "/dev/$(basename "$b")"; return 0; }
      done
      return 1
    }

    dev=""
    for _ in $(seq 1 50); do dev="$(find_dev)" && [ -n "$dev" ] && break; dev=""; sleep 0.1; done
    if [ -z "$dev" ]; then
      log "no vmDiskSize disk found after probe; /nix/.rw-store stays tmpfs (RAM). by-id=[$(ls /dev/disk/by-id 2>/dev/null | tr '\n' ' ')]"
      exit 0
    fi

    mkdir -p "$target"
    keyf=/run/ccvm-store-disk.key   # initrd /run = tmpfs (RAM); never on 9p, gone at power-off
    ( umask 077; dd if=/dev/urandom of="$keyf" bs=64 count=1 status=none )
    if cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
         --pbkdf-force-iterations 1000 "$dev" "$keyf" \
       && cryptsetup open --type luks2 --key-file "$keyf" "$dev" ccvm-scratch; then
      shred -u "$keyf" 2>/dev/null || rm -f "$keyf"
      if mkfs.ext4 -q -F -E nodiscard /dev/mapper/ccvm-scratch \
         && mount /dev/mapper/ccvm-scratch "$target"; then
        # Pre-create the overlay upper/work dirs (+ a scratch subdir the post-boot service binds to
        # /scratch) ON the disk, so the overlay assembles its upper on disk, not the shadowed tmpfs.
        mkdir -p "$target/store" "$target/work" "$target/scratch"
        : >/run/ccvm-store-on-disk   # survives switch-root → post-boot service shares this pool
        log "SUCCESS: /nix/.rw-store backed by encrypted disk $dev"
      else
        log "mkfs/mount failed; /nix/.rw-store stays tmpfs (RAM)"
        cryptsetup close ccvm-scratch 2>/dev/null || true
      fi
    else
      log "LUKS setup failed (cryptsetup non-zero — crypto module missing in initrd?); /nix/.rw-store stays tmpfs (RAM)"
      rm -f "$keyf"
    fi
    exit 0   # ALWAYS fail-open: never fail the unit, never block boot
  '';
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
    agentSudo = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the agent user (ccvm) gets passwordless root (wheel + sudo) in the guest. The host
        wrapper RESOLVES this from the user-facing tri-state (lib/mkccvm.nix): on by default for
        DevEx, off when an egress allowlist is set so a (prompt-injected) agent cannot flush the
        in-guest egress firewall. Off removes ccvm from wheel and disables sudo entirely; the root
        systemd units (seed setup, firewall install) run regardless and are unaffected.
      '';
    };
    # NOTE: host-config sharing is driven entirely by the wrapper + the `seed/share-claude-config`
    # flag (read by launcher.nix), NOT by a guest option — so there is deliberately no
    # `shareClaudeConfig` option here. The host-side default lives in lib/mkccvm.nix and is
    # baked into the wrapper as @SHARECLAUDE@.
    # Internal build-time nix config. The user-facing home-manager surface (programs.ccvm.nix.*)
    # nests the same way and maps straight onto these — one name end to end (see lib/mkccvm.nix).
    nix = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable in-VM nix: a writable /nix/store overlay (read-only store image as the lower, a
          tmpfs upper) plus nix.enable, so `nix develop`/`nix build` work inside the guest. The
          upper is RAM (tmpfs) by default; combine with vmDiskSize > 0 and the initrd backs the
          upper with the encrypted disk instead (fail-open to tmpfs), so a multi-GB closure does
          not OOM guest RAM.
        '';
      };
      substituters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra binary caches (substituter URLs) for in-VM nix, appended to cache.nixos.org. Only
          meaningful with nix.enable. Pure guest-closure config (no mount); paths must verify against
          trustedPublicKeys. Passed through the nested `nix` attr by mkccvm.
        '';
      };
      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Public keys verifying paths from `substituters` (name:base64key). Appended to nixpkgs' built-in keys.";
      };
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
    ]
    # nix.enable only: device-mapper + dm-crypt + the LUKS cipher modules + ext4, so the initrd can
    # LUKS-open AND mount the encrypted vmDiskSize disk as the /nix/store overlay upper
    # (storeDiskScript). cryptoModules is NixOS's own arch-appropriate set (aes/xts/sha/…), the same
    # list the luks module uses; ext4 pulls its deps (jbd2/mbcache/crc32c) via the module closure —
    # the default initrd only carries squashfs/overlay/9p, so without this `mount` reports "unknown
    # filesystem type 'ext4'". Gated so the default (RAM-only) initrd stays lean. The post-boot
    # /scratch path (vmDiskSize without nix.enable) uses the running-system modules below instead.
    ++ lib.optionals cfg.nix.enable ([ "dm_mod" "dm_crypt" "ext4" ] ++ config.boot.initrd.luks.cryptoModules);
    boot.initrd.kernelModules = [ "virtio_pci" "virtio_mmio" "virtio_blk" ]
      ++ lib.optionals cfg.nix.enable ([ "dm_mod" "dm_crypt" "ext4" ] ++ config.boot.initrd.luks.cryptoModules);
    boot.initrd.checkJournalingFS = false;

    # device-mapper + dm-crypt for the opt-in encrypted disk pool (vmDiskSize). Loaded in the
    # running system because the post-boot seed service (guest/launcher.nix) LUKS-formats the disk
    # for /scratch when nix.enable is OFF; harmless when vmDiskSize is off. (When nix.enable is on, the
    # INITRD owns the disk instead — see storeDiskScript / boot.initrd above.) The aes/xts/sha
    # crypto the cipher needs is auto-loaded by the kernel crypto API when dm-crypt requests xts(aes).
    boot.kernelModules = [ "dm_mod" "dm_crypt" ];

    # nix.enable only: pull the disk-backing initrd oneshot + its tools (cryptsetup, mkfs.ext4) into
    # the initrd, and order it AFTER the declarative tmpfs /nix/.rw-store mount (RequiresMountsFor)
    # but BEFORE the /nix/store overlay assembles (sysroot-nix-store.mount). See storeDiskScript for
    # the mount-stacking + fail-open rationale. wantedBy initrd.target so it's pulled into the boot
    # transaction; it always exits 0, so even a total disk failure can't block boot.
    # List the packages explicitly (not just the script): storePaths copies each listed path's
    # closure, so cryptsetup/mkfs.ext4 + their libs land in the initrd. Referencing them only via
    # the script's PATH is NOT enough — the script's transitive refs aren't pulled into the initrd,
    # so cryptsetup would be "command not found" (ENOENT on exec) at LUKS-format time.
    boot.initrd.systemd.storePaths = lib.optionals cfg.nix.enable [
      storeDiskScript
      pkgs.cryptsetup
      pkgs.e2fsprogs
    ];
    boot.initrd.systemd.services.ccvm-store-disk = lib.mkIf cfg.nix.enable {
      description = "Back the /nix/store overlay upper with the encrypted vmDiskSize disk (fail-open to tmpfs)";
      wantedBy = [ "initrd.target" ];
      before = [ "sysroot-nix-store.mount" "initrd-fs.target" ];
      unitConfig = {
        DefaultDependencies = false;
        # Resolve + order-After the tmpfs /nix/.rw-store mount unit WITHOUT hardcoding its escaped
        # name (sysroot-nix-.rw\x2dstore.mount) — RequiresMountsFor takes the path and lets systemd
        # find the unit. We mount the disk OVER that tmpfs, so the tmpfs must be mounted first.
        RequiresMountsFor = "/sysroot/nix/.rw-store";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Mirror diagnostics to the console (the script logs to stderr): the initrd journal isn't
        # reliably handed to the running system's journal, so the console — which CCVM_DEBUG streams
        # and the wrapper dumps on a boot timeout — is where a fail-open reason is actually visible.
        StandardError = "journal+console";
        ExecStart = "${storeDiskScript}";
      };
    };

    # Direct kernel boot has no bootloader to supply a cmdline, so the wrapper passes
    # these (plus init=<toplevel>/init) via QEMU -append. Serial console = ttyS0, which
    # QEMU's microvm machine exposes via isa-serial and q35 via the 16550 UART.
    boot.kernelParams = [
      # Serial console differs by arch: 16550/isa-serial (ttyS0) on x86, PL011 (ttyAMA0)
      # on the aarch64 `virt` machine. A wrong value only loses the debug log, not boot.
      (if pkgs.stdenv.hostPlatform.isAarch64 then "console=ttyAMA0" else "console=ttyS0")
    ];

    # Filesystems: tmpfs root (RAM, discarded on power-off) + the read-only system closure. The
    # closure is always a self-contained squashfs on the first virtio-blk disk (max isolation —
    # nothing of the host store is exposed). With nix.enable it becomes the overlay LOWER (at
    # /nix/.ro-store) under a writable /nix/store; without it (the lean default) it is /nix/store
    # directly, ro.
    fileSystems =
      let
        roStore = {
          device = "/dev/vda";
          fsType = "squashfs";
          options = [ "ro" ];
          neededForBoot = true;
        };
        # No size cap on root => defaults to 50% of VM RAM.
        rootFs."/" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=0755" ];
          neededForBoot = true;
        };
        storeFs =
          if cfg.nix.enable then {
            # Writable store: ro lower + writable upper, overlaid at /nix/store. The overlay is set
            # up in the initrd (store is neededForBoot). The upper (/nix/.rw-store) is tmpfs (RAM) by
            # default; when vmDiskSize > 0 the initrd's ccvm-store-disk service mounts the encrypted
            # disk OVER this tmpfs (fail-open) so the upper lands on disk — the overlay config here is
            # IDENTICAL either way (only what's mounted at /nix/.rw-store changes). nix realises new
            # paths into the upper; wiped on exit. Off by default — this branch only exists when nix.enable is on.
            "/nix/.ro-store" = roStore;
            "/nix/.rw-store" = {
              device = "tmpfs";
              fsType = "tmpfs";
              options = [ "mode=0755" ];
              neededForBoot = true;
            };
            "/nix/store" = {
              overlay = {
                lowerdir = [ "/nix/.ro-store" ];
                upperdir = "/nix/.rw-store/store";
                workdir = "/nix/.rw-store/work";
              };
              neededForBoot = true;
            };
          } else {
            "/nix/store" = roStore;
          };
      in
      rootFs // storeFs;
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
    # User: ccvm (baked uid 1000). 9p passthrough (security_model=none) is numeric,
    # so for a host user whose uid != 1000 the seed service remaps this user to the
    # host id at boot (Before=sshd) — see guest/launcher.nix. zsh with vi-mode.
    ##########################################################################
    users.mutableUsers = false;
    # Authentication is supplied at runtime via the seed (authorized_keys), not declared
    # here, so the lockout guard would fire a false positive.
    users.allowNoPasswordLogin = true;
    users.users.ccvm = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
      # wheel (→ passwordless sudo) only when agentSudo is on. Dropped under egress hardening so a
      # prompt-injected agent can't `nft flush` the in-guest egress firewall (guest/launcher.nix).
      extraGroups = lib.optional cfg.agentSudo "wheel";
      shell = pkgs.zsh;
    };
    # Lock root explicitly. mutableUsers=false already leaves root password-less (→ locked), but be
    # unambiguous: no interactive root login and no `su -`/`su root` path anywhere (verified: su to
    # root returns an authentication failure). The privileged work runs from root systemd units, not
    # an interactive root shell.
    users.users.root.hashedPassword = "!";
    # Ephemeral VM: passwordless sudo is fine and helps debugging in --shell mode — but it also lets
    # a root agent flush the egress firewall, so agentSudo=false (auto when egressAllowlist is set)
    # disables sudo outright. Use sudo-rs (the memory-safe Rust sudo) instead of classic C sudo, and
    # restrict invocation to the wheel group (execWheelOnly). mkDefault on enable so an extraGuestModule
    # can still re-enable it if a workflow genuinely needs in-guest sudo.
    security.sudo.enable = false;
    security.sudo-rs = {
      enable = lib.mkDefault cfg.agentSudo;
      wheelNeedsPassword = false;
      execWheelOnly = true;
    };

    ##########################################################################
    # Guest kernel hardening. Cheap, in-guest defense-in-depth against an agent
    # probing the kernel — none of it touches the host or the boot-critical path.
    ##########################################################################
    # Block replacing the running kernel image (kexec) + hibernation. The guest never kexecs or
    # hibernates. NB: this does NOT lock module loading, so the seed service's runtime modprobe
    # (nf_tables/nf_conntrack for egress, dm_crypt for the standalone /scratch) still works — we
    # deliberately do not set security.lockKernelModules, which would break those.
    security.protectKernelImage = true;
    # Unprivileged user namespaces stay ENABLED on purpose: the nix build sandbox needs them, and the
    # namespaced-root they grant can neither reach the init-netns egress firewall nor route packets
    # out (a fresh netns has no uplink) — verified during the audit. The sysctls below are pure wins.
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2; # hide kernel pointers from the agent (/proc/kallsyms etc.)
      "kernel.dmesg_restrict" = 1; # only root reads the kernel ring buffer
      "kernel.unprivileged_bpf_disabled" = 1; # no unprivileged BPF (the agent needs none)
      "net.core.bpf_jit_harden" = 2; # harden the BPF JIT against spraying
      "net.ipv4.conf.all.rp_filter" = 1; # strict reverse-path filter (anti-spoof; single-NIC NAT guest)
    };

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
        # Terminal fidelity: ssh forwards the client's $TERM (e.g. xterm-kitty, xterm-ghostty,
        # foot, wezterm), but the guest only ships ncurses' built-in terminfo (xterm-256color,
        # screen, tmux, linux, …). A forwarded TERM the guest can't resolve leaves zsh's ZLE
        # unable to drive the terminal — the visible line desyncs from the edit buffer (backspace
        # corrupts, cursor jumps). Ship the common emulators' own terminfo so the forwarded $TERM
        # resolves. (Replaces `environment.enableAllTerminfo`, which broke in recent nixpkgs.)
        # terminfo outputs are tiny — negligible closure/boot cost.
        alacritty.terminfo
        foot.terminfo
        ghostty.terminfo
        kitty.terminfo
        wezterm.terminfo

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
    # Mutable nix only when nix.enable is on (writable /nix/store overlay above). Off by default —
    # the store is read-only, so the channel/daemon machinery is skipped and the closure stays lean.
    nix.enable = cfg.nix.enable;
    nix.settings = lib.mkIf cfg.nix.enable {
      experimental-features = [ "nix-command" "flakes" ]; # `nix develop`/`nix build` on flakes
      # Who may talk to the nix-daemon at all (request builds). Only root and the agent are nix
      # clients in this guest, so pin the set rather than leaving it the permissive default `*`.
      allowed-users = [ "root" "ccvm" ];
      # SECURITY (audit S-1) — a Nix *trusted-user* is root-EQUIVALENT: it can set post-build-hook,
      # disable the build sandbox, or add unsigned substituters, all of which the root daemon honours
      # (a post-build-hook runs AS ROOT). So make the agent trusted ONLY when it already has root via
      # sudo (agentSudo on). When agentSudo is dropped (auto under egressAllowlist) the agent must NOT
      # be trusted — otherwise it could regain root through the daemon and `nft flush` the in-guest
      # egress firewall, silently defeating the exact mitigation the sudo-drop exists for. A
      # NON-trusted agent can still `nix build`/`nix develop` (builds run as the nixbld users); it
      # just can't override these trusted-only settings. The complete fix remains host-side egress
      # enforcement (see CLAUDE.md, "Egress"); this keeps the in-guest mitigation actually binding.
      # mkForce makes this list authoritative: nixpkgs' own nix module also defines
      # `trusted-users = [ "root" ]` at equal priority, which otherwise CONCATENATES (rendering a
      # harmless-but-confusing `root root`). Forcing it both deduplicates and guarantees no
      # transitive module can silently slip an extra trusted (root-equivalent) user past this gate.
      trusted-users = lib.mkForce ([ "root" ] ++ lib.optional cfg.agentSudo "ccvm");
      # Extra binary caches (nix.substituters / nix.trustedPublicKeys). Appended to the defaults
      # (cache.nixos.org + nixpkgs' keys), reached over HTTP at network speed — a substituter is
      # HTTP substitution, not a mount, so this needs no 9p share and exposes nothing of the host.
      # Empty lists are a no-op. require-sigs stays ON: paths must verify against the trusted keys.
      extra-substituters = cfg.nix.substituters;
      extra-trusted-substituters = cfg.nix.substituters;
      extra-trusted-public-keys = cfg.nix.trustedPublicKeys;
    };
  };
}
