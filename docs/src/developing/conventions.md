# Conventions

## Stage, don't commit — commits are signed with a hardware key

The user signs every commit with a hardware security key, which is not reachable from inside the VM,
so agents never run `git commit`. When working a multi-step task, run the relevant checks (`bash -n`,
the `host.sh` dry-run recipe, and — on a Nix+KVM box — `nix flake check` / `bash tests/boot.sh` / a
`--shell` pass for TTY changes); if they're green, `git add` the change and hand the user the full
commit message (including the `Co-authored-by` trailer) as a copy-pasteable block — without stopping
to ask per item. If a commit was made anyway, `git reset --soft HEAD~1` to undo it with the changes
still staged. Still surface anything that can only be verified on the Nix+KVM box so it gets checked
there before being claimed done.

## Don't touch `README.md` without an explicit go-ahead

The user owns the README. Propose changes (even a one-word fix to a dangling reference) and wait for
an explicit OK before editing it — unlike the rest of the tree, it is not auto-fixable under the
stage-on-green rule.

## Audience split — write to the right altitude

- The **README** is newcomer-facing: approachable, for people new to ccvm and non-technical
  evaluators.
- This **docs site** (Security / Developing) is for the technical reader — security nuts,
  contributors — and is where the deep detail, threat-model nuance, edge cases, and settled-decision
  rationale live.
- **CLAUDE.md** is terse operational rules + a routing directive that points here.

When something surfaces, put the friendly version (if any) in the README, the real depth in this
site, and a one-line operational rule (if any) in CLAUDE.md. Don't duplicate depth across all three.

## Commit trailer (exact)

`Co-authored-by: Claude <noreply@anthropic.com>` — lowercase `authored-by`, bare `Claude`, no model
name. This intentionally differs from the Claude Code CLI default; use *this* form.

## Config flows through `@TOKENS@` {#config-flows-through-tokens}

Scalars are baked at build time in `mkccvm.nix` (`@MODE@` = `rw`/`overlay`,
`@SHARE_SETTINGS@` / `@SHARE_CLAUDEMD@` / `@SHARE_KEYBINDINGS@` / `@SHARE_COMMANDS@` /
`@SHARE_AGENTS@` / `@SHARE_SKILLS@` / `@SHARE_OUTPUTSTYLES@` / `@SHARE_PLUGINS@` / `@SHARE_CONFIG@` =
`1`/`0`, etc.).

Values only known at launch — the workspace 9p share and the SSH port — are **not** baked; the
wrapper builds those QEMU args at runtime (the microvm.nix "runtime-share trap").

Adding a new `@TOKEN@` means updating BOTH the bake in `mkccvm.nix` AND the stand-in token list in
`tests/default.nix` (the host test bakes the wrapper itself, with fixture values) — forget the
latter and the token stays literal, which `tests/host.sh` catches as a failure.

## Runtime override pattern

A `CCVM_*` env var overrides the baked default for one run (`CCVM_WRITABLE_CWD`,
`CCVM_SHARE_SETTINGS`, `CCVM_SHARE_CLAUDEMD`, `CCVM_SHARE_KEYBINDINGS`, `CCVM_SHARE_COMMANDS`,
`CCVM_SHARE_AGENTS`, `CCVM_SHARE_SKILLS`, `CCVM_SHARE_OUTPUTSTYLES`, `CCVM_SHARE_PLUGINS`,
`CCVM_SHARE_CONFIG`, `CCVM_MLOCK`, `CCVM_ACCEL`); an explicit `ccvm` flag wins over the env var.
Back-compat: `CCVM_SHARE_CLAUDE_CONFIG=0|1` toggles all claude items at once; per-item vars win over
it.

## `acceleration` is a declarative mode, baked as `@ACCELERATION@`

`auto` (default) uses KVM when `/dev/kvm` is usable else falls back to TCG, using `-cpu max` (not
`host`) so QEMU's own `-accel kvm:tcg` runtime fallback stays valid. `kvm` requires KVM: hard-errors
with an actionable reason (missing device / not in `kvm` group / not writable) and uses `-accel kvm`
(no fallback) + `-cpu host`. `tcg` forces emulation. Per-run: `CCVM_ACCEL`. The boot-wait budget is
generous for anything that might run emulated. The KVM-usability probe only checks the device is
writable (can't detect a present-but-broken KVM) — a real `KVM_CREATE_VM` failure surfaces as QEMU's
error (`kvm` mode) or a silent TCG fallback (`auto`). Tests drive modes via `CCVM_KVM_DEV` to
simulate `/dev/kvm` states portably.

## Formatting

`nix fmt` (treefmt — `nixfmt` for Nix, `shfmt` for the shell scripts). CI enforces it
(`checks.formatting`), so an unformatted tree fails `nix flake check`. Markdown is **excluded** from
treefmt (auto-reflow would wreck CLAUDE.md's char budget and the README), and `book.toml` is TOML,
also unformatted. `statix` / `deadnix` stay green too.
