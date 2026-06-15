# Changelog

All notable changes to **ccvm** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — unreleased

First public release: run Claude Code in an ephemeral, RAM-only QEMU microVM with
native-terminal fidelity, reproducible end-to-end from this flake.

### Added

- **One-command ephemeral microVM.** `ccvm` is a drop-in replacement for `claude`: it boots a
  RAM-only NixOS guest (tmpfs root, read-only squashfs `/nix/store`), `ssh -tt`s in, and drops
  you into the same TUI. The entire VM is destroyed on exit.
- **`writableCwd`** (default `true`) — live edits to the launch directory land on the host tree
  via 9p. Set `false` for a genuinely read-only host tree (edits land in a tmpfs upper and never
  reach the host).
- **`share.*` granular config allowlist** — opt-in staging of `~/.claude` settings, memory,
  `gitConfig`, `keybindings`, and `outputStyles` into the guest. Excludes the OAuth credential by
  construction, so your login never crosses into the VM. `~/.claude.json` is staged sanitized
  (`mcpServers[].env`/`.headers` and legacy `primaryApiKey` stripped); `gitConfig` is sanitized
  (store paths and `credential.*` dropped, signing force-disabled).
- **`egressAllowlist`** — opt-in default-deny network firewall enforced inside the guest by a
  non-root agent. Auto-drops `agentSudo` and the agent's Nix `trusted-users` membership to keep
  the enforcement tamper-resistant. Fails closed (refuses to boot rather than opening egress) on
  an unresolvable FQDN-only allowlist.
- **`vmDiskSize`** — opt-in encrypted, ephemeral disk-backed pool mounted at `/scratch` for large
  build outputs that would exhaust the RAM filesystem. The guest `luksFormat`s from `/dev/urandom`
  every boot; the host sees only ciphertext; the disk is cryptographically wiped on exit.
- **`nix.enable`** — writable `/nix/store` overlay (backed by the `vmDiskSize` disk) for in-VM
  Nix builds, with `nix.substituters` / `nix.trustedPublicKeys` to add binary caches.
- **`persistClaudeProjects`** — opt-in write-back of `~/.claude/projects` (session transcripts +
  memory) to the host; nothing else survives.
- **`extraClaudeMd`** — stage a built-in context blurb as the guest's `~/.claude/CLAUDE.md`.
- **`acceleration`** — declarative `auto` | `kvm` | `tcg` mode selection.
- **Image-paste clipboard bridge** — an image-only reverse bridge restores clipboard image paste
  into the TUI.
- **`agentSudo`**, **`lockGuestMemory`** (mlock guest RAM off host swap), and other guest knobs.
- **Runtime `CCVM_*` overrides** — per-run env-var overrides of the baked defaults; explicit
  `ccvm` flags win over env vars. `CCVM_SHARE_CLAUDE_CONFIG=0|1` toggles all `share.*` at once.
- **`--ccvm-help` / `--ccvm-version`** wrapper flags.
- **home-manager module** (`programs.ccvm.*`) installing the command.
- **mdBook documentation site** (deployed to GitHub Pages), with internal-link checking gated in
  CI.
- **CI** — `nix flake check` (guest image, wrapper shellcheck, host secret-hygiene tests,
  clipboard, egress, formatting, docs link-check) on every push/PR, plus a weekly
  `nix flake update` PR.

### Security

The QEMU boundary defends the host filesystem and the user's credentials against a
(possibly prompt-injected) in-VM agent. Established invariants for this release:

- The API key never touches disk/argv/kernel-cmdline (SSH `SendEnv`→`AcceptEnv` only).
- The SSH host key is pinned per run (ephemeral ed25519, `StrictHostKeyChecking=yes`).
- No persistent disk — root tmpfs, store read-only; only host-CWD edits (in `writableCwd` mode)
  and opt-in `~/.claude/projects` survive.
- Only the launch directory is shared — no `~/.ssh`, `~/.aws`, or home dir crosses.
- QEMU is sandboxed (`-sandbox on`), ccvm refuses to run as host root, and 9p shares are
  `nosuid,nodev`.
- Guest kernel/userspace hardening: `protectKernelImage`, hardening sysctls, `sudo-rs`, locked
  root password, pinned `allowed-users`.

[0.1.0]: https://github.com/openccvm/ccvm/releases/tag/v0.1.0
