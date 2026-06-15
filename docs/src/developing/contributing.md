# Contributing

Thanks for helping out. ccvm is a small, security-focused project, so a few house rules keep it that
way.

## Read this first

This site's **[Security](../security/threat-model.md)** and **Developing** sections are the
authoritative engineering docs: the security invariants that must not regress, the rationale behind
the settled [design decisions](design-decisions.md) (and which ones not to relitigate), and the
[gotchas](gotchas.md) that cost time to rediscover. Read the relevant pages before changing the
guest, the wrapper, or the boot path.

`CLAUDE.md` in the repo root is the terse operational version — the must-not-regress checklist plus a
routing directive into this site. The [README](https://github.com/openccvm/ccvm/blob/main/README.md) is
deliberately newcomer-facing — keep deep/technical detail here, not in the README.

## Definition of done

A behaviour change is done when:

1. **`nix flake check` is green.** It builds the guest image, shellchecks the wrapper, builds the
   docs (failing on dead internal links), and runs the host-side guarantee tests (secret hygiene,
   config staging, verbatim argv, mode selection). CI runs this on every PR.
2. **`bash tests/boot.sh` passes on a Nix+KVM box** — *if* you touched the guest, wrapper, or boot
   path. It boots a stub-`claude` VM and asserts the things that need a real guest (argv reaches
   claude, rw vs. overlay file visibility, egress, the encrypted disk). This is **not** in CI yet
   (it needs a KVM runner), so paste the `N passed, M failed` line in your PR. Defaults to TCG
   software emulation, so it runs anywhere — just slowly.
3. **A human `ccvm --shell` pass** (resize, `vim`, `less`, vi-mode) — *if* it touches the terminal
   path. Terminal fidelity is verified by hand, not automated.

See [Build / test / debug](build-test-debug.md) for the full loop, including the fast stub-`claude`
iteration pattern.

## Security invariants

Treat any change that weakens a [Security invariant](../security/invariants.md) as a bug: no secret
to disk/argv/seed, the host key stays pinned, only the CWD is shared. The host-side tests grep the
seed for the API key and the OAuth credential — keep them passing.

## Conventions

- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` for AI-assisted
  commits (lowercase `authored-by`, bare `Claude`).
- **Format before committing:** `nix fmt` (treefmt — `nixfmt` for Nix, `shfmt` for the shell
  scripts). CI enforces it via `checks.formatting`. See [Conventions](conventions.md) for the full
  set.

## macOS host support — help wanted

macOS host support is on the roadmap and is **community-driven**: the maintainer has no Apple
hardware. Help from nix-darwin folks — or anyone willing to do the porting work — would be very
welcome. The hard parts are the host-side bits that assume Linux: KVM/TCG acceleration selection, the
clipboard bridge's host reader (`wl-paste` / `xclip` → `pbpaste`), and QEMU's accel/networking flags.
The guest itself is a NixOS system and is unaffected. If you're interested, open an issue to
coordinate.

## License

By contributing you agree your contributions are licensed under the MIT License (see the repo's
`LICENSE`).
