<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# About

`ccvm` runs Claude Code inside an ephemeral, RAM-only QEMU microVM. Running `ccvm` in a project
directory automatically boots a NixOS microVM and drops you into the same TUI that running `claude`
would — but everything Claude does happens inside a disposable sandbox that is destroyed when you
exit.

## What it is

- A **drop-in replacement** for `claude`: everything you type after `ccvm` is forwarded to the real
  `claude` verbatim, including flags like `--dangerously-skip-permissions`.
- An **ephemeral sandbox**: the entire VM (root filesystem, packages, shell history, anything
  outside the shared project directory) lives in RAM and is destroyed on exit. There is no disk to
  recover state from afterwards.
- **Zero host setup**: it runs unprivileged, with QEMU's built-in user-mode networking — no
  bridges, TAP devices, or `sudo` required.

## Who it's for

- People who want to run Claude Code (especially with `--dangerously-skip-permissions`) without
  giving an agent — possibly a prompt-injected one — free rein over their home directory and
  credentials.
- Security-minded developers who want a real, auditable trust boundary (QEMU) rather than a
  best-effort one.
- Nix users who value a fully reproducible, lockfile-pinned toolchain.

## The threat model in one paragraph

The trust boundary is **QEMU**: ccvm assumes QEMU's device/Virtio isolation holds, and defends the
**host filesystem and your credentials** against a (possibly prompt-injected) agent inside the VM.
Out of the box you get **containment** — Claude can't read or write anything on the host beyond the
single project directory you launched it in, and nothing it does persists past exit — plus the
guarantee that **your host login never auto-crosses** into the VM (the OAuth credential is excluded
from what's shared, by construction). What the defaults do **not** give you is exfiltration
resistance: under the native-mirroring defaults (open egress), a misbehaving agent can read your
project tree and send it somewhere over the open network. Locking that down is one setting —
[`egressAllowlist`](security/egress.md), a default-deny firewall enforced inside the guest.

For the full version — scope of the boundary, the must-not-regress invariants, the egress design
and its residual channels — read the [Security](security/threat-model.md) section.

## The native-mirroring default

ccvm's defaults are deliberately tuned to feel exactly like native `claude`:

- **Live host edits** (`writableCwd = true`) — the agent's edits to the project directory land on
  your host immediately.
- **Shared `~/.claude` config** — your settings, `CLAUDE.md`, commands, agents, skills, keybindings,
  and output styles are staged into the VM (but **never** your login credential).
- **Shared git identity** (`share.gitConfig = true`) — in-VM `git` commits as you, with your
  aliases and ignores (no credentials or signing keys cross).
- **Open egress** — the VM can reach the internet freely, just like native `claude`.

Isolation (read-only project, no shared config, locked-down egress) is the **opt-in**, not the
default. This is a deliberate DevEx choice: the out-of-the-box win is containment plus the host
login never crossing, not project-exfiltration resistance. See
[Deliberate defaults](developing/defaults.md) for the full rationale.
