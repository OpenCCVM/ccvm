# Security invariants — MUST NOT regress

These are the whole point of the project. Treat any change that weakens one as a bug. They stop the
host from being **persisted to or having its credentials written to disk**. (For what they
deliberately do *not* stop, see [Threat model & scope](threat-model.md).)

## API key never touches disk / argv / kernel-cmdline

The API key travels only over the SSH channel via `SendEnv`→`AcceptEnv`. Use `SendEnv`, **never**
`SetEnv` (`SetEnv` puts it on the remote command line).

## Host key is pinned

Ephemeral ed25519 keys per run, `StrictHostKeyChecking=yes`. Never disable host-key checking to
"make it work."

## The `share.*` allowlist excludes the OAuth credential — airtight by construction

The `share.*` items are the ONLY things staged from `~/.claude` into the seed. The credential
(`.credentials.json`) is not a `share.*` item and is therefore **never copied into the seed** —
exclusion is by omission, not by filter. Two defenses reinforce this:

1. The per-item `cp -aL` only copies the listed paths, so the credential is never touched.
2. A defense-in-depth `find $SEED/claude-config -name .credentials.json -delete` strips any nested
   one that a directory `cp` might drag in. The staged copy is `chmod -R u+w`'d first (a
   read-only `/nix/store` parent dir would otherwise make the delete fail silently), and the
   wrapper **secure-fails** (`die`) if any `.credentials.json` survives the strip. See
   [Gotchas](../developing/gotchas.md).

The guest lays staged items into a fresh **tmpfs** `~/.claude` at boot. Claude starts
unauthenticated; the user's `/login` or API key authenticates it ephemerally. This also avoids OAuth
refresh-token rotation: the rotated in-VM token dies with the tmpfs, leaving the host's stored token
valid.

**Verify:** `grep -rl '\.credentials\.json' "$SEED"` → zero hits.

**`persistClaudeProjects` (opt-in) does not change this:** it mounts only `~/.claude/projects`
read-write; the credential lives at the `~/.claude` *root*. Never widen the writable mount to all of
`~/.claude`.

## `~/.claude.json` is staged SANITIZED — its known secret-bearing keys are stripped {#claudejson}

The home-root `~/.claude.json` (distinct from `~/.claude/`) can carry MCP server configs with inline
secrets. When `share.settings` is on, the wrapper stages it through `jq`, dropping
`mcpServers[].env`, `mcpServers[].headers`, and the legacy `primaryApiKey`; the non-secret structure
(including server definitions) is kept.

**Secure-fail:** if `jq` is missing or the file is invalid JSON, nothing is staged — hence `jq` is a
wrapper `runtimeInput`.

**Verify:** a fixture with an MCP env token + auth header + `primaryApiKey` → grep
`seed/claude-json` for the secrets → zero hits, with `userID` + server name still present
(`tests/host.sh` §1b). If a new secret-bearing key appears, add it to the `jq del(...)`.

## `share.gitConfig` stages only sanitized, non-secret git config

The wrapper resolves the **global** git config host-side and writes `seed/gitconfig` only after:

- dropping every value containing `/nix/store/`,
- dropping **all `credential.*` entries**,
- force-disabling commit/tag signing, and
- staging `core.excludesfile` by *content*.

Keep all four guards. **Verify** by grepping the seed for any `/nix/store` path or `credential` key
— expect zero hits.

## No persistent disk

Root is tmpfs; the store is a read-only image. Nothing the agent does survives exit except
host-project edits while `writableCwd = true` — and, when the opt-in `persistClaudeProjects` is on,
writes under `~/.claude/projects` (session transcripts + memory). Both are deliberate,
narrowly-scoped write-throughs, not a general persistent disk.

The opt-in `vmDiskSize` disk pool is **not** an exception: it is an *ephemeral* disk, wiped on exit.
`/home` and root deliberately stay tmpfs, so secrets never go on the disk.

## `vmDiskSize` pool: the LUKS key is guest-only, the disk is wiped on exit

The host attaches a sparse image but **never** the key — the guest generates it from `/dev/urandom`
in its own RAM and `luksFormat`s fresh every boot, so the host only ever sees ciphertext (verify: no
key file in the seed; the wrapper writes only the `vm-disk` marker, never the key). Wipe-on-exit is
cryptographic (key dies with guest RAM), with the trap `rm` as belt-and-suspenders.

The host image MUST live in a disk-backed dir, never tmpfs/`$TMP` (that would put the "disk" back in
RAM) — the wrapper refuses a tmpfs target unless `CCVM_SCRATCH_ALLOW_TMPFS=1`. The pool backs only
**bulk, non-secret** data — `/scratch` and (with `nix.enable`) the writable `/nix/store` overlay
upper, mounted in the **initrd** by a fail-open LUKS oneshot (key still guest-only). Keep
`/home`/secrets in tmpfs. Never stage the key through the seed. See
[Encrypted disk](encrypted-disk.md).

## `writableCwd = false` means genuinely read-only

The host tree is the 9p **lower**; edits land in a tmpfs **upper** and must not reach the host.

## Only the CWD is shared

No `~/.ssh`, `~/.aws`, or home dir crosses the boundary.

## QEMU is sandboxed; ccvm never runs as host root; 9p shares are `nosuid,nodev`

QEMU launches with `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`
so a device-emulation / 9p / slirp escape hits a seccomp wall (`CCVM_QEMU_SANDBOX=0` is the escape
hatch).

The wrapper refuses host uid 0 — 9p `security_model=none` passthrough as root would let the guest
create root-owned/setuid files on the host workspace (`CCVM_ALLOW_ROOT=1` overrides).

Every 9p share is mounted `nosuid,nodev` (deliberately not `noexec` — the workspace needs to run
project binaries/build scripts). Don't regress any of the three.

## Guest kernel/userspace hardening

In-guest defense-in-depth against an agent probing the kernel (`guest/default.nix`):

- **`security.protectKernelImage`** — no kexec/hibernation. (*Not* `lockKernelModules`, which would
  break the seed service's runtime `modprobe` of `nf_tables`/`dm_crypt`.)
- **sysctls** — `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`,
  `bpf_jit_harden=2`, `rp_filter=1`.
- **`sudo-rs`** — memory-safe Rust sudo (`execWheelOnly`) in place of classic C sudo, still gated on
  `agentSudo`.
- an **explicit `root.hashedPassword = "!"`**, and
- a pinned **`nix.settings.allowed-users = [ "root" "ccvm" ]`**.

Not done: `lockKernelModules` (incompatible with runtime modprobe) and disabling unprivileged user
namespaces (the nix build sandbox needs them; namespaced-root can't reach the init-netns firewall —
audit-verified, not a containment hole).
