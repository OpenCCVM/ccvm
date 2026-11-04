# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Jaxxen

# Stub `claude` for ccvm boot tests (tests/boot.sh): instead of the real agent, print
# exactly what the guest sees so the host can assert on it, then exit. No API calls.
echo "CCVM_BOOT_MARKER"
echo "ARGV:$*"
echo "CWD:$PWD"
# The agent's uid: the guest remaps the ccvm user to the host uid so 9p passthrough gives
# correct workspace ownership. The host asserts this equals its own `id -u`.
echo "UID:$(id -u)"
# agentSudo: with it dropped (auto when egressAllowlist is set) the agent (ccvm) is not in wheel and
# sudo is disabled, so a prompt-injected agent can't flush the in-guest egress firewall. Report
# whether passwordless root is actually available so boot.sh can assert per posture.
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  echo "SUDO:available"
else
  echo "SUDO:dropped"
fi
# 9p shares should carry nosuid,nodev (defense in depth). Check the workspace (the guest CWD in rw
# mode is the 9p share itself; in overlay mode it's the overlay, so this line is asserted only for rw).
wsopts=",$(awk -v d="$PWD" '$2==d {print $4; exit}' /proc/self/mounts 2>/dev/null),"
if [ "$wsopts" != ",," ] && [ "${wsopts#*,nosuid,}" != "$wsopts" ] && [ "${wsopts#*,nodev,}" != "$wsopts" ]; then
  echo "WS:hardened"
else
  echo "WS:plain"
fi
# Try to write into the workspace (the guest CWD == the host project path). In rw mode this
# reaches the host; in overlay mode it lands in the tmpfs upper and never does.
if echo "guest-wrote-$$" >./ccvm-boot-write 2>/dev/null; then
  echo "WRITE:ok"
else
  echo "WRITE:denied"
fi
# Report host-config visibility (share.* items land in a tmpfs ~/.claude from the seed).
# share.settings stages settings.json; the credential is NEVER staged — excluded by
# construction (it is not a share.* item). boot.sh asserts settings ARE readable, credential NOT.
[ -r "$HOME/.claude/settings.json" ] && echo "CONFIG:settings-readable"
# Audit D-1: settings.json reached the seed via cp -aL of a home-manager /nix/store symlink (mode
# 0444), so the guest must restore owner-write or claude's own settings writes fail with EACCES.
if [ -e "$HOME/.claude/settings.json" ]; then
  [ -w "$HOME/.claude/settings.json" ] && echo "CONFIG:settings-writable" || echo "CONFIG:settings-readonly"
fi
if [ -r "$HOME/.claude/.credentials.json" ]; then
  echo "CONFIG:credential-readable"
else
  echo "CONFIG:credential-excluded"
fi

# persistClaudeProjects: in the persist posture ~/.claude/projects is a read-WRITE 9p mount of the
# host's projects dir — and ONLY that subpath (the credential at the ~/.claude root is never
# mounted). Write a marker INSIDE projects/ (must reach the host) and one at the ~/.claude ROOT
# (must NOT — it's the ephemeral overlay/tmpfs), so boot.sh asserts both write-back AND the scope.
mkdir -p "$HOME/.claude/projects" 2>/dev/null
if echo "CCVM-PERSIST-MARKER" >"$HOME/.claude/projects/ccvm-persist-probe" 2>/dev/null; then
  echo "PERSIST:wrote-projects"
else
  echo "PERSIST:projects-writefail"
fi
echo "CCVM-ROOT-MARKER" >"$HOME/.claude/ccvm-root-probe" 2>/dev/null || true

# ccvm-context global memory (extraClaudeMd): should be laid at ~/.claude/CLAUDE.md, carrying
# the baked blurb and the runtime mode line, but not the source file's SPDX header. Report so
# boot.sh can assert it survived a boot.
if [ -r "$HOME/.claude/CLAUDE.md" ]; then
  echo "CLAUDEMD:present"
  grep -q 'inside .*ccvm' "$HOME/.claude/CLAUDE.md" 2>/dev/null && echo "CLAUDEMD:blurb"
  grep -q 'LIVE to the host' "$HOME/.claude/CLAUDE.md" 2>/dev/null && echo "CLAUDEMD:mode-rw"
  grep -q 'SPDX-License-Identifier' "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo "CLAUDEMD:no-spdx"
else
  echo "CLAUDEMD:absent"
fi

# Git config passthrough (shareGitConfig): the guest should see the host identity, with the
# host-only /nix/store tool paths and credentials stripped and signing disabled. Report what
# actually landed so boot.sh can assert the sanitization survived a real boot.
if [ -r "$HOME/.config/git/config" ]; then
  echo "GIT:config-present"
  echo "GITNAME:$(git config --get user.name 2>/dev/null)"
  if grep -q '/nix/store' "$HOME/.config/git/config"; then
    echo "GIT:storepath-leaked"
  else
    echo "GIT:sanitized"
  fi
  echo "GITSIGN:$(git config --get commit.gpgsign 2>/dev/null)"
else
  echo "GIT:config-absent"
fi
[ -r "$HOME/.config/git/ignore" ] && echo "GIT:ignore-present"

# vmDiskSize: the opt-in encrypted disk pool should be a writable mount at /scratch backed by a
# dm-crypt device. Report what landed so boot.sh can assert it survived a real boot. The crypt
# check reads /sys unprivileged: the mapper device's dm/uuid is CRYPT-LUKS2-… for dm-crypt.
if mountpoint -q /scratch 2>/dev/null; then
  echo "SCRATCH:mounted"
  if echo "scratch-$$" >/scratch/ccvm-scratch-write 2>/dev/null; then echo "SCRATCH:writable"; fi
  dm="$(readlink -f /dev/mapper/ccvm-scratch 2>/dev/null)" # -> /dev/dm-N
  if [ -n "$dm" ]; then
    case "$(cat "/sys/class/block/$(basename "$dm")/dm/uuid" 2>/dev/null)" in
      CRYPT-*) echo "SCRATCH:encrypted" ;;
    esac
  fi
else
  echo "SCRATCH:absent"
fi

# nix.enable: with it on, /nix/store should be a writable overlay (overlayfs) and `nix` present;
# off (the default), /nix/store stays the read-only squashfs/9p. Report the store fs type and
# whether nix is on PATH so boot.sh can assert per posture. stat -f is coreutils (always present).
case "$(stat -f -c %T /nix/store 2>/dev/null)" in
  overlayfs) echo "STORE:overlay" ;;
  squashfs | 9p | v9fs) echo "STORE:readonly" ;;
  *) echo "STORE:other" ;;
esac
command -v nix >/dev/null 2>&1 && echo "NIX:present" || echo "NIX:absent"

# Audit S-1: a Nix trusted-user is root-equivalent (it can set post-build-hook / disable the sandbox,
# both honoured by the root daemon). When sudo is dropped (auto under egressAllowlist) the agent must
# NOT be trusted, or it could regain root and `nft flush` the egress firewall. Report whether ccvm is
# in the daemon's trusted-users so boot.sh can assert it's excluded under the nix+egress posture.
if command -v nix >/dev/null 2>&1; then
  tu="$({ nix config show 2>/dev/null || nix show-config 2>/dev/null || cat /etc/nix/nix.conf 2>/dev/null; } | sed -n 's/^[[:space:]]*trusted-users[[:space:]]*=[[:space:]]*//p')"
  if printf '%s' "$tu" | grep -qw ccvm; then echo "TRUSTED:agent-is-trusted"; else echo "TRUSTED:agent-not-trusted"; fi
fi

# nix.enable + vmDiskSize: the initrd should back the overlay UPPER (/nix/.rw-store) with the
# encrypted disk instead of tmpfs. Report its fstype (ext4 = disk-backed, tmpfs = RAM/fail-open)
# and whether it sits on a dm-crypt device, so boot.sh can assert the disk-backed-upper posture.
if [ -d /nix/.rw-store ]; then
  case "$(stat -f -c %T /nix/.rw-store 2>/dev/null)" in
    ext2/ext3 | ext4) echo "RWSTORE:disk" ;;
    tmpfs) echo "RWSTORE:tmpfs" ;;
    *) echo "RWSTORE:other" ;;
  esac
  dm="$(readlink -f /dev/mapper/ccvm-scratch 2>/dev/null)" # -> /dev/dm-N
  if [ -n "$dm" ]; then
    case "$(cat "/sys/class/block/$(basename "$dm")/dm/uuid" 2>/dev/null)" in
      CRYPT-*) echo "RWSTORE:encrypted" ;;
    esac
  fi
fi

# nix.substituters / nix.trustedPublicKeys: an extra binary cache configured via the option should
# reach the guest's effective nix config — both the substituter URL and its trusted public key. The
# boot test (nixSubst posture) asserts on these. (A real fetch is a network/human check;
# example.invalid never resolves.) `nix config show`/`nix.conf` both name them.
nixcfg="$({ nix config show 2>/dev/null || nix show-config 2>/dev/null || cat /etc/nix/nix.conf 2>/dev/null; })"
if grep -q 'https://cache.example.invalid' <<<"$nixcfg"; then
  echo "SUBST:substituter-configured"
else
  echo "SUBST:substituter-missing"
fi
if grep -q 'cache.example.invalid:0000000000000000000000000000000000000000000=' <<<"$nixcfg"; then
  echo "SUBST:key-configured"
else
  echo "SUBST:key-missing"
fi

# egress /etc/hosts pin: allowlisted FQDNs are pinned to the host-resolved IP so the in-VM
# resolver returns an IP the firewall allows (otherwise a round-robin host drifts to an IP the
# firewall drops). Report whether the example.com pin landed — boot.sh asserts it in the egress
# scenario; it's absent under open egress, where /etc/hosts is left untouched.
if grep -qiE '(^|[[:space:]])example\.com([[:space:]]|$)' /etc/hosts 2>/dev/null; then
  echo "HOSTS:pinned"
else
  echo "HOSTS:unpinned"
fi

# Egress probes (best-effort, short timeout). With open egress both reach; with the
# example.com allowlist only the allowed host reaches and the other is blocked. boot.sh
# asserts on these only in the egress scenario.
probe() { # $1=url $2=label
  if curl -sS --max-time 8 -o /dev/null "$1" 2>/dev/null; then
    echo "EGRESS:$2:reachable"
  else
    echo "EGRESS:$2:blocked"
  fi
}
probe https://example.com/ allowed
probe https://1.1.1.1/ denied

# Exit cleanly: the diagnostic probes/tests above must not leak a non-zero status to the
# wrapper (which propagates the remote exit code) — that would look like a boot/session
# failure when the run was fine. The real claude returns 0 on a normal exit; mirror that.
exit 0
