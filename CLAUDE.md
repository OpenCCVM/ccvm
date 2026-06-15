# CLAUDE.md

Working agreement for agents and contributors on **ccvm** — run Claude Code in an
ephemeral, RAM-only QEMU microVM with native-terminal fidelity.

This file is the **terse operational layer**: the must-not-regress rules, the repo map, the
conventions, and a routing directive into the docs. The **depth** — threat-model nuance, the
rationale behind every settled decision, the gotchas — now lives in the mdBook site under
`docs/src/` (built by `nix build .#docs`, deployed to GitHub Pages). User-facing docs live in
[README.md](README.md).

## MANDATORY reading directive

**Before doing ANY work, read the docs for the area you touch — this is mandatory, not optional.**
The checklist below is the *rule*; the linked page is the *why*, and you are expected to read it
before changing the relevant code.

- Touching security-sensitive components (guest, wrapper, QEMU args, seed/staging, egress, sshd,
  encrypted disk, clipboard bridge) **or anything that could introduce a security bug → READ ALL of
  `docs/src/security/` FIRST** (threat-model, invariants, egress, encrypted-disk, image-paste,
  slirp-loopback).
- Touching DevEx/UX (wrapper flags, `programs.ccvm.*` options, defaults, terminal/PTY, first-run) →
  read `docs/src/developing/` (defaults, design-decisions) + the relevant `docs/src/options.md` /
  `docs/src/getting-started.md`.
- Build/test/flake/CI work → read `docs/src/developing/build-test-debug.md`.
- Don't relitigate a settled decision without a NEW reason — they're documented in
  `docs/src/developing/design-decisions.md` and `docs/src/developing/defaults.md` precisely so they
  don't get rediscovered. Same for the traps in `docs/src/developing/gotchas.md`.

## Repo map

| Path | Role |
|---|---|
| `flake.nix` | Outputs: `packages.*` (`ccvm`, guest artifacts, `docs`), `checks.*`, `homeModules.ccvm`. |
| `lib/mkccvm.nix` | The builder. Evaluates the guest NixOS system, then bakes its boot artifacts + scalar config into the wrapper via `builtins.replaceStrings` `@TOKENS@`. |
| `lib/defaults.nix` | Default config values for the builder. |
| `lib/ccvm-context.md` | Built-in `extraClaudeMd` blurb staged as the guest's `~/.claude/CLAUDE.md`. |
| `wrapper/ccvm.sh` | Host wrapper **template** (the `@TOKEN@` placeholders). Generates completely ephemeral SSH keys, writes the seed, boots QEMU headless, `ssh -tt`s in, traps cleanup. |
| `guest/default.nix` | The microVM NixOS guest (tmpfs root, ro squashfs `/nix/store`). |
| `guest/launcher.nix` | `ccvm-seed.service` (root oneshot, `Before=sshd`) installs the pinned host key + `authorized_keys` and does every 9p/overlay mount. `ccvm-guest-launch` is the **unprivileged** sshd `ForceCommand` that `cd`s to the workspace and execs claude (or zsh). |
| `guest/sshd.nix` | Hardened sshd: key-only, no root, single `ForceCommand`. |
| `modules/home-manager.nix` | `programs.ccvm.*` options → installs the command. |
| `docs/` | The mdBook site (`book.toml`, `src/`). Built by `packages.docs`, gated by `checks.docs` (fails on dead internal links). |
| `tests/` | `host.sh` (CI host-side guarantees via the `CCVM_DRYRUN` hook), `boot.sh`+`stub-claude.sh`+`boot.nix` (local full-boot smoke test), `clipboard.sh`, `egress.sh`, `default.nix` (wires the checks into `nix flake check`). |

## Security invariants — MUST NOT regress (CHECKLIST)

The whole point of the project. Treat any change that weakens one as a bug. One line each — the
**rule**; the **full detail + verification steps** are in the linked page, which you must read before
touching the relevant code.

The boundary is **QEMU**; it defends the host filesystem + the user's credentials against a
(possibly prompt-injected) in-VM agent. The defaults give **containment + the host login never
auto-crossing**, NOT project-exfiltration resistance (open egress is deliberate; `egressAllowlist`
is the hardening knob). — full detail: `docs/src/security/threat-model.md`.

- **API key never touches disk/argv/kernel-cmdline** — SSH `SendEnv`→`AcceptEnv` only; never
  `SetEnv`. — `docs/src/security/invariants.md`
- **Host key is pinned** — ephemeral ed25519 per run, `StrictHostKeyChecking=yes`; never disable it.
  — `docs/src/security/invariants.md`
- **`share.*` excludes the OAuth credential by construction** — `.credentials.json` is not a
  `share.*` item so it's never staged; guest lays staged items into fresh tmpfs `~/.claude`; claude
  starts unauthenticated. `persistClaudeProjects` only mounts `~/.claude/projects` rw — never widen.
  — `docs/src/security/invariants.md`
- **`~/.claude.json` staged SANITIZED** — `jq` strips `mcpServers[].env`/`.headers` + legacy
  `primaryApiKey`; secure-fail if `jq` missing/invalid JSON. New secret key → add to the `del(...)`.
  — `docs/src/security/invariants.md#claudejson`
- **`share.gitConfig` sanitized** — drop `/nix/store/` values + all `credential.*`, force-disable
  signing, stage `core.excludesfile` by content. Keep all four guards. —
  `docs/src/security/invariants.md`
- **No persistent disk** — root tmpfs, store ro; only host-CWD edits (rw mode) and opt-in
  `~/.claude/projects` survive. `vmDiskSize` is an *ephemeral* encrypted disk, not an exception. —
  `docs/src/security/invariants.md`
- **`vmDiskSize` LUKS key is guest-only, disk wiped on exit** — guest `luksFormat`s from
  `/dev/urandom` every boot; host sees only ciphertext; never stage the key; image must be
  disk-backed not tmpfs. — `docs/src/security/encrypted-disk.md`
- **`writableCwd=false` means genuinely read-only** — host tree is the 9p lower; edits land in a
  tmpfs upper and must not reach the host. — `docs/src/security/invariants.md`
- **Only the CWD is shared** — no `~/.ssh`, `~/.aws`, or home dir crosses. —
  `docs/src/security/invariants.md`
- **QEMU sandboxed; ccvm never runs as host root; 9p shares `nosuid,nodev`** — `-sandbox on,...`;
  wrapper refuses host uid 0; shares not `noexec` (workspace runs build scripts). Don't regress any
  of the three. — `docs/src/security/invariants.md`
- **Egress enforcement lives in the GUEST**, so it only binds a non-root agent — `egressAllowlist`
  auto-drops `agentSudo` AND (under `nix.enable`) the agent's Nix `trusted-users` membership; both
  load-bearing (a trusted-user is root-equivalent and could `nft flush`). Forcing `agentSudo=true`
  alongside an allowlist re-opens the bypass. — `docs/src/security/egress.md`
- **Guest kernel/userspace hardening** — `protectKernelImage`, hardening sysctls, `sudo-rs`, root
  password lock, pinned `allowed-users`. NOT `lockKernelModules` (breaks runtime modprobe), NOT
  disabling userns (nix build sandbox needs it). — `docs/src/security/invariants.md`

## Conventions

- **Commit automatically once all checks pass when working through a task list.** Run the relevant
  checks (`bash -n`, the `host.sh` dry-run recipe, and — on a Nix+KVM box — `nix flake check` /
  `bash tests/boot.sh` / a `--shell` pass for TTY changes); if green, commit without stopping to ask
  per item. Surface anything only verifiable on a Nix+KVM box so it gets checked before being
  claimed done.
- **Definition of done for a behaviour change:** `nix flake check` green **and** a stub-package boot
  test asserting the new behaviour under `tcg`/`q35` — plus a human `--shell` pass if it touches the
  TTY. Full loop + the fast stub-`claude` pattern: `docs/src/developing/build-test-debug.md`.
- **Don't touch `README.md` without an explicit go-ahead.** The user owns the README. Propose
  changes (even a one-word fix) and wait for an explicit OK — it is NOT auto-fixable under the
  commit-on-green rule. (The docs site and CLAUDE.md *are* auto-fixable.)
- **Audience split:** README = newcomer; `docs/src/` Security/Developing = depth; CLAUDE.md = terse
  operational + routing. Put the friendly version in the README, the real depth in the site, the
  one-line rule here. Don't duplicate depth across all three.
- **Commit trailer (exact):** `Co-authored-by: Claude <noreply@anthropic.com>` — lowercase
  `authored-by`, bare `Claude`, no model name. Differs from the Claude Code CLI default; use *this*.
- **Config flows through `@TOKENS@`.** Scalars baked at build time in `mkccvm.nix`. Adding a new
  `@TOKEN@` means updating BOTH the bake in `mkccvm.nix` AND the stand-in list in `tests/default.nix`
  — forget the latter and the token stays literal, which `tests/host.sh` catches. Runtime-only
  values (workspace 9p share, SSH port) are built by the wrapper at launch, not baked. —
  `docs/src/developing/conventions.md`
- **Runtime override pattern:** a `CCVM_*` env var overrides the baked default for one run; an
  explicit `ccvm` flag wins over the env var. `CCVM_SHARE_CLAUDE_CONFIG=0|1` toggles all claude
  `share.*` at once; per-item vars win. Full var/flag table: `docs/src/options.md`.
- **Forwarded argv is NUL-separated** (`claude-args`, read with `mapfile -d ""`); never rebuild it
  by string-splitting. **Nix `''` escaping:** a literal bash `${var}` is written `''${var}`.
  **`wrapper/ccvm.sh` shellchecks at build** (`writeShellApplication`, `set -euo pipefail`). More
  traps: `docs/src/developing/gotchas.md`.
- **Format before committing:** `nix fmt` (nixfmt + shfmt); CI enforces it via `checks.formatting`.
  Markdown (incl. `docs/src/`) and the YAML workflows are excluded from treefmt. `statix`/`deadnix`
  stay green too.

## Docs site

The site under `docs/src/` is the single source of truth for extended content. Edit the relevant
page when you change behaviour (it's auto-fixable under commit-on-green, unlike the README). Build
and preview locally with `nix build .#docs` (open `result/index.html`) or `mdbook serve docs` from
the devShell. `checks.docs` fails CI on dead **internal** links (mdbook-linkcheck2,
`warning-policy = "error"`), so keep cross-references valid. When you add a security/design fact
here, put its depth in the site and leave only the one-line rule in this file.
