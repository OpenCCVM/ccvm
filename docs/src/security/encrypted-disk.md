<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Encrypted disk & wipe-on-exit

The opt-in `vmDiskSize` (GiB) attaches a sparse disk image to back **bulk, non-secret** data:
`/scratch`, and — under `nix.enable` — the writable `/nix/store` overlay upper. `vmDiskSize = 0`
(the default) keeps the VM pure-RAM.

## The LUKS key is guest-only

The host attaches the sparse image but **never** the key. The guest generates the key from
`/dev/urandom` in its own RAM and `luksFormat`s the disk fresh **every boot**, so the host only ever
sees ciphertext. (Verify: no key file in the seed; the wrapper writes only the `vm-disk` marker,
never the key.)

The disk is mounted in the **initrd** by a fail-open LUKS oneshot — if it can't set up, the system
falls back to a tmpfs upper rather than failing to boot.

## Wipe-on-exit is cryptographic

The key dies with guest RAM at power-off, so the image is inert ciphertext the instant QEMU stops —
trap or no trap. The cleanup trap's `rm` is belt-and-suspenders; the guarantee rests on the key
being gone.

This is **why an encrypted disk rather than a plain ephemeral one**: wipe-on-exit must survive a
crash that skips the cleanup trap, and on modern storage plain deletion ≠ erasure (async SSD TRIM,
CoW snapshots retain freed blocks). With full-disk encryption, the image is unrecoverable the moment
the key is gone, regardless of how the process ended.

## Why one encrypted pool, not a second `/nix/store` disk

Once the disk is encrypted with a guest-RAM key, disk-vs-tmpfs makes no confidentiality difference
to an in-guest attacker (it can read tmpfs or decrypt the disk equally). The right split is *bulk on
the encrypted disk, secrets in tmpfs* — by **placement**, not a second disk. A second disk only
earns its keep for a different lifecycle (a persistent content-addressed store cache) — a separate
future feature, deliberately **not** folded into `vmDiskSize`.

## Where the image must live

The host image MUST live in a disk-backed directory, **never** tmpfs / `$TMP` — that would put the
"disk" back in RAM and defeat the point. The wrapper refuses a tmpfs target unless
`CCVM_SCRATCH_ALLOW_TMPFS=1`.

`/home` and root deliberately stay tmpfs, so secrets never go on the disk. Never stage the LUKS key
through the seed.

## Cost

`vmDiskSize > 0` adds **~4–5s to boot** — the encrypted disk's device-settle plus the per-boot
`luksFormat`. This cost is **inherent to the wipe-on-exit guarantee** (a fresh `luksFormat` every
boot, by design), not a regression. The pure-RAM default boots faster.

Measured baselines under KVM (8 vCPU / 8 GiB): a full boot is ~7.3s (≈277ms kernel + 3.9s initrd +
3.1s userspace); `systemd-analyze blame`'s top units are the disk device settling at ~4.6s. A
running session sits around ~0.7–0.8 GiB RAM because the squashfs store and writable-store overlay
upper live on the encrypted disk.
