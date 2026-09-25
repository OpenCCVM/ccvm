# Gotchas

Things that are expensive to rediscover.

## 9p preserves symlinks verbatim

A host symlink pointing outside the exported tree (home-manager links
`~/.claude/settings.json` → `/nix/store/…`) **dangles** in the guest. Fix already in place:
dereference such links host-side into the seed, then lay the real files over the config overlay's
tmpfs upper (shadowing the dead lower symlink).

## Overlay copy-up hazard

Never `chown -R` an overlay root — it copies *every* lower file up into the tmpfs upper. Chown only
the specific files you staged.

## microvm vs q35 use different virtio transports

`virtio-mmio` / BUS=`device` vs `virtio-pci` / BUS=`pci`. The wrapper derives `BUS` from the machine
type; keep new `-device` args going through it.

## `ssh -tt` adds a PTY

So guest stdout gets `\r` and escape sequences. When grepping captured guest output, use `grep -a`
and `tr -d '\r'` or matches silently fail.

## Ctrl+Z freezes the session — and there is NO guest-side fix {#ctrlz-freezes-the-session}

claude is `exec`'d as the sshd `ForceCommand` with NO job-control shell behind it, so a stopped
claude has nothing to `fg` it: a hard lockout (the VM has no second tty; the only escape, dropping
the SSH connection, tears down the whole VM).

The cause is **upstream Claude Code**: it reads Ctrl+Z in raw mode and raises a stop signal **on
itself** — specifically `SIGSTOP` (the Windows port crashes with "Unknown signal: SIGSTOP").
`SIGSTOP` is **uncatchable and unignorable**, so guest-side mitigation does not work — `stty susp
undef` (terminal SUSP) and `trap "" TSTP` (ignore SIGTSTP) were both tried and had **zero effect**
(removed; don't re-add — they only made `tests/boot.sh` pass while the bug persisted).

Ctrl+Z is also **not a rebindable keybinding** (the keybindings doc lists it under "Terminal
conflicts", not as an action), so `~/.claude/keybindings.json` cannot disable it. Same brick as
claudecode.nvim#194; related claude-code#3586 / #12483.

The only ccvm-side fix would be an **external supervisor that auto-`SIGCONT`s claude whenever it
stops** (an outside process *can* continue a SIGSTOP'd child) — **deliberately NOT pursued**: a C
helper plus job-control/foreground-pgrp handling is too much machinery for an upstream bug Anthropic
may yet make configurable. Documented instead as a user caveat (see
[Getting started → the Ctrl+Z caveat](../getting-started.md#the-ctrlz-caveat)). Don't disable
`-ixon` / Ctrl+S either — Ctrl+S is a claude keybinding (stash), not a freeze.

## The guest interactive shell is zsh, which has no `/dev/tcp`

Any in-guest TCP-connect probe (egress checks against the allowlist, the clipboard-bridge
`127.0.0.1:9180` reader) relies on bash's `/dev/tcp` pseudo-device; under the guest's zsh it fails
with `no such file or directory` and *falsely* reads as BLOCKED/dead. Wrap such probes in `bash -c`.
Test artifact only — the real clipboard shims are bash scripts (`writeShellScriptBin`), so they hit
`/dev/tcp` fine.

## 9p `msize` is negotiated DOWN

`guest/launcher.nix` requests `msize=1048576` (1 MiB), but QEMU's virtio-9p caps the *effective*
value (≈`512000` in practice — `grep msize /proc/mounts`). Harmless, but don't trust the requested
number when reasoning about 9p throughput.

## `vmDiskSize` adds ~4–5s to boot

The encrypted disk's device-settle plus the per-boot `luksFormat`. Measured baselines under KVM
(8 vCPU / 8 GiB): a full boot is ~7.3s (≈277ms kernel + 3.9s initrd + 3.1s userspace);
`systemd-analyze blame`'s top units are the `vdb` / `virtio-ccvm-scratch` device settling at ~4.6s.
The pure-RAM default boots faster; this cost is **inherent to the wipe-on-exit guarantee**, not a
regression. Other measured references: **warm 9p is a non-issue** (768-file repo walk ≈70ms,
`git status` ≈100ms); a running session sits around ~0.7–0.8 GiB RAM. See
[Encrypted disk](../security/encrypted-disk.md).

## Nix `''` string escaping

The wrapper + guest scripts are inside `''…''`: a literal bash `${var}` is written `''${var}`;
`$(...)` and bare `$var` pass through literally.

## The parallel `@TOKEN@` lists

Config flows through `@TOKENS@` baked at build time in `mkccvm.nix`. Adding a new `@TOKEN@` means
updating BOTH the bake in `mkccvm.nix` AND the stand-in token list in `tests/default.nix` (the host
test bakes the wrapper itself, with fixture values) — forget the latter and the token stays literal,
which `tests/host.sh` catches as a failure. See [Conventions → `@TOKENS@` flow](conventions.md#config-flows-through-tokens).

## Forwarded argv is NUL-separated

On the wire (`claude-args` in the seed, read with `mapfile -d ""`); spaces/quotes/globs survive
intact. Never rebuild the argv by string-splitting.

## `writeShellApplication` shellchecks at build

`wrapper/ccvm.sh` is built via `writeShellApplication`, so **shellcheck runs at build** — keep it
clean (and the `set -euo pipefail` it injects in mind).

## `cp -a` copies `/nix/store`'s read-only modes

home-manager config is symlinked into `/nix/store` (dirs `0555`, files `0444`), and `cp -aL`
preserves those modes into the seed. A read-only staged dir breaks two things: the nested
`.credentials.json` strip (unlinking needs a writable parent, so `find -delete` fails and the
credential leaks into the seed), and the exit-time `rm -rf` of the scratch dir (`Permission
denied` on exit). The wrapper runs `chmod -R u+w` on the staged copy before the strip, and again
on the scratch dir before cleanup. `tests/host.sh` makes its fake store read-only so a regression
shows up in the test.
