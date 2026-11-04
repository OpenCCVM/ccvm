# Contributing to ccvm

Thanks for helping out. ccvm is a small, security-focused project, so a few house
rules keep it that way.

## Read this first

[`CLAUDE.md`](CLAUDE.md) is the authoritative engineering doc: the security invariants
that must not regress, the rationale behind the settled decisions (and which ones not to
relitigate), and the gotchas that cost time to rediscover. Read it before changing the
guest, the wrapper, or the boot path. The [`README`](README.md) is deliberately
newcomer-facing — keep deep/technical detail in `CLAUDE.md`, not the README.

## Definition of done

A behaviour change is done when:

1. **`nix flake check` is green.** It builds the guest image, shellchecks the wrapper, and
   runs the host-side guarantee tests (secret hygiene, config staging, verbatim argv, mode
   selection). CI runs this on every PR, against both the pinned nixpkgs and
   `nixos-unstable`.
2. **`bash tests/boot.sh` passes on a Nix+KVM box** — *if* you touched the guest, wrapper,
   or boot path. It boots a stub-`claude` VM and asserts the things that need a real guest
   (argv reaches claude, rw vs. overlay file visibility, egress, the encrypted disk). This
   is **not** in CI yet (it needs a KVM runner), so paste the `N passed, M failed` line in
   your PR. Defaults to TCG software emulation, so it runs anywhere — just slowly.
3. **A human `ccvm --shell` pass** (resize, `vim`, `less`, vi-mode) — *if* it touches the
   terminal path. Terminal fidelity is verified by hand, not automated.

The pull-request template restates this checklist.

## Security invariants

Treat any change that weakens a `CLAUDE.md` "Security invariants" bullet as a bug: no
secret to disk/argv/seed, the host key stays pinned, only the CWD is shared. The host-side
tests grep the seed for the API key and the OAuth credential — keep them passing.

## Conventions

- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` for
  AI-assisted commits (note: lowercase `authored-by`, bare `Claude`).
- **Format before committing:** `nix fmt` (treefmt — `nixfmt` for Nix, `shfmt` for the
  shell scripts). CI enforces it (`checks.formatting`), so an unformatted tree fails
  `nix flake check`. `shellcheck` additionally lints the wrapper and also runs at build.

## License

By contributing you agree your contributions are licensed under the MIT License
(see [`LICENSE`](LICENSE)).
