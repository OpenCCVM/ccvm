# Repo map

| Path | Role |
|---|---|
| `flake.nix` | Outputs: `packages.*` (`ccvm`, guest artifacts, `docs`), `checks.*`, `homeModules.ccvm`. |
| `lib/mkccvm.nix` | The builder. Evaluates the guest NixOS system, then bakes its boot artifacts + scalar config into the wrapper via `builtins.replaceStrings` `@TOKENS@`. |
| `lib/defaults.nix` | Default values for the builder's config (memory, cores, the `package`, etc.). |
| `lib/ccvm-context.md` | The built-in `extraClaudeMd` blurb staged as the guest's `~/.claude/CLAUDE.md`. |
| `wrapper/ccvm.sh` | Host wrapper **template** (the `@TOKEN@` placeholders). Generates completely ephemeral SSH keys, writes the seed, boots QEMU headless, `ssh -tt`s in, traps cleanup. |
| `guest/default.nix` | The microVM NixOS guest (tmpfs root, ro squashfs `/nix/store`). |
| `guest/launcher.nix` | Two units. `ccvm-seed.service` (root oneshot, `Before=sshd`) installs the pinned host key + `authorized_keys` and does every 9p/overlay mount. `ccvm-guest-launch` is the **unprivileged** sshd `ForceCommand` that just `cd`s to the workspace and execs claude (or zsh). |
| `guest/sshd.nix` | Hardened sshd: key-only, no root, single `ForceCommand`. |
| `modules/home-manager.nix` | `programs.ccvm.*` options → installs the command. |
| `docs/` | This mdBook site (`book.toml`, `src/`). Built by `packages.docs`, gated by `checks.docs`. |
| `tests/` | `host.sh` (CI host-side guarantees via the `CCVM_DRYRUN` hook), `boot.sh`+`stub-claude.sh`+`boot.nix` (local full-boot smoke test), `clipboard.sh` (image-only bridge), `egress.sh`, `default.nix` (wires the checks into `nix flake check`). |
