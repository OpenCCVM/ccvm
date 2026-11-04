<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Threat model & scope

> These are the whole point of the project. Treat any change that weakens one of the
> [security invariants](invariants.md) as a bug.

## Scope of the boundary

The trust boundary is **QEMU**: we assume its device/Virtio isolation holds, and defend the *host
filesystem and the user's credentials* against a (possibly prompt-injected) agent.

Explicitly **out of scope**:

- Defending the host against a malicious *guest kernel*.
- Being a general-purpose VM manager — ccvm builds exactly one guest and boots it one way.

The VM being the boundary is what makes `--dangerously-skip-permissions` safe to opt into.
`writableCwd = false` adds a file-level safety net on top.

## Default posture — what the defaults do and don't stop

The [invariants](invariants.md) stop the host from being **persisted to or having its credentials
written to disk** — they do **not** sandbox what a prompt-injected agent can **read and send**.

Under the native-mirroring defaults (open egress + `share.*` on), the in-VM agent can read the whole
project tree and **exfiltrate it over open egress** (with `clipboard.images` on, also the host
clipboard *image* — never text; see [Image-paste bridge](image-paste.md)).

What it can **no longer read** is the host's OAuth login: the `share.*` allowlist stages only
settings/commands/memory, and `.credentials.json` is **excluded by construction** — claude starts
unauthenticated and the user's own in-VM `/login` or API key authenticates it. The host's **stored**
credential never crosses; but once authenticated in-VM, the resulting token lives in the ephemeral
tmpfs `~/.claude` and **is readable by the in-VM agent** (it has to be), so under open egress it is
exfiltratable — same class as the project tree.

The out-of-the-box win is **containment** (no host access beyond CWD, nothing persists) plus **the
host login never auto-crossing** — **not** project-exfiltration resistance, a deliberate DevEx
choice.

## The primary hardening knob

The primary hardening knob is [`egressAllowlist`](egress.md) (default-deny egress), enforced
**inside the guest** — so it only binds a non-root agent.

Setting `egressAllowlist` also **auto-drops the agent's sudo** and, under `nix.enable`, removes the
agent from Nix `trusted-users` — both load-bearing: a Nix trusted-user is root-equivalent
(`post-build-hook` runs as root) and would otherwise regain root to `nft flush` the rules
(audit S-1; fixed).

To disable all claude config sharing: set all `share.*` to `false`, or `CCVM_SHARE_CLAUDE_CONFIG=0`.

Keep this distinction accurate — understating it turns a sandbox into a liability.

## Reporting a vulnerability

Security reports go through GitHub's private vulnerability reporting for this repository (see
`SECURITY.md` in the repo root). Please don't open a public issue for anything that could be a
boundary break before it's triaged.
