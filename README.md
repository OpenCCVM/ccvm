# ccvm

**CLI for isolating and securing the Claude Code experience with little-to-no added friction**

***100% reproducible from this repository.***

[![flake check](https://github.com/openccvm/ccvm/actions/workflows/flake-check.yml/badge.svg)](https://github.com/openccvm/ccvm/actions/workflows/flake-check.yml) [![docs](https://img.shields.io/badge/docs-mdBook-1f6feb)](https://openccvm.github.io/ccvm/) [![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

**[About](#about) · [Quick start](#quick-start) · [Documentation](#documentation) · [Roadmap](#roadmap) · [License](#license)**

---

## About

  `ccvm` is a drop-in replacement for running `claude`.

  Running `ccvm` in any project directory automatically whips up a RAM-only NixOS microVM and
  drops you into the same TUI that running `claude` would. Everything Claude does happens inside a
  completely ephemeral sandbox that can only see the one directory you launched it in — not the
  rest of your machine, your SSH keys, or your cloud credentials — and it all disappears when you
  close it.

  By default it feels exactly like native `claude` (live edits to your project, your `~/.claude`
  settings, your git identity) — but your **login credential never crosses** into the VM, and one
  setting (`egressAllowlist`) locks down where the VM can connect. The full threat model and every
  option live in the **[documentation](https://openccvm.github.io/ccvm/)**.

---

## Quick start

  **Requirements:** Linux and [Nix](https://nixos.org/download/) (with flakes enabled).

  Just want to try it, without installing anything? In any project directory:

  ```bash
  nix run github:openccvm/ccvm
  ```

  > [!NOTE]
  > No Nix yet? Install it with the [official installer](https://nixos.org/download/), then enable
  > flakes once by adding `experimental-features = nix-command flakes` to `~/.config/nix/nix.conf`.

  > [!NOTE]
  > The first run builds the VM image, so it takes a few minutes; after that it's cached and starts
  > quickly.

  Once installed via home-manager (see **[Getting started](https://openccvm.github.io/ccvm/getting-started.html)**),
  run it anywhere, exactly like `claude`:

  ```bash
  ccvm
  ```

  > [!NOTE]
  > ccvm brings your `~/.claude` settings into the VM but not your login, so `/login` on first run
  > (it stays in the VM and is wiped on exit) or set `ANTHROPIC_API_KEY`.

  > [!WARNING]
  > Avoid pressing **Ctrl+Z** inside ccvm. Claude Code treats it as suspend and stops itself, but
  > the VM has no shell to bring it back, so the session just freezes. Disconnect and start again
  > (the VM is ephemeral, so nothing is lost beyond the session). This is upstream Claude Code
  > behavior, not specific to ccvm.

---

## Documentation

  Everything lives in the docs site: **[openccvm.github.io/ccvm](https://openccvm.github.io/ccvm/)**

  - **[Getting started](https://openccvm.github.io/ccvm/getting-started.html)** — requirements, the
    full home-manager install, first-run authentication.
  - **[Options](https://openccvm.github.io/ccvm/options.html)** — every `programs.ccvm.*` setting and
    the per-run `CCVM_*` overrides (egress, encrypted disk, in-VM Nix, config sharing, …).
  - **[Security](https://openccvm.github.io/ccvm/security/threat-model.html)** — the threat model, the
    must-not-regress invariants, the egress design, and the encrypted-disk / clipboard-bridge
    internals.
  - **[Developing](https://openccvm.github.io/ccvm/developing/repo-map.html)** — repo map, the
    build/test loop, the deliberate defaults, and the settled design decisions.

---

## Roadmap

  - [X] Baseline one-command microVM for Claude Code
  - [X] Network egress controls
  - [X] Encrypted disk support
  - [ ] Authenticated binary cache support
  - [ ] Dedicated CI server for the boot tests
  - [ ] macOS host support — community-driven (I have no Apple hardware; help from
    nix-darwin folks or anyone willing to do the porting work would be very welcome)

---

## License

  MIT © 2026 Jaxxen. See [LICENSE](LICENSE).
