<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Design decisions

Settled decisions — don't relitigate. These were considered and decided; reopening one needs a
*new* reason, not a rediscovery of the old trade-off.

## SSH transport, not the serial console — for PTY fidelity

A serial line is not a terminal: no `SIGWINCH`, no window size, no full termios, so resize breaks and
`vim` / `less` / full-screen TUIs corrupt. `ssh -tt` to a real sshd gives a genuine guest PTY that
propagates `TERM`, window size, `SIGWINCH` on every resize, and termios end-to-end — so the VM is
invisible. `-tt` *forces* PTY allocation even when the wrapper's own stdin isn't a tty. The wrapper
runs ssh in the foreground but **never `exec`s it**, so it regains control to tear the VM down.

## QEMU + slirp, not firecracker / cloud-hypervisor

We need outbound HTTPS with **zero host setup** — no bridges, TAP devices, or `sudo`. QEMU's
built-in slirp gives unprivileged user-mode NAT (guest 10.0.2.x, synthesised DNS+DHCP) plus
`hostfwd` for the inbound SSH port. The lighter VMMs boot faster but require host networking setup,
breaking "works on a stock box as a normal user." Boot speed matters; running unprivileged matters
more.

A consequence to know about: the guest can reach the host's loopback via slirp's `10.0.2.2` gateway.
See [Slirp host-loopback reachability](../security/slirp-loopback.md).

## Egress: an allowlist, not Tor

Tor solves *anonymity* (orthogonal — the API authenticates you by credential regardless; Tor adds
latency and hits exit blocking; users wanting anonymity run it on the host and the guest rides it).
Egress *control* belongs in ccvm; *anonymization* on the host. The full allowlist design, the three
residual channels, and the host-side-enforcement trilemma live in
[Egress control](../security/egress.md).

## Encrypted disk, not a plain ephemeral one

Wipe-on-exit must survive a crash that skips the cleanup trap, and on modern storage plain deletion ≠
erasure (async SSD TRIM, CoW snapshots retain freed blocks). With FDE the key dies with guest RAM at
power-off, so the image is inert ciphertext the instant QEMU stops — trap or no trap. The trap `rm`
is belt-and-suspenders; the guarantee rests on the key being gone. See
[Encrypted disk](../security/encrypted-disk.md).

## One encrypted pool, not a second `/nix/store` disk

Once the disk is encrypted with a guest-RAM key, disk-vs-tmpfs makes no confidentiality difference to
an in-guest attacker (it can read tmpfs or decrypt the disk equally). The right split is *bulk on the
encrypted disk, secrets in tmpfs* — by **placement**, not a second disk. A second disk only earns its
keep for a different lifecycle (persistent content-addressed store cache) — a separate future
feature, deliberately **not** folded into `vmDiskSize`.

## 9p for the shares, not virtiofs (and the large-tree edge case)

The workspace / seed / config / projects shares ride virtio-9p — zero host daemon, unprivileged,
zero setup. 9p with `cache=none` is latency-bound on *metadata*: each `stat` / `open` / `readdir` is
a host round-trip, so a **cold whole-tree walk** is sluggish while the agent's normal localized loop
feels native.

Calibration: **systemd-scale (~4k files) is a non-issue; the Linux kernel (~85k files, ~1.5 GB) is
the usable ceiling** — past that (100k+ tiny files) it crawls, but that isn't ccvm's user. The
real-world worst case is a huge gitignored dir (`node_modules` / `.venv` / `target`): `rg` / `fd`
skip gitignored paths; bulk build output belongs on `/scratch`.

**virtiofs is a deliberate non-goal pre-1.0:** it needs a per-share `virtiofsd` daemon +
shared-memory guest backend (reworking core QEMU `-m` args, the cleanup trap, and the
uid-remap/`security_model=none` path) — a multi-day change that reopens every share's security
verification, for a problem the audience rarely hits. Cheap lever: bump 9p `msize` and add a
mode-aware cache (`cache=loose` / `mmap` is fine for the ro overlay lower / config / seed, but risks
stale reads on the live rw workspace). Don't reach for virtiofs without that benchmark first.

## Nix in the VM {#nix-in-the-vm}

`nix.enable` is opt-in and **build-time**. When on, the store is rebuilt as a writable overlay in the
initrd; its upper is tmpfs by default and relocates to the encrypted disk when `vmDiskSize > 0`.

To give in-VM nix extra pre-built paths, point it at a **binary cache** via `nix.substituters` +
`nix.trustedPublicKeys`. A **public-read** signed cache works with zero secrets; a cache behind a
token/netrc is **not yet supported**. `require-sigs` stays on.

Two predecessors were **deliberately removed — do not re-add**: `mountHostNixStore` (host store as
the guest's boot store) and `nix.useHostStoreAsCache` (host `/nix/store` + DB over ro 9p as a local
substituter). 9p copy ran **slower than downloading** (<1 MiB/s vs. network), and it exposed the
*entire* host store to the agent. The guest always boots off the self-contained squashfs store; the
host store is never the guest's boot store.

## `claude-code` comes from a community flake; nixpkgs is pinned stable

nixpkgs is pinned to the **stable release (`nixos-26.05`)**, not `nixos-unstable`. The old reason for
unstable — tracking a fast-moving `claude-code` — no longer applies: `claude-code` now comes from the
**community `github:ryoppippi/nix-claude-code` flake** (input `claude-code`, `follows` our nixpkgs).
Its `overlays.default` sets `pkgs.claude-code`, so every existing `pkgs.claude-code` reference
(`lib/defaults.nix`, `guest/default.nix`) transparently picks up the community build, kept current
independent of the nixpkgs channel.

**It only reaches a home-manager consumer because `modules/home-manager.nix` closes over the
`claude-code` input and applies the overlay to the consumer's own `pkgs`** (`pkgs.extend`) — a
downstream flake has no view of our inputs otherwise; keep that wiring.

The package is **unfree**, so a *consuming* config must allow it: the README home-manager example's
`allowUnfreePredicate` does this, and the entry that works in a real build is **`claude-code`**
(verified on a real home-manager activation — `claude` alone is rejected; do not "simplify" it to
`claude`). ccvm's own standalone `pkgsFor` sets a blanket `allowUnfree = true`, so `nix run` / the
flake needs nothing extra. Its FOD downloads the prebuilt binary from `storage.googleapis.com` (see
the [hardened-egress note](build-test-debug.md#rebuilding-the-guest-from-inside-a-hardened-egress-ccvm-needs-storagegoogleapiscom)).

## No published binary cache (first-run stays a local build)

Most of the guest closure substitutes from `cache.nixos.org`, so first-run is bounded — mostly
download + the ccvm-specific squashfs/toplevel build (~minutes). The **unfree** `claude-code` path is
not on `cache.nixos.org`, and re-serving it from a public cache is a redistribution problem. Net:
bounded win, licensing headache. Don't re-propose a public cache without a new reason; if first-run
ever hurts, shrink the closure.

## Documentation: mdBook, not a JS SSG

The docs site is built with **mdBook** (Rust, via `pkgs.mdbook` in the flake) — no Node / Bun / npm.
ccvm stays 100% Nix and the site is byte-reproducible from a commit (pinned via `flake.lock`). A JS
SSG would reintroduce a lockfile/runtime into a pure-Nix security repo. The docs build is a `flake
check` (`checks.docs`) so the site can never silently break, and dead internal links fail the build
via the `mdbook-linkcheck2` backend.
