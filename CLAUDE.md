# CLAUDE.md

Working agreement for agents and contributors on **ccvm** — run Claude Code in an
ephemeral, RAM-only QEMU microVM with native-terminal fidelity. User docs live in
[README.md](README.md). This file is the authoritative engineering doc: the rules that
must not regress, the rationale behind the settled decisions, and the traps that cost
time to rediscover.

## Repo map

| Path | Role |
|---|---|
| `flake.nix` | Outputs: `packages.*.ccvm`, `homeManagerModules.default`. |
| `lib/mkccvm.nix` | The builder. Evaluates the guest NixOS system, then bakes its boot artifacts + scalar config into the wrapper via `builtins.replaceStrings` `@TOKENS@`. |
| `wrapper/ccvm.sh` | Host wrapper **template** (the `@TOKEN@` placeholders). Generates throw-away SSH keys, writes the seed, boots QEMU headless, `ssh -tt`s in, traps cleanup. |
| `guest/default.nix` | The microVM NixOS guest (tmpfs root, ro squashfs `/nix/store`). |
| `guest/launcher.nix` | Two units. `ccvm-seed.service` (root oneshot, `Before=sshd`) installs the pinned host key + `authorized_keys` and does every 9p/overlay mount. `ccvm-guest-launch` is the **unprivileged** sshd `ForceCommand` that just `cd`s to the workspace and execs claude (or zsh). |
| `guest/sshd.nix` | Hardened sshd: key-only, no root, single `ForceCommand`. |
| `modules/home-manager.nix` | `programs.ccvm.*` options → installs the command. |
| `tests/` | `host.sh` (CI host-side guarantees via the `CCVM_DRYRUN` hook), `boot.sh`+`stub-claude.sh`+`boot.nix` (local full-boot smoke test), `default.nix` (wires `host.sh` into `nix flake check`). |

## Security invariants — MUST NOT regress

These are the whole point of the project. Treat any change that weakens one as a bug.

**Scope of the boundary.** The trust boundary is QEMU: we assume its device/Virtio isolation
holds, and defend the *host filesystem and the user's credentials* against a (possibly
prompt-injected) agent. Explicitly out of scope: defending the host against a malicious *guest
kernel*, and being a general-purpose VM manager — ccvm builds exactly one guest and boots it one
way. The VM being the boundary is what makes `--dangerously-skip-permissions` safe to opt into
(`writableCwd=false` adds a file-level safety net on top).

**Default posture — what the defaults do and don't stop (be honest about this).** The
invariants below stop the *host* from being **persisted to or having its credentials written to
disk** — they do **not** sandbox what a prompt-injected agent can **read and send**. With the
native-mirroring defaults (open egress + `shareClaudeConfig=true`), the in-VM agent can read the
OAuth credential (`~/.claude/.credentials.json` rides the ro 9p mount so claude can auth) and the
whole project tree, and **exfiltrate either over open egress**. "Never copied to seed/disk"
protects the host from *persistence*, not the agent from *reading shared inputs*. So the
out-of-the-box win is **containment** (no host access beyond the CWD, nothing persists), **not
exfiltration resistance** — a deliberate DevEx choice, not a bug. The primary hardening knob is
`egressAllowlist` (default-deny egress; the API stays reachable); the strongest stance is
`shareClaudeConfig=false` + API-key auth, so the OAuth token never enters the VM at all. Keep
this distinction accurate in user-facing docs — under-stating it is the one thing that turns a
sandbox into a liability.

- **API key never touches disk/argv/kernel-cmdline.** It travels only over the SSH channel
  via `SendEnv`→`AcceptEnv`. Use `SendEnv`, **never** `SetEnv` (SetEnv puts it on the
  remote command line).
- **Host key is pinned.** Ephemeral ed25519 keys per run, `StrictHostKeyChecking=yes`.
  Never disable host-key checking to "make it work."
- **`shareClaudeConfig` never leaks the OAuth credential.** `~/.claude/.credentials.json`
  must ride the **read-only 9p mount** only — never copied into the scratch/seed dir. Only
  the non-secret `~/.claude.json` is staged through the seed. The config-deref staging loop
  selects `find -type l` and skips `.credentials.json` by name; keep both guards. Verify by
  running the staging loop standalone and grepping the seed dir for the credential — expect
  zero hits. **`persistClaudeProjects` (opt-in) does not change this:** it mounts only
  `~/.claude/projects` read-write; the credential lives at the `~/.claude` *root*, not under
  `projects/`, so it is never in that share. Never widen the writable mount to all of `~/.claude`.
- **`shareGitConfig` stages only sanitized, non-secret git config.** The wrapper resolves the
  **global** git config host-side and writes `seed/gitconfig` only after dropping every value
  containing `/nix/store/` (host-only tool paths that would dangle) and **all `credential.*`
  entries** (no host credential — `~/.ssh`, `gh` token — ever crosses), force-disabling commit/
  tag signing, and staging `core.excludesfile` by *content*. Keep all four guards. Verify by
  grepping the seed for any `/nix/store` path or `credential` key — expect zero hits.
- **No persistent disk.** Root is tmpfs; the store is a read-only image. Nothing the agent
  does survives exit except host-project edits while `writableCwd=true` — and, when the
  opt-in `persistClaudeProjects` is on, writes under `~/.claude/projects` (session transcripts
  + memory). Both are deliberate, narrowly-scoped write-throughs, not a general persistent disk.
  The opt-in `vmDiskSize` disk pool is **not** an exception: it is an *ephemeral* disk, wiped on
  exit (see next bullet). `/home` and root deliberately stay tmpfs, so secrets never go on the disk.
- **`vmDiskSize` pool: the LUKS key is guest-only, the disk is wiped on exit.** The host attaches
  a sparse image but **never** the key — the guest generates it from `/dev/urandom` in its own RAM
  and `luksFormat`s the device fresh every boot, so the host only ever sees ciphertext (verify: no
  key file in the seed; the wrapper writes only the `vm-disk` marker, never the key). Wipe-on-exit
  is cryptographic (the key dies with guest RAM → inert ciphertext even on a crash), with the trap
  `rm` as belt-and-suspenders. The host image MUST live in a disk-backed dir, never tmpfs/`$TMP`
  (that would put the "disk" back in RAM) — the wrapper refuses a tmpfs target unless
  `CCVM_SCRATCH_ALLOW_TMPFS=1`. The pool backs only **bulk, non-secret** data — `/scratch` and (with
  `nix.enable`) the writable `/nix/store` overlay upper, opened+mounted in the **initrd** by a fail-open
  LUKS oneshot (key still guest-only). Keep `/home`/secrets in tmpfs. Never stage the key through the seed.
- **`writableCwd=false` means genuinely read-only.** The host tree is the 9p **lower**;
  edits land in a tmpfs **upper** and must not reach the host.
- **Only the CWD is shared.** No `~/.ssh`, `~/.aws`, or home dir crosses the boundary.

## Deliberate defaults — do not reverse

- **Native mirroring is the default.** `writableCwd=true` (live host edits),
  `shareClaudeConfig=true` (reuse host `~/.claude`), and `shareGitConfig=true` (commit as you,
  with your aliases/ignores) make ccvm behave like native `claude`. Isolation (read-only
  project, no config) is the **opt-in**. Do not re-propose "secure by default" — that was the
  original spec and was deliberately reversed.
- **RAM-only is the default; the disk pool and in-VM nix are opt-in.** `vmDiskSize=0` (no disk,
  pure RAM) and `nix.enable=false` (read-only `/nix/store`, no in-VM nix, lean closure) are the
  defaults — keep boot fast and the no-disk stance unless asked. The user-facing option is
  `programs.ccvm.nix.enable`; the internal config + guest module use the **same** nested `nix.enable`
  name end to end (the old internal `nixInVm` flag was unified away — `lib/mkccvm.nix` passes the whole
  `nix` attr through). It is **build-time** (it flips `nix.enable` and rebuilds the store as a writable overlay in the
  initrd) — never try to make it a runtime `CCVM_*` env var. Its overlay upper is tmpfs (RAM) by
  default; combine with `vmDiskSize>0` and an initrd LUKS oneshot relocates that upper onto the
  encrypted disk (fail-open to tmpfs), so a large `nix develop` doesn't OOM guest RAM — one shared
  pool also backs `/scratch`. **The guest always boots off the self-contained squashfs store; the
  host store is never the guest's boot store.** To give in-VM nix extra pre-built paths, point it at a
  **binary cache** via `nix.substituters` + `nix.trustedPublicKeys` (typically your own self-hosted
  cache of tweaked deps). These are **pure guest-closure config** — baked into the guest's nix.conf
  (appended to `cache.nixos.org` and nixpkgs' keys), no wrapper token, no seed marker, no mount: a
  binary cache is **HTTP substitution**, reached over the network at line rate, exposing nothing of the
  host. `require-sigs` stays ON — paths must verify against `trustedPublicKeys`. A **public-read** signed
  cache works with zero secrets; a cache behind a token/netrc is **not yet supported** (ccvm carries no
  host credentials — a sanitized netrc-staging path, modeled on `shareGitConfig`, would be the future
  story). Two host-store-reuse predecessors were **deliberately removed — do not re-add either**:
  `mountHostNixStore` (host store as the guest's *boot* store) and `nix.useHostStoreAsCache` (host
  `/nix/store`+DB over **ro 9p** as a `local?root=…` substituter with a `db.sqlite` copy). The cache
  variant was implemented, KVM-verified, then cut: 9p copy ran **slower than downloading** (<1 MiB/s
  vs. network), it punched a hole in the isolation thesis (exposed the *entire* host store ro to the
  agent), and the audience that benefits from caching already runs a real binary cache — which the
  `substituters` option serves cleanly.
- **`extraClaudeMd` is default-on context, not a flag.** A built-in blurb is staged as the
  guest's `~/.claude/CLAUDE.md` (via the seed, **appended** to any host-shared one — never
  clobbering it) so the agent knows it's in ccvm. It must stay seed-delivered, never become
  `--append-system-prompt`, or it breaks transparent passthrough. The wrapper prepends a
  **runtime** mode line (rw=live / overlay=discarded) the build-time file can't know.
- **Transparent passthrough.** The wrapper injects **no** flags. Everything after `ccvm`
  is forwarded to `claude` verbatim, including `--dangerously-skip-permissions` (opt-in by
  the user, never auto-added). The *only* args the wrapper consumes (and does **not**
  forward) are its own: `--shell`, `--ccvm-debug`, `--writable-cwd`,
  `--read-only-cwd`, `--ccvm-help`, `--ccvm-version`. They are deliberately ccvm-specific
  names (none is a claude flag), so bare `--help`/`--version` still reach claude.
  Preserve that interception boundary.

## Why it's built this way (settled decisions — don't relitigate)

The rationale that used to live in `docs/design.md`. These were considered and decided;
reopening one needs a *new* reason, not a rediscovery of the old trade-off.

- **SSH transport, not the serial console — for PTY fidelity.** The load-bearing choice. A
  serial line is not a terminal: no `SIGWINCH`, no window size, no full termios, so resize
  breaks and `vim`/`less`/full-screen TUIs corrupt. `ssh -tt` to a real sshd gives a genuine
  guest PTY that propagates `TERM`, the initial window size, `SIGWINCH` on every resize, and
  termios end-to-end — so the VM is invisible. `-tt` *forces* PTY allocation even when the
  wrapper's own stdin isn't a tty. The wrapper runs ssh in the foreground but **never `exec`s
  it**, so it regains control to tear the VM down.
- **QEMU + slirp, not firecracker / cloud-hypervisor.** We need outbound HTTPS to the API with
  **zero host setup** — no bridges, TAP devices, or `sudo`. QEMU's built-in slirp gives
  unprivileged user-mode NAT (guest 10.0.2.x, synthesised DNS+DHCP) plus `hostfwd` for the
  inbound SSH port. The lighter VMMs boot faster but make you wire up host networking, which
  breaks "works on a stock box as a normal user." Boot speed matters; running unprivileged
  matters more.
- **Egress: an allowlist, not Tor.** Tor solves *anonymity*, which is orthogonal — the dominant
  flow is the Anthropic API authenticated with the user's own credential, so Tor hides the
  source IP while the app layer still identifies you exactly (self-defeating), adds latency, and
  hits Tor-exit blocking. It's also redundant: the guest egresses through the *host* stack, so a
  user who wants anonymity runs Tor/VPN on the host and the guest rides it for free. Egress
  *control* (where the agent may connect) belongs in ccvm; *anonymization* belongs on the host.
  The IP-filter MVP leaves three residual channels — each the job of a future SNI/DNS-filtering
  proxy, not the packet filter: **FQDN staleness** (the kernel sees IPs, so FQDNs are
  host-pre-resolved at launch into pinned A/AAAA records — a CDN like `api.anthropic.com`
  rotating mid-session breaks calls, so restart or pin a CIDR); **DNS tunneling** (DNS is pinned
  to the slirp stub resolver, blocking DNS-to-anywhere, but low-bandwidth tunneling through the
  recursive resolver remains); **TCP-only** (QUIC/UDP 443 is dropped; clients fall back to TCP).
- **Encrypted disk, not a plain ephemeral one.** Wipe-on-exit must survive a crash that skips
  the cleanup trap, and on modern storage plain deletion ≠ erasure (async SSD TRIM, CoW
  snapshots retain freed blocks). With FDE the key dies with guest RAM at power-off, so the image
  is inert ciphertext the instant QEMU stops — trap or no trap. The trap `rm` is
  belt-and-suspenders; the guarantee rests on the key being gone.
- **One encrypted pool, not a second `/nix/store` disk.** Once the disk is encrypted with a
  guest-RAM key, disk-vs-tmpfs makes no confidentiality difference to an in-guest attacker (it
  can read tmpfs or decrypt the disk equally). The right split is *bulk on the encrypted disk,
  secrets in tmpfs* — by **placement**, not a second sized disk. A second disk only earns its
  keep for a different *lifecycle* (a persistent, content-addressed store cache) — a separate
  future feature with its own key story, deliberately **not** folded into `vmDiskSize`.
- **9p for the shares, not virtiofs (and the large-tree edge case).** The workspace/seed/config/
  projects shares ride virtio-9p — zero host daemon, unprivileged, fits the zero-setup goal. 9p
  with `cache=none` (the default) is latency-bound on *metadata*: each `stat`/`open`/`readdir` is
  a host round-trip, so a **cold whole-tree walk** (a fresh `rg`/`git status`/`fd` over the entire
  tree) is sluggish, while the agent's normal localized loop (read a few files, edit, build) feels
  native. Calibration for the realistic audience: **systemd-scale (~4k files) is a non-issue; the
  Linux kernel (~85k files, ~1.5 GB) is the usable ceiling** — fine except the occasional cold
  whole-tree grep; past that (giant monorepos, 100k+ tiny files) it crawls, but that isn't ccvm's
  user. The real-world worst case is a huge gitignored dir (`node_modules`/`.venv`/`target`), and
  that's already handled: `rg`/`fd` skip gitignored paths, and bulk build output belongs on
  `/scratch` (`vmDiskSize`, native ext4). **virtiofs would be faster but is a deliberate non-goal
  pre-1.0:** it needs a per-share `virtiofsd` daemon + a shared-memory guest backend (reworking the
  core QEMU `-m` args, the cleanup trap that reaps the daemons, and the uid-remap/`security_model=none`
  passthrough path), a multi-day change that reopens every share's security verification — for a
  problem the audience rarely hits. The cheap lever *if* a kernel-scale user ever complains: bump
  9p `msize` and add a **mode-aware** cache (`cache=loose`/`mmap` is fine for the ro overlay
  lower/config/seed, but risks stale reads on the live **rw** workspace where host and guest both
  write — keep it conservative there). Don't reach for virtiofs without that benchmark first.
- **No published binary cache (first-run stays a local build).** Considered for `nix run` speed
  and declined. Most of the guest closure already substitutes from `cache.nixos.org`, so first-run
  is **bounded** — mostly download + the ccvm-specific squashfs/toplevel build (~minutes), not a
  giant compile. And re-serving the **unfree** `claude-code` path from a public cache is a
  **redistribution** problem (it's exactly why `cache.nixos.org` doesn't carry it). Net: bounded
  win, licensing headache — not worth it. Don't re-propose a public cache without a new reason; if
  first-run ever genuinely hurts, the lever is shrinking the closure, not redistributing claude-code.

## Build / test / debug

- Build the wrapper: `nix build .#ccvm`. **Iteration cost:** `memory`/`cores` are runtime
  QEMU args (cheap, no rebuild); changing `package`/`extraPackages`/`nix.enable`/guest
  modules rebuilds the guest closure.
- **Iterate fast with a stub `claude`** — the proven way to test file/config/arg behaviour
  without a real agent run. Bake a shell script as the `package` and assert on its stdout:

  ```nix
  (import ./lib/mkccvm.nix { inherit pkgs; } {
    package = pkgs.writeShellScriptBin "claude" ''
      # print what the guest sees: mount type of $HOME/.claude, is settings.json
      # readable, does it contain the expected model, is .credentials.json present, …
    '';
  }).wrapper
  ```

  Boot it under `tcg`/`q35`, grep the output. This is exactly how `shareClaudeConfig` and
  `writableCwd` were verified end-to-end — much faster than booting the real agent.
- `nix flake check` should pass. It builds the guest image, shellchecks the wrapper, and
  runs `tests/host.sh` (the `checks.<sys>.host` derivation) — host-side secret hygiene,
  config staging, verbatim argv, mode selection — against the real wrapper driven by its
  `CCVM_DRYRUN` hook (no VM, no claude-code). The `homeManagerModules`/`ccvmParts` "unknown
  flake output" warnings are pre-existing and cosmetic.
- **Full-boot smoke test:** `bash tests/boot.sh` (defaults to `CCVM_ACCEL=tcg
  CCVM_MACHINE=q35`) boots a stub-`claude` VM and asserts argv-reaches-claude and overlay
  vs. rw file visibility. This is the codified version of the stub-package boot test below.
- **Boot-testing without working KVM:** force software emulation with
  `CCVM_ACCEL=tcg CCVM_MACHINE=q35 ccvm` (slow but correct).
- `CCVM_DEBUG=1` / `--ccvm-debug` streams the guest console and keeps the scratch dir.
  `CCVM_SHELL=1` / `--shell` drops into a guest zsh instead of claude.
- **Terminal fidelity is human-verified**, not automated (`ccvm --shell`, then resize /
  vim / less / vi-mode). Don't claim it works from code inspection alone.
- **Definition of done for a behaviour change:** `nix flake check` green **and** a
  stub-package boot test asserting the new behaviour under `tcg`/`q35` — plus a human
  `--shell` pass if it touches the TTY.
- **aarch64-linux is best-effort.** It evaluates and is wired up (`qemu-system-aarch64`, the
  `virt` machine, PL011 `ttyAMA0` console), but x86_64-linux is the primary, CI-built target.

## Conventions

- **Commit automatically once all checks pass when working through a task list.** When working a
  multi-step task, run the relevant checks (`bash -n`, the `host.sh` dry-run recipe, and — on a
  Nix+KVM box — `nix flake check` / `bash tests/boot.sh` / a `--shell` pass for TTY changes); if
  they're green, commit without stopping to ask per item. Still surface anything that can only be
  verified on the Nix+KVM box so it gets checked there before being claimed done.
- **Don't touch `README.md` without an explicit go-ahead.** The user owns the README. Propose
  changes (even a one-word fix to a dangling reference) and wait for an explicit OK before
  editing it — unlike the rest of the tree, it is not auto-fixable under the commit-on-green rule.
- **Audience split — write to the right altitude.** The README is **newcomer-facing**:
  approachable, for people new to ccvm and non-technical evaluators. **CLAUDE.md is for the
  technical reader** — security nuts, contributors — and is where the deep detail, threat-model
  nuance, edge cases, and settled-decision rationale live. When something surfaces, put the
  friendly version (if any) in the README and the real depth here, not the other way round.
- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` — lowercase
  `authored-by`, bare `Claude`, no model name. This intentionally differs from the Claude
  Code CLI default; use *this* form.
- **Config flows through `@TOKENS@`.** Scalars are baked at build time in `mkccvm.nix`
  (`@MODE@` = `rw`/`overlay`, `@SHARECLAUDE@` = `1`/`0`, etc.). Values only known at launch
  — the workspace 9p share and SSH port — are **not** baked; the wrapper builds those QEMU
  args at runtime (the microvm.nix "runtime-share trap").
- **Runtime override pattern:** a `CCVM_*` env var overrides the baked default for one run
  (`CCVM_WRITABLE_CWD`, `CCVM_SHARE_CLAUDE_CONFIG`, `CCVM_MLOCK`, `CCVM_ACCEL`); an explicit `ccvm` flag
  wins over the env var.
- **`acceleration` is a declarative mode, baked as `@ACCELERATION@` (`auto`/`kvm`/`tcg`).** `auto`
  (default) uses KVM when `/dev/kvm` is usable else falls back to TCG, **never** erroring on accel —
  the friction-free first run; it uses `-cpu max` (not `host`) so QEMU's own `-accel kvm:tcg` runtime
  fallback stays valid on a present-but-broken KVM. `kvm` *requires* KVM: it hard-errors with an
  actionable reason (missing device / not in the `kvm` group / not writable) and uses `-accel kvm`
  (no fallback) + `-cpu host`. `tcg` forces emulation. Per-run: `CCVM_ACCEL`. The boot-wait budget is
  generous for anything that might run emulated (`ACCEL != kvm`) — the cap is a timeout, not a wait,
  so it never slows a fast KVM boot. The KVM-usability probe only checks the device is writable (it
  can't detect a present-but-broken KVM) — so a real `KVM_CREATE_VM` failure surfaces as QEMU's error
  (`kvm` mode) or a silent runtime fallback to TCG (`auto`). Tests drive the modes via `CCVM_KVM_DEV`
  (internal seam) to simulate `/dev/kvm` states portably.
- **Forwarded argv is NUL-separated** on the wire (`claude-args` in the seed, read with
  `mapfile -d ""`); spaces/quotes/globs survive intact. Never rebuild the argv by
  string-splitting.
- **Nix `''` string escaping** (wrapper + guest scripts are inside `''…''`): a literal bash
  `${var}` is written `''${var}`; `$(...)` and bare `$var` pass through literally.
- `wrapper/ccvm.sh` is built via `writeShellApplication`, so **shellcheck runs at build** —
  keep it clean (and the `set -euo pipefail` it injects in mind).

## Gotchas (expensive to rediscover)

- **9p preserves symlinks verbatim.** A host symlink pointing outside the exported tree
  (home-manager links `~/.claude/settings.json` → `/nix/store/…`) **dangles** in the guest.
  Fix already in place: dereference such links host-side into the seed, then lay the real
  files over the config overlay's tmpfs upper (shadowing the dead lower symlink).
- **Overlay copy-up hazard.** Never `chown -R` an overlay root — it copies *every* lower
  file up into the tmpfs upper. Chown only the specific files you staged.
- **microvm vs q35 use different virtio transports** (`virtio-mmio`/BUS=`device` vs
  `virtio-pci`/BUS=`pci`). The wrapper derives `BUS` from the machine type; keep new
  `-device` args going through it.
- **`ssh -tt` adds a PTY**, so guest stdout gets `\r` and escape sequences. When grepping
  captured guest output, use `grep -a` and `tr -d '\r'` or matches silently fail.
