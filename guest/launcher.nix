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
{ config, lib, pkgs, ... }:
let
  cfg = config.ccvm;

  # 9p mount options shared by every share. msize=1M keeps 9p throughput tolerable
  # for editing source trees; access=any + security_model=none on the host side means
  # host uids pass straight through (uid 1000 host == ccvm in the guest).
  p9 = "trans=virtio,version=9p2000.L,msize=1048576,access=any";

  claudeBin = if cfg.claudePackage != null then "${cfg.claudePackage}/bin/claude" else "claude";

  launcher = pkgs.writeShellApplication {
    name = "ccvm-guest-launch";
    runtimeInputs = [ pkgs.coreutils pkgs.zsh ];
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
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.nftables pkgs.kmod ];
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

      workdir="$(cat "$seed/workdir")"
      mode="$(cat "$seed/mode")"
      mkdir -p "$workdir"

      if [ "$mode" = "rw" ]; then
        # autoUpdateFiles=true: edits land on the host live.
        mount -t 9p -o ${p9} ccvm-workspace "$workdir"
      else
        # autoUpdateFiles=false (default): host tree read-only as the overlay lower,
        # a tmpfs upper for the agent's ephemeral edits. Writes never reach the host.
        mkdir -p /run/ccvm-lower /run/ccvm-upper /run/ccvm-work
        mount -t 9p -o ${p9},ro ccvm-workspace /run/ccvm-lower
        chown ccvm:users /run/ccvm-upper /run/ccvm-work
        mount -t overlay overlay \
          -o lowerdir=/run/ccvm-lower,upperdir=/run/ccvm-upper,workdir=/run/ccvm-work \
          "$workdir"
      fi

      # Optional host-config path: surface the host's ~/.claude (settings, custom commands,
      # global memory, OAuth credential) inside the VM as the read-only lower of an overlay,
      # with a tmpfs upper for claude's own writes — so its state is usable but ephemeral and
      # never persists back to the host. The home-root ~/.claude.json is staged via the seed
      # (it is config, not the secret token) and installed into the writable home.
      if [ -f "$seed/share-config" ]; then
        mkdir -p /run/ccvm-host-claude
        if mount -t 9p -o ${p9},ro ccvm-config /run/ccvm-host-claude 2>/dev/null; then
          install -d -m 700 -o ccvm -g users /home/ccvm/.claude
          mkdir -p /run/ccvm-claude-upper /run/ccvm-claude-work
          chown ccvm:users /run/ccvm-claude-upper /run/ccvm-claude-work
          mount -t overlay overlay \
            -o lowerdir=/run/ccvm-host-claude,upperdir=/run/ccvm-claude-upper,workdir=/run/ccvm-claude-work \
            /home/ccvm/.claude
          # Lay the host-dereferenced config files (home-manager symlinks the wrapper
          # resolved on the host) over the overlay. They land in the writable tmpfs upper,
          # shadowing the now-dangling symlinks the 9p lower carries, so claude can actually
          # read settings.json et al. Per-file chown (never `chown -R` the overlay root —
          # that would copy every lower file up into the tmpfs). Best-effort: a hiccup here
          # must not fail the oneshot and block sshd.
          if [ -d "$seed/config-deref" ]; then
            find "$seed/config-deref" -type f -print0 | while IFS= read -r -d "" f; do
              rel="''${f#"$seed/config-deref/"}"
              dst="/home/ccvm/.claude/$rel"
              mkdir -p "$(dirname "$dst")" && rm -f "$dst" \
                && cp "$f" "$dst" && chown ccvm:users "$dst"
            done || true
          fi
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
        #     residual covert channel an SNI/DNS-filtering proxy would address — see design §3.10)
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
