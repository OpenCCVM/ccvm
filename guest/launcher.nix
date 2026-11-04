/*
  SPDX-License-Identifier: MIT
  Copyright (C) 2026 Jaxxen
*/

# Guest-side runtime glue, all driven by the read-only "seed" 9p share the host
# wrapper populates per invocation (/run/ccvm-seed):
#
#   * ccvm-seed.service  — a boot oneshot (root) that mounts the seed, installs the
#     SSH host key + authorized_keys, and mounts the workspace per mode. Doing every
#     privileged mount here (ordered Before=sshd) means the ForceCommand launcher can
#     run completely unprivileged: it only cd's and exec's.
#
#   * ccvm-guest-launch  — the sshd ForceCommand. Reads the seed, cd's to the
#     workspace, and exec's either zsh (debug) or claude with the forwarded args.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ccvm;

  # 9p mount options shared by every share. We request msize=1 MiB; QEMU's virtio-9p negotiates
  # this DOWN (to ~512 KB in practice — verify with `grep msize /proc/mounts`), but it still keeps
  # 9p throughput tolerable for editing source trees. access=any + security_model=none on the host
  # side means host uids pass straight through (uid 1000 host == ccvm in the guest).
  # nosuid,nodev: defense in depth on every host-shared tree — the guest must never honour a
  # setuid bit or device node coming off 9p. (noexec is deliberately NOT set: the workspace has to
  # run project binaries / build scripts, and a shared ~/.claude may carry executable hooks/skills.)
  p9 = "trans=virtio,version=9p2000.L,msize=1048576,access=any,nosuid,nodev";

  claudeBin = if cfg.claudePackage != null then "${cfg.claudePackage}/bin/claude" else "claude";

  launcher = pkgs.writeShellApplication {
    name = "ccvm-guest-launch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.zsh
    ];
    text = ''
      seed=/run/ccvm-seed

      # Where the host CWD lives, mirrored at the identical absolute path (mounted by
      # ccvm-seed.service). Fall back to home so a misconfigured boot still lands somewhere.
      workdir="$(cat "$seed/workdir" 2>/dev/null || true)"
      [ -n "$workdir" ] && [ -d "$workdir" ] || workdir="$HOME"
      cd "$workdir"

      # Debug fidelity shell instead of claude.
      if [ "$(cat "$seed/shell" 2>/dev/null || echo 0)" = "1" ]; then
        # Non-interactive escape hatch: if the client sent a remote command (ssh host 'cmd'),
        # run it under a login shell rather than the interactive TUI. Gated on debug shell
        # mode, so normal claude launches can never be diverted into arbitrary command exec.
        if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ]; then
          exec zsh -lc "$SSH_ORIGINAL_COMMAND"
        fi
        exec zsh -l
      fi

      # Reconstruct the forwarded argv. NUL-separated on the wire so spaces/quotes/globs
      # survive intact — never rebuilt by string-splitting.
      args=()
      if [ -f "$seed/claude-args" ]; then
        mapfile -t -d "" args < "$seed/claude-args"
      fi

      # NB: Ctrl+Z freezes the session and there is no guest-side fix — Claude Code reads Ctrl+Z
      # in raw mode and raises SIGSTOP on ITSELF (the Windows port crashes "Unknown signal:
      # SIGSTOP"), and SIGSTOP is uncatchable/unignorable, so neither `stty susp undef` nor
      # `trap "" TSTP` here has any effect (both were tried, removed). See CLAUDE.md gotcha.

      # The API key arrived over the encrypted SSH channel (SendEnv -> AcceptEnv) and is
      # already in our environment here; it is never read from the seed or any file.
      # No flags are injected — claude gets exactly the forwarded argv. The VM is the
      # safety boundary, so --dangerously-skip-permissions is yours to opt into via
      # `ccvm --dangerously-skip-permissions`, not something ccvm forces on you.
      exec ${claudeBin} "''${args[@]}"
    '';
  };

  seedSetup = pkgs.writeShellApplication {
    name = "ccvm-seed-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.shadow
      pkgs.gnugrep
      pkgs.nftables
      pkgs.kmod
      pkgs.cryptsetup
      pkgs.e2fsprogs
      config.systemd.package
    ];
    text = ''
      seed=/run/ccvm-seed
      mkdir -p "$seed"

      # No seed share attached (e.g. a bare debug boot)? Leave a usable system and bail
      # cleanly so the serial console still reaches a login.
      if ! mountpoint -q "$seed"; then
        mount -t 9p -o ${p9},ro ccvm-seed "$seed" 2>/dev/null || {
          echo "ccvm-seed: no seed share; skipping (debug boot)"; exit 0;
        }
      fi

      # SSH identity: copy to tmpfs with strict perms (sshd refuses group/world-readable
      # host keys, and the 9p uid mapping is not guaranteed to satisfy StrictModes).
      install -D -m 600 "$seed/ssh_host_ed25519_key"     /etc/ssh/ssh_host_ed25519_key
      install -D -m 644 "$seed/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub
      install -D -m 644 -o root -g root "$seed/authorized_keys" /etc/ccvm/authorized_keys

      # Match the agent user (ccvm, baked uid 1000) to the *host* user's uid/gid so 9p
      # passthrough (security_model=none) gives correct ownership in rw mode. Without this a
      # host user whose uid != 1000 sees the workspace owned by a foreign uid — the agent
      # can't write its own project, and files it creates land on the host owned by 1000.
      # The ids are non-secret integers from the read-only seed (the wrapper wrote `id -u`/
      # `id -g`). Done BEFORE the workspace/config setup and Before=sshd, so every later
      # `chown ccvm`/`-o ccvm` and the login session pick up the remapped ids. Best-effort
      # and fail-open: a hiccup must NOT fail the oneshot and block sshd — we keep uid 1000.
      # usermod is safe here (no ccvm process exists yet; sshd hasn't started). `-o` permits
      # a non-unique id (this ephemeral guest has no conflicting accounts to protect).
      host_uid="$(cat "$seed/host-uid" 2>/dev/null || true)"
      host_gid="$(cat "$seed/host-gid" 2>/dev/null || true)"
      if printf '%s' "$host_uid" | grep -qxE '[0-9]+' && [ "$host_uid" != 0 ]; then
        if printf '%s' "$host_gid" | grep -qxE '[0-9]+' && [ "$host_gid" != 0 ] \
           && [ "$host_gid" != "$(id -g ccvm)" ]; then
          groupmod -o -g "$host_gid" users || true
        fi
        if [ "$host_uid" != "$(id -u ccvm)" ]; then
          usermod -o -u "$host_uid" ccvm || true
          # systemd-tmpfiles created /home/ccvm as the old uid; re-own it (small tmpfs home).
          chown -R "$host_uid:$(id -g ccvm)" /home/ccvm || true
        fi
      fi

      workdir="$(cat "$seed/workdir")"
      mode="$(cat "$seed/mode")"
      mkdir -p "$workdir"

      if [ "$mode" = "rw" ]; then
        # writableCwd=true (default): edits land on the host live.
        mount -t 9p -o ${p9} ccvm-workspace "$workdir"
      else
        # writableCwd=false: host tree read-only as the overlay lower,
        # a tmpfs upper for the agent's ephemeral edits. Writes never reach the host.
        mkdir -p /run/ccvm-lower /run/ccvm-upper /run/ccvm-work
        mount -t 9p -o ${p9},ro ccvm-workspace /run/ccvm-lower
        chown ccvm:users /run/ccvm-upper /run/ccvm-work
        mount -t overlay overlay \
          -o lowerdir=/run/ccvm-lower,upperdir=/run/ccvm-upper,workdir=/run/ccvm-work \
          "$workdir"
      fi

      # Set up ~/.claude from the seed's allowlist-staged config items.
      # The host wrapper copied only the enabled share.* items (settings, CLAUDE.md, commands,
      # agents, skills, and optionally plugins/config) into $seed/claude-config/ — nothing else
      # (projects/, sessions/, history.jsonl, .credentials.json, …) is ever staged. The guest
      # lays them into a fresh tmpfs ~/.claude so claude's writes stay ephemeral. No 9p config
      # mount, no root-private lower, no overlay whiteout — credential exclusion is airtight
      # by construction (it was never staged).
      install -d -m 700 -o ccvm -g users /home/ccvm/.claude
      if [ -d "$seed/claude-config" ]; then
        # Copy each staged item into ~/.claude. Dirs recurse; chown afterward (never chown -R
        # on an overlay root — copy-up hazard doesn't apply here since this is a plain tmpfs
        # dir, but be explicit). chmod u+w too (audit D-1): host config files reached the seed via
        # `cp -aL` of home-manager's read-only /nix/store symlinks (mode 0444), so without this the
        # in-VM settings.json stays unwritable and claude's own settings writes fail with EACCES.
        # Best-effort: a hiccup must not fail the oneshot and block sshd.
        find "$seed/claude-config" -maxdepth 1 -mindepth 1 -print0 2>/dev/null \
          | while IFS= read -r -d "" item; do
          name="''${item##*/}"
          dst="/home/ccvm/.claude/$name"
          if [ -d "$item" ]; then
            cp -r "$item" "$dst" 2>/dev/null \
              && chown -R ccvm:users "$dst" 2>/dev/null \
              && chmod -R u+w "$dst" 2>/dev/null || true
          else
            cp "$item" "$dst" 2>/dev/null \
              && chown ccvm:users "$dst" 2>/dev/null \
              && chmod u+w "$dst" 2>/dev/null || true
          fi
        done || true
      fi

      # Opt-in: persist ~/.claude/projects back to the host (session transcripts + memory).
      # Mounted read-WRITE into the tmpfs ~/.claude so Claude's writes reach the host —
      # `claude --resume` works across runs and memory survives. Must run AFTER the staging
      # block above so it layers over any staged projects/ content from the seed. No chown -R
      # (passthrough + uid remap already give correct host-side ownership). Best-effort.
      if [ -f "$seed/persist-claude-projects" ]; then
        mkdir -p /home/ccvm/.claude/projects
        mount -t 9p -o ${p9} ccvm-claude-projects /home/ccvm/.claude/projects || true
      fi

      # Opt-in encrypted ephemeral disk pool (vmDiskSize). The host attached a raw SPARSE virtio-blk
      # disk with serial=ccvm-scratch (so it resolves at /dev/disk/by-id/virtio-ccvm-scratch
      # regardless of /dev ordering). Two cases below, depending on whether the INITRD already
      # claimed the disk for the nix.enable /nix/store overlay upper (storeDiskScript, guest/default.nix):
      # it did (marker present) -> SHARE that pool; it didn't -> this service OWNS the disk and formats
      # a standalone /scratch. Invariants common to both, however the disk gets opened:
      #   * the LUKS key is generated in GUEST RAM and never crosses 9p — the host only ever sees
      #     ciphertext (same spirit as the API key);
      #   * wipe-on-exit is cryptographic — the key dies with guest RAM at power-off, so the on-disk
      #     image is inert the instant qemu stops, even on a crash that skips the host-side rm;
      #   * FAIL-OPEN throughout — any hiccup logs and continues WITHOUT /scratch (the agent still has
      #     tmpfs); it must never fail this oneshot and block sshd.
      if [ -f "$seed/vm-disk" ] && [ -e /run/ccvm-store-on-disk ]; then
        # nix.enable + vmDiskSize: the INITRD already LUKS-opened the disk and mounted it as the
        # /nix/store overlay upper at /nix/.rw-store (marker /run/ccvm-store-on-disk, preserved
        # across switch-root). Don't reformat — SHARE that one pool: bind its scratch/ subdir to
        # /scratch. Fail-open: a hiccup just leaves the agent without /scratch (it still has tmpfs).
        if mkdir -p /nix/.rw-store/scratch && mkdir -p /scratch \
           && mount --bind /nix/.rw-store/scratch /scratch; then
          chown ccvm:users /scratch || true
          chmod 0770 /scratch || true
        else
          echo "ccvm: scratch: bind to the shared disk pool failed; continuing without /scratch" >&2
        fi
      elif [ -f "$seed/vm-disk" ]; then
        # STANDALONE (nix.enable off, or the initrd backing failed open): this service owns the disk, so
        # LUKS-format it FRESH every boot, open it, lay an ext4, and mount it at /scratch. A LUKS
        # header needs a few MiB so the host caps the size; pbkdf2 keeps luksFormat fast (the key is
        # already 64 random bytes, so a memory-hard KDF would only slow boot — especially under TCG).
        modprobe dm_mod dm_crypt 2>/dev/null || true
        dev=/dev/disk/by-id/virtio-ccvm-scratch
        for _ in $(seq 1 50); do [ -e "$dev" ] && break; sleep 0.1; done
        if [ -e "$dev" ]; then
          keyf=/run/ccvm-scratch.key # tmpfs (RAM); never written to 9p, gone at power-off
          ( umask 077; head -c 64 /dev/urandom >"$keyf" )
          if cryptsetup luksFormat --batch-mode --type luks2 \
               --pbkdf pbkdf2 --pbkdf-force-iterations 1000 "$dev" "$keyf" \
             && cryptsetup open --type luks2 --key-file "$keyf" "$dev" ccvm-scratch; then
            shred -u "$keyf" 2>/dev/null || rm -f "$keyf"
            if mkfs.ext4 -q -F -E nodiscard /dev/mapper/ccvm-scratch \
               && mkdir -p /scratch \
               && mount /dev/mapper/ccvm-scratch /scratch; then
              # fail-open: ownership tweaks must not abort the oneshot (set -e) and block sshd.
              chown ccvm:users /scratch || true
              chmod 0770 /scratch || true
            else
              echo "ccvm: scratch disk: mkfs/mount failed; continuing without /scratch" >&2
            fi
          else
            echo "ccvm: scratch disk: LUKS setup failed; continuing without /scratch" >&2
            rm -f "$keyf"
          fi
        else
          echo "ccvm: scratch disk: $dev never appeared; continuing without /scratch" >&2
        fi
      fi

      # Opt-in egress allowlist. The host (which has working DNS) resolved the configured
      # FQDNs into IPs and wrote them to seed/egress-allow; seed/egress-enforce is the
      # "lock down" marker. An ABSENT marker means open egress — the native default — and we
      # install no firewall. When the marker is PRESENT we apply a default-deny OUTPUT
      # firewall permitting only the allowlisted destinations on the listed ports, plus a set
      # of base rules (below). Critically we gate on the marker, NOT on a non-empty allow set,
      # so even an empty allow set fails CLOSED (deny-all) rather than reverting to open egress
      # — the allowlist must never degrade into "no containment".
      if [ -f "$seed/egress-enforce" ]; then
        # Ensure the netfilter modules are present before nft talks to the kernel; without
        # them even the fail-closed fallback below could not install a deny rule.
        modprobe nf_tables nf_conntrack 2>/dev/null || true
        portset="$(cat "$seed/egress-ports" 2>/dev/null || true)"
        [ -n "$portset" ] || portset="443"
        v4="" v6=""
        if [ -f "$seed/egress-allow" ]; then
          while IFS= read -r addr; do
            [ -n "$addr" ] || continue
            case "$addr" in
            *:*) if [ -z "$v6" ]; then v6="$addr"; else v6="$v6, $addr"; fi ;;
            *) if [ -z "$v4" ]; then v4="$addr"; else v4="$v4, $addr"; fi ;;
            esac
          done <"$seed/egress-allow"
        fi
        # Base rules shared by the full ruleset AND the fail-closed fallback. They keep the
        # box usable and the management ssh alive WITHOUT opening an exfil channel:
        #   * lo + conntrack replies  -> the inbound ssh session (and DNS replies) keep working
        #   * DNS only to the slirp stub resolver (10.0.2.3 / fec0::3), NOT to any host — normal
        #     resolution via systemd-resolved still works, but a compromised agent can't tunnel
        #     data out to an arbitrary DNS server (DNS through the recursive resolver is the
        #     residual covert channel an SNI/DNS-filtering proxy would address — see CLAUDE.md,
        #     "Egress: an allowlist, not Tor")
        #   * DHCPv4 lease renewal
        #   * IPv6 NDP (neighbor/router discovery) so IPv6 doesn't black-hole and stall
        #     happy-eyeballs; without it `policy drop` would silently break v6.
        emit_base() {
          echo "    oifname lo accept"
          echo "    ct state established,related accept"
          echo "    ip daddr 10.0.2.3 udp dport 53 accept"
          echo "    ip daddr 10.0.2.3 tcp dport 53 accept"
          echo "    ip6 daddr fec0::3 udp dport 53 accept"
          echo "    ip6 daddr fec0::3 tcp dport 53 accept"
          echo "    udp dport 67 accept" # DHCPv4 lease renewal
          echo "    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } accept"
        }
        {
          echo "table inet ccvm {"
          echo "  chain output {"
          echo "    type filter hook output priority 0; policy drop;"
          emit_base
          [ -n "$v4" ] && echo "    ip daddr { $v4 } tcp dport { $portset } accept"
          [ -n "$v6" ] && echo "    ip6 daddr { $v6 } tcp dport { $portset } accept"
          echo "  }"
          echo "}"
        } >/run/ccvm-egress.nft
        if ! nft -f /run/ccvm-egress.nft; then
          # Apply failed: fail CLOSED, but keep the base rules so the management ssh session and
          # DNS survive (deny only NEW egress to the outside). A bare deny-all here would also
          # drop sshd's own replies — killing the session and hanging the boot — which is worse
          # than useless: you couldn't even --shell in to see what broke.
          echo "ccvm: ERROR: could not apply egress allowlist; failing closed (only DNS + the ssh session survive)" >&2
          {
            echo "table inet ccvm {"
            echo "  chain output {"
            echo "    type filter hook output priority 0; policy drop;"
            emit_base
            echo "  }"
            echo "}"
          } >/run/ccvm-egress-fallback.nft
          nft -f /run/ccvm-egress-fallback.nft 2>/dev/null || true
        fi

        # Pin the host-resolved name->IP map into the guest resolver so the agent dials exactly
        # what the firewall allows. Without this a round-robin/CDN host (github.com, npm) resolves
        # in-guest to an IP outside the host's launch-time snapshot and is silently dropped (the
        # request hangs). /etc/hosts is a store symlink and /etc is tmpfs, so build a real file from
        # its current contents + our pins and swap it in, then reload resolved (the swap won't trip
        # its inotify; if resolved isn't up yet it reads the file on start). Best-effort, fail-open:
        # a hiccup just leaves FQDN allowlisting at its old host-only behaviour, never blocks sshd.
        if [ -s "$seed/egress-hosts" ]; then
          if cp --dereference /etc/hosts /run/ccvm-hosts 2>/dev/null \
             && cat "$seed/egress-hosts" >>/run/ccvm-hosts \
             && cp --remove-destination /run/ccvm-hosts /etc/hosts; then
            systemctl reload-or-restart systemd-resolved.service >/dev/null 2>&1 || true
          else
            echo "ccvm: egress: could not pin /etc/hosts (allowlisted FQDNs may resolve to unpinned IPs)" >&2
          fi
        fi
      fi

      # Sanitized host git config (shareGitConfig): the wrapper stripped host-only /nix/store
      # tool paths and credentials, so this is safe to lay at the guest's XDG git paths. Owned
      # by ccvm (post-remap) so in-VM `git` reads it as the agent user. install -D makes the
      # parent dirs (root-owned 0755 — readable/traversable by ccvm, which is all git needs).
      if [ -f "$seed/gitconfig" ]; then
        install -D -m 644 -o ccvm -g users "$seed/gitconfig" /home/ccvm/.config/git/config
      fi
      if [ -f "$seed/gitignore" ]; then
        install -D -m 644 -o ccvm -g users "$seed/gitignore" /home/ccvm/.config/git/ignore
      fi

      # ccvm-context global memory (extraClaudeMd): tell the agent it is inside ccvm. Laid at
      # ~/.claude/CLAUDE.md owned by the (remapped) agent user. If share.claudeMd staged a host
      # CLAUDE.md (now simply present as a file in the tmpfs ~/.claude), APPEND to it rather than
      # clobber the user's global memory — the host file is never touched. Runs AFTER the
      # claude-config staging block above so $dst already reflects any staged host content.
      if [ -f "$seed/claude-md" ]; then
        dst=/home/ccvm/.claude/CLAUDE.md
        tmp=/home/ccvm/.claude/.CLAUDE.md.ccvm
        if [ -f "$dst" ]; then
          { cat "$dst"; printf '\n'; cat "$seed/claude-md"; } >"$tmp"
        else
          cat "$seed/claude-md" >"$tmp"
        fi
        install -m 644 -o ccvm -g users "$tmp" "$dst"
        rm -f "$tmp"
      fi

      # An `if` (not a trailing `[ -f … ] && …`): under `set -e` a bare conditional as the
      # script's final statement makes the whole oneshot exit non-zero when the file is
      # absent — the common case — which would fail ccvm-seed.service and block sshd.
      if [ -f "$seed/claude-json" ]; then
        install -m 600 -o ccvm -g users "$seed/claude-json" /home/ccvm/.claude.json
      fi
    '';
  };
in
{
  options.ccvm.launcherPackage = lib.mkOption {
    type = lib.types.package;
    internal = true;
    default = launcher;
    description = "The sshd ForceCommand target (cd + exec claude/zsh).";
  };

  config = {
    systemd.services.ccvm-seed = {
      description = "Mount ccvm seed + workspace and install SSH identity";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" ];
      unitConfig.DefaultDependencies = false;
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${seedSetup}/bin/ccvm-seed-setup";
      };
    };
  };
}
