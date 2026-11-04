<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Deliberate defaults — do not reverse

These defaults were chosen on purpose. Reversing one needs a *new* reason, not a rediscovery of the
old trade-off.

## Native mirroring is the default

`writableCwd = true` (live host edits), the `share.*` allowlist on (settings / claudeMd / commands /
agents / skills reuse host `~/.claude`), and `share.gitConfig = true` (commit as you, with your
aliases/ignores) make ccvm behave like native `claude`. Isolation (read-only project, no config) is
the **opt-in**.

Do not re-propose "secure by default" — that was the original spec and was deliberately reversed.
The out-of-the-box win is [containment plus the host login never crossing](../security/threat-model.md#default-posture--what-the-defaults-do-and-dont-stop),
not project-exfiltration resistance, a deliberate DevEx choice.

## RAM-only is the default; the disk pool and in-VM nix are opt-in {#ram-only-is-the-default}

`vmDiskSize = 0` (no disk, pure RAM) and `nix.enable = false` (read-only `/nix/store`, no in-VM nix,
lean closure) are the defaults.

The user-facing option is `programs.ccvm.nix.enable`; the internal config + guest module use the same
nested `nix.enable` name end to end. It is **build-time** — it flips `nix.enable` and rebuilds the
store as a writable overlay in the initrd. Its overlay upper is tmpfs by default; combine with
`vmDiskSize > 0` and the initrd LUKS oneshot relocates that upper onto the encrypted disk (fail-open
to tmpfs), so a large `nix develop` doesn't OOM guest RAM — one shared pool also backs `/scratch`.

**The guest always boots off the self-contained squashfs store; the host store is never the guest's
boot store.**

To give in-VM nix extra pre-built paths, point it at a **binary cache** via `nix.substituters` +
`nix.trustedPublicKeys` — pure guest-closure config, baked into the guest's `nix.conf` (appended to
`cache.nixos.org` and nixpkgs' keys), HTTP substitution at line rate, no host credentials.
`require-sigs` stays ON. A **public-read** signed cache works with zero secrets; a cache behind a
token/netrc is **not yet supported**.

Two predecessors were **deliberately removed — do not re-add**: `mountHostNixStore` (host store as
the guest's boot store) and `nix.useHostStoreAsCache` (host `/nix/store` + DB over ro 9p as a local
substituter): 9p copy ran **slower than downloading** (<1 MiB/s vs. network), and it exposed the
*entire* host store to the agent. See [Design decisions → in-VM nix](design-decisions.md#nix-in-the-vm).

## `agentSudo` is auto, not a fixed default

The agent has passwordless root in the guest EXCEPT when `egressAllowlist` is set, where it
auto-drops so the in-guest egress firewall can't be flushed (the firewall is installed by a root
systemd unit, not the agent).

**Coupled to it (`guest/default.nix`): Nix `trusted-users` is gated on the SAME flag —
`[ "root" ] ++ lib.optional cfg.agentSudo "ccvm"` — so when sudo is off the agent is also
non-trusted.** This is load-bearing under `nix.enable`: a Nix trusted-user is root-equivalent (a
`post-build-hook` runs as root), so leaving the agent trusted would hand straight back the root the
sudo-drop removes, letting it `nft flush` the firewall (audit S-1). A non-trusted agent can still
`nix build` / `nix develop`; builds run as the `nixbld` users.

`null` = auto; `true` / `false` force it — but forcing `true` alongside an `egressAllowlist`
re-opens the `nft flush` bypass (and re-grants trusted-user), so it's only sensible behind host-side
egress control. Build-time (rebuilds the guest closure).

## Guest kernel/userspace hardening is deliberate, cheap, and boot-safe

See [Security invariants → guest hardening](../security/invariants.md#guest-kerneluserspace-hardening)
for the full list: `security.protectKernelImage`, the sysctl set, `sudo-rs`, the explicit root
password lock, and the pinned `allowed-users`. Notably **not** done: `lockKernelModules`
(incompatible with the seed service's runtime `modprobe`) and disabling unprivileged user namespaces
(the nix build sandbox needs them; namespaced-root can't reach the init-netns firewall —
audit-verified, not a containment hole).

## `extraClaudeMd` is default-on context, not a flag

A built-in blurb is staged as the guest's `~/.claude/CLAUDE.md` (via the seed, **appended** to any
host-shared one — never clobbering it) so the agent knows it's in ccvm. It must stay seed-delivered,
never become `--append-system-prompt` (which would break transparent passthrough). The wrapper
prepends a **runtime** mode line (rw=live / overlay=discarded) that the build-time file can't know.

## Transparent passthrough

The wrapper injects **no** flags. Everything after `ccvm` is forwarded to `claude` verbatim,
including `--dangerously-skip-permissions`. The *only* args the wrapper consumes are its own:
`--shell`, `--ccvm-debug`, `--writable-cwd`, `--read-only-cwd`, `--ccvm-help`, `--ccvm-version` —
all deliberately ccvm-specific names (none is a claude flag), so bare `--help` / `--version` still
reach claude. Preserve that interception boundary.

## Image paste — image-only reverse clipboard bridge (`clipboard.images`, default-on)

The full design and threat analysis live in [Security → Image-paste bridge](../security/image-paste.md).
In short: the bridge restores Ctrl+V image paste over the existing SSH connection, is **image-only**
(host clipboard text never crosses), and opens no new network hole.
