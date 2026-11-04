<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# ccvm

**Run Claude Code in an ephemeral, RAM-only QEMU microVM — with native-terminal fidelity and
zero host setup.**

`ccvm` is a drop-in replacement for running `claude`. Launch it in any project directory and it
whips up a completely ephemeral NixOS microVM, drops you into the exact same Claude Code TUI you'd get from
native `claude`, and tears the whole VM down when you exit. Everything Claude does happens inside
the VM; the only things that cross back to your host are the edits it makes to the one project
directory you launched it in.

The whole project is **100% reproducible from this repository** and built entirely with Nix — no
Node, no Bun, no npm, no hidden lockfiles. The site you are reading is byte-reproducible from a
commit too.

## Why ccvm

- **Containment by default.** Claude can see the one directory you launched it in — not the rest
  of your machine, your SSH keys, or your cloud credentials — and everything it does disappears
  when you close it.
- **Feels native.** A real guest PTY over SSH means resize, `vim`, `less`, full-screen TUIs, and
  vi-mode all behave exactly as they do outside the VM.
- **Your host login never auto-crosses.** ccvm shares your `~/.claude` settings, commands, agents,
  and memory, but the OAuth credential is excluded **by construction** — you `/login` inside the VM
  (wiped on exit) or set `ANTHROPIC_API_KEY`.
- **One knob to lock egress down.** Open egress by default (like native `claude`); set
  `egressAllowlist` to switch to a default-deny firewall enforced inside the guest.

## Where to go next

- New here? Start with **[About](about.md)** for the what/why and the one-paragraph threat model,
  then **[Getting started](getting-started.md)** to install and run it.
- Configuring it? The **[Options](options.md)** reference covers every `programs.ccvm.*` setting
  and the per-run `CCVM_*` environment variables.
- Care about the boundary? The **[Security](security/threat-model.md)** section is the deep version
  of the threat model, the must-not-regress invariants, and the egress design.
- Hacking on ccvm? **[Developing](developing/repo-map.md)** has the repo map, the build/test loop,
  the deliberate defaults not to reverse, and the settled design decisions not to relitigate.

> **Heads up:** avoid pressing **Ctrl+Z** inside ccvm — Claude Code treats it as suspend and stops
> itself, and the VM has no shell to bring it back, so the session freezes. This is upstream Claude
> Code behavior, not specific to ccvm. See [Getting started](getting-started.md#the-ctrlz-caveat).
