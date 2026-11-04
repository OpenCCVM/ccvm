<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Options

Every setting below is a `programs.ccvm.*` option from the home-manager module. Most have a per-run
`CCVM_*` environment-variable override and, for a few, a `ccvm` command-line flag — see
[Per-run overrides](#per-run-overrides) at the bottom.

> **Egress is open by default** (like native `claude`), so a compromised agent could exfiltrate
> your project files (and anything you authenticate with inside the VM). Lock it down with
> [`egressAllowlist`](#egressallowlist). Full threat model: [Security](security/threat-model.md).

The options are ordered roughly by how often you'll reach for them — essentials first, escape
hatches last.

## Core

### `enable`

Install the `ccvm` command. Default: `false`. Type: boolean.

### `writableCwd`

Mount the host CWD (the project directory `ccvm` was launched in) read-write so the agent's edits
land on the host live. `false` keeps the CWD read-only with edits in an ephemeral overlay discarded
on exit. **Only this one directory ever crosses to the host.** Default: `true`. Type: boolean.

Per-run: `CCVM_WRITABLE_CWD`, or the `--writable-cwd` / `--read-only-cwd` flags.

### `memory`

How much RAM (in MiB) to allocate to the VM. Default: `4096`. Type: positive integer.
This is a runtime QEMU argument — changing it does **not** rebuild the guest. Per-run: `CCVM_MEMORY`.

### `cores`

How many vCPUs to allocate to the VM. Default: `4`. Type: positive integer.
Runtime QEMU argument — no rebuild.

### `acceleration`

Which acceleration mode to use. Default: `"auto"`. Type: `"auto"`, `"kvm"`, or `"tcg"`.

- `"auto"` — use KVM when `/dev/kvm` is usable, else fall back to TCG software emulation. Uses
  `-cpu max` so QEMU's own `-accel kvm:tcg` runtime fallback stays valid.
- `"kvm"` — require KVM. Hard-errors with an actionable reason (missing device / not in the `kvm`
  group / not writable) if it can't. Uses `-accel kvm` (no fallback) and `-cpu host`.
- `"tcg"` — force software emulation. Works anywhere, slowly.

Per-run: `CCVM_ACCEL`.

## Config sharing (`share.*`)

By default ccvm stages items from your host `~/.claude` into the VM so it behaves like native
`claude` — but **never** your login credential (`.credentials.json` is excluded by construction, not
by filter; see [Security invariants](security/invariants.md)).

### `share.settings`, `share.claudeMd`, `share.keybindings`, `share.commands`, `share.agents`, `share.skills`, `share.outputStyles`

Stage the named item from host `~/.claude` into the VM — your settings, context file (`CLAUDE.md`),
keyboard shortcuts, commands, agents, skills, and output styles respectively. Default: `true` for
all seven. Type: boolean.

`share.settings` also stages a **sanitized** copy of the home-root `~/.claude.json` — its known
secret-bearing keys (`mcpServers[].env`, `mcpServers[].headers`, the legacy `primaryApiKey`) are
stripped via `jq` before staging. See [Security invariants](security/invariants.md#claudejson).

Per-run: `CCVM_SHARE_SETTINGS`, `CCVM_SHARE_CLAUDEMD`, `CCVM_SHARE_KEYBINDINGS`,
`CCVM_SHARE_COMMANDS`, `CCVM_SHARE_AGENTS`, `CCVM_SHARE_SKILLS`, `CCVM_SHARE_OUTPUTSTYLES`.

### `share.plugins`, `share.config`

Opt-in sharing for `~/.claude/plugins` and `~/.claude/config`. Default: `false` for both. Type:
boolean. Per-run: `CCVM_SHARE_PLUGINS`, `CCVM_SHARE_CONFIG`.

### `share.gitConfig`

Stage a sanitized copy of your **global** git config so in-VM `git` commits as you, with your
aliases and ignores. No credentials or signing keys cross: every value containing a `/nix/store/`
path and **all** `credential.*` entries are dropped, commit/tag signing is force-disabled, and
`core.excludesfile` is staged by content. Default: `true`. Type: boolean. Per-run:
`CCVM_SHARE_GIT_CONFIG`.

### Disabling all config sharing at once

Set every `share.*` to `false`, or use the back-compat env var `CCVM_SHARE_CLAUDE_CONFIG=0` to
toggle all claude items off at once (per-item vars win over it). `CCVM_SHARE_CLAUDE_CONFIG=1`
re-enables them.

## Nix in the VM

### `nix.enable`

Enable Nix inside the VM. Default: `false` (read-only `/nix/store`, no in-VM nix, lean closure).
Type: boolean. This is **build-time** — it rebuilds the store as a writable overlay in the initrd.

Combine with [`vmDiskSize`](#vmdisksize) `> 0` to relocate the writable-store overlay onto the
encrypted disk so a large `nix develop` doesn't exhaust guest RAM. See
[Deliberate defaults](developing/defaults.md#ram-only-is-the-default).

### `nix.substituters`, `nix.trustedPublicKeys`

Extra binary caches for in-VM Nix and the public keys that verify paths from them. Default: `[]` for
both. Type: list of strings. A **public-read** signed cache works with zero secrets; a cache behind
a token/netrc is not yet supported. `require-sigs` stays on. See
[Design decisions → in-VM nix](developing/design-decisions.md#nix-in-the-vm).

## Persistence & disk

### `persistClaudeProjects`

Mount `~/.claude/projects` read-write so transcripts and memory persist back to the host
(cross-run `--resume`). Scoped to `projects/` only — nothing else under `~/.claude` is writable, so
the login credential (which lives at the `~/.claude` root) is still never writable. Default:
`false`. Type: boolean. Per-run: `CCVM_PERSIST_PROJECTS`.

### `vmDiskSize`

GiB of opt-in **encrypted, ephemeral** disk mounted at `/scratch` (and, under `nix.enable`, backing
the writable `/nix/store` overlay). `0` keeps the VM pure-RAM. The LUKS key is generated inside the
guest from `/dev/urandom` every boot and never leaves guest RAM, so the disk is inert ciphertext the
instant QEMU stops — wipe-on-exit is cryptographic. Default: `0`. Type: non-negative integer.
Per-run: `CCVM_VM_DISK_SIZE`. Adds ~4–5s to boot (per-boot `luksFormat`). See
[Encrypted disk](security/encrypted-disk.md).

## Clipboard

### `clipboard.images`

Make Ctrl+V **image paste** work inside the VM (like native `claude`) by bridging the host clipboard
image over the existing SSH connection. **Image-only** — host clipboard *text* never crosses — and
it opens no new network hole. Default: `true`. Type: boolean. Per-run: `CCVM_CLIPBOARD_IMAGES`
(only `0` is honored — disables image paste for the run). See
[Image-paste bridge](security/image-paste.md).

## Egress control

### `egressAllowlist`

FQDN / IP / CIDR egress allowlist. Empty = open egress (the default). Non-empty = a default-deny
firewall enforced **inside the guest**. `api.anthropic.com` is always allowed so Claude keeps
working. Default: `[]`. Type: list of strings.

```nix
programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" ];
```

Setting this **auto-drops the agent's sudo** ([`agentSudo`](#agentsudo)) and, under `nix.enable`,
removes the agent from Nix `trusted-users` — both load-bearing so a compromised agent can't flush
the in-guest firewall. Allowlisted FQDNs are pinned at launch to the IPs they resolve to. See
[Egress control](security/egress.md) for the full design and its residual channels.

> *Building* ccvm itself (or anything whose Nix closure includes `claude-code`) from **inside** an
> allowlisted VM also needs `storage.googleapis.com` on the list — that's where the unfree
> `claude-code` binary is downloaded from. Just *running* ccvm doesn't need it.

### `egressPorts`

Destination ports the allowlist permits. Default: `[ 443 ]`. Type: list of ports.

### `agentSudo`

Whether the in-VM agent gets passwordless root (sudo). `null` (default) = **auto**: on for DevEx
and `--shell` debugging, but automatically **off** when `egressAllowlist` is set (so a compromised
agent can't flush the in-guest egress firewall). `true`/`false` force it — but forcing `true`
alongside an `egressAllowlist` re-opens the bypass, so only do that behind host-side egress control.
Default: `null`. Type: `null` or boolean. Build-time (rebuilds the guest closure).

## Authentication & context

### `apiKeyVariable`

The host environment variable carrying the Anthropic API key, passed to the VM **only over SSH**
(never on disk, argv, or kernel command line). Default: `"ANTHROPIC_API_KEY"`. Type: string.

### `extraClaudeMd`

Markdown staged as the guest's `~/.claude/CLAUDE.md`, telling the agent it's running inside ccvm.
It is **appended** to any host-shared `CLAUDE.md`, never clobbering it. Default: a built-in blurb.
Type: lines (`""` disables). Per-run: `CCVM_CLAUDE_MD`.

## Escape hatches

### `extraPackages`

Additional packages to install into the VM. Default: `[]`. Type: list of strings (well, package
list). Build-time.

### `package`

The `claude-code` package to run in the VM. Default: `pkgs.claude-code` (the community
nix-claude-code build). Type: package. Build-time.

### `extraGuestModules`

Extra NixOS modules merged into the guest — a general escape hatch. Default: `[]`. Type: list of
modules. Build-time.

### `lockGuestMemory`

`mlock` guest RAM so in-VM secrets can't be paged to host swap. **Takes tinkering and isn't
recommended for most people** — QEMU refuses to start unless you raise the host's `RLIMIT_MEMLOCK`
(`ulimit -l`, systemd `LimitMEMLOCK`, or `limits.conf`). Only worth it if **(a)** your host swap is
unencrypted (the one case it actually buys something) or **(b)** you're willing to do that host
setup. Default: `false`. Type: boolean. Per-run: `CCVM_MLOCK`.

## Per-run overrides

A `CCVM_*` environment variable overrides the baked-in default for a single run; an explicit `ccvm`
flag wins over the env var.

| Option | Env var | Flag |
|---|---|---|
| `writableCwd` | `CCVM_WRITABLE_CWD` | `--writable-cwd` / `--read-only-cwd` |
| `acceleration` | `CCVM_ACCEL` | — |
| `memory` | `CCVM_MEMORY` | — |
| `share.settings` | `CCVM_SHARE_SETTINGS` | — |
| `share.claudeMd` | `CCVM_SHARE_CLAUDEMD` | — |
| `share.keybindings` | `CCVM_SHARE_KEYBINDINGS` | — |
| `share.commands` | `CCVM_SHARE_COMMANDS` | — |
| `share.agents` | `CCVM_SHARE_AGENTS` | — |
| `share.skills` | `CCVM_SHARE_SKILLS` | — |
| `share.outputStyles` | `CCVM_SHARE_OUTPUTSTYLES` | — |
| `share.plugins` | `CCVM_SHARE_PLUGINS` | — |
| `share.config` | `CCVM_SHARE_CONFIG` | — |
| all claude `share.*` at once | `CCVM_SHARE_CLAUDE_CONFIG` (`0`/`1`) | — |
| `share.gitConfig` | `CCVM_SHARE_GIT_CONFIG` | — |
| `persistClaudeProjects` | `CCVM_PERSIST_PROJECTS` | — |
| `clipboard.images` | `CCVM_CLIPBOARD_IMAGES` (only `0` honored) | — |
| `extraClaudeMd` | `CCVM_CLAUDE_MD` | — |
| `lockGuestMemory` | `CCVM_MLOCK` | — |
| `vmDiskSize` | `CCVM_VM_DISK_SIZE` | — |

ccvm-only flags (consumed by the wrapper, never forwarded to `claude`): `--writable-cwd`,
`--read-only-cwd`, `--shell` (debug shell), `--ccvm-debug` (stream console), `--ccvm-help`,
`--ccvm-version`. All other arguments pass through to `claude` unchanged — so bare `--help` and
`--version` still reach `claude`.
