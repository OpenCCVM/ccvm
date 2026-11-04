<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Build / test / debug

## Building

- Build the wrapper: `nix build .#ccvm`.
- **Iteration cost:** `memory` / `cores` are runtime QEMU args (cheap, no rebuild); changing
  `package` / `extraPackages` / `nix.enable` / guest modules rebuilds the guest closure.
- Buildable guest artifacts are honest packages: `nix build .#guest-store` (ro squashfs store) or
  `.#guest-toplevel` (system closure).
- Build the docs site: `nix build .#docs` → site in `./result`; open `result/index.html` to eyeball
  it.

## Iterate fast with a stub `claude`

The proven way to test file/config/arg behaviour without a real agent run: bake a shell script as
the `package` and assert on its stdout.

```nix
(import ./lib/mkccvm.nix { inherit pkgs; } {
  package = pkgs.writeShellScriptBin "claude" ''
    # print what the guest sees: mount type of $HOME/.claude, is settings.json
    # readable, does it contain the expected model, is .credentials.json present, …
  '';
}).wrapper
```

Boot it under `tcg` / `q35`, grep the output. This is exactly how `share.*` and `writableCwd` were
verified end-to-end — much faster than booting the real agent.

## `nix flake check`

`nix flake check` should pass — and is **warning-clean**. It:

- builds the guest image (the ro squashfs store),
- shellchecks the wrapper (via `writeShellApplication`),
- builds the docs site (`checks.docs`, which fails on dead internal links — see below),
- runs `tests/host.sh` (`checks.<sys>.host`) — host-side secret hygiene, config staging, verbatim
  argv, mode selection — against the real wrapper driven by its `CCVM_DRYRUN` hook (no VM, no
  claude-code),
- runs the `egress` and `clipboard` checks, and
- enforces formatting (`checks.formatting`: nixfmt + shfmt).

> The home-manager module is exposed as **`homeModules`** (the name stock Nix recognizes —
> `homeManagerModules` warns; don't reintroduce it).

### The docs check catches dead links

`checks.docs` builds the site with the **mdbook-linkcheck2** backend
(`[output.linkcheck2]` in `docs/book.toml`, `warning-policy = "error"`), so any broken **internal**
link breaks CI. mdBook's plain `mdbook build` does *not* fail on bad internal links on its own — the
backend is what makes it strict. External links are not followed (the Nix sandbox has no network).

### Introspecting guest config

The non-derivation bring-up handles (`append`, the evaluated `guestSystem`) are deliberately **not**
flake outputs; introspect them with a direct import — e.g. dump any guest config value:

```bash
nix eval --impure --expr 'let p = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
  in (import ./lib/mkccvm.nix { pkgs = p; } { nix.enable = true; egressAllowlist = ["x"]; }).guestSystem.config.nix.settings.trusted-users'
```

## Rebuilding the guest from inside a hardened-egress ccvm needs `storage.googleapis.com`

Any build that re-realizes the guest closure — `nix flake check`'s `guest-image` / `wrapper` checks,
`tests/boot.nix`, or `nix build .#ccvm` — must fetch the **unfree** `claude-code`, whose
fixed-output derivation downloads from `storage.googleapis.com`. That host is NOT in a typical
`egressAllowlist`, so from *inside* a hardened ccvm such a build hangs, then fails with
`cannot download claude from any mirror` — the egress firewall doing its job, not a bug. Add
`storage.googleapis.com` to the allowlist when you need to rebuild ccvm in-VM. The host-side checks
(`checks.<sys>.{host,egress}`) don't pull claude-code and build fine under any egress posture.

## Full-boot smoke test

`bash tests/boot.sh` (defaults to `CCVM_ACCEL=tcg CCVM_MACHINE=q35`) boots a stub-`claude` VM and
asserts argv-reaches-claude and overlay vs. rw file visibility.

**Boot-testing without working KVM:** force software emulation with `CCVM_ACCEL=tcg
CCVM_MACHINE=q35 ccvm` (slow but correct).

## Debug switches

- `CCVM_DEBUG=1` / `--ccvm-debug` streams the guest console and keeps the scratch dir.
- `CCVM_SHELL=1` / `--shell` drops into a guest zsh instead of claude.

**Terminal fidelity is human-verified**, not automated (`ccvm --shell`, then resize / vim / less /
vi-mode). Don't claim it works from code inspection alone.

## Definition of done for a behaviour change

`nix flake check` green **and** a stub-package boot test asserting the new behaviour under `tcg` /
`q35` — plus a human `--shell` pass if it touches the TTY.

## aarch64-linux is best-effort

It evaluates and is wired up (`qemu-system-aarch64`, the `virt` machine, PL011 `ttyAMA0` console),
but x86_64-linux is the primary, CI-built target.
