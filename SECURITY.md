# Security Policy

`ccvm` runs Claude Code inside an ephemeral, RAM-only QEMU microVM — the VM *is* the security
boundary, so security reports are very welcome.

This file is the researcher-facing summary: how to report, and what is in and out of scope. The
**authoritative, detailed threat model** — the trust boundary, every security invariant, and the
rationale behind the settled trade-offs — lives in [CLAUDE.md](CLAUDE.md) ("Security invariants —
MUST NOT regress" and the default-posture / "Egress" sections). To reproduce the verification
yourself, a runnable pentest / regression playbook lives in
[`tests/security-reverification.md`](tests/security-reverification.md).

## Reporting a vulnerability

**Please report privately — do not open a public issue for a security bug.**

- **Email** (preferred): jxwi@proton.me
- Or GitHub **private vulnerability reporting** on this repo — *Security → Report a vulnerability* —
  to keep it on-platform.

Helpful to include: which boundary is crossed, the ccvm config in play (`egressAllowlist`,
`agentSudo`, `nix.enable`, `vmDiskSize`, `share.*`, `writableCwd`), your Nix version + host OS, and
a reproducer or PoC if you have one.

There is no formal response SLA yet — ccvm is pre-1.0, maintained by one person — but reports are
taken seriously and acknowledged as promptly as is realistic.

## Supported versions

ccvm is pre-1.0 and ships from a single line of development. Security fixes land on `main`; please
reproduce against the latest `main` before reporting.

## Scope

The trust boundary is the **QEMU virtual machine**. ccvm defends the **host filesystem** and the
**user's stored credentials** against a possibly prompt-injected in-VM agent.

**In scope** — these are the guarantees; a break is a vulnerability:

- Reading or writing the host filesystem **outside the single shared project directory** (e.g. via
  9p, symlink escape, or `security_model` tricks).
- The host's **stored login credential** (`~/.claude/.credentials.json`) crossing into the VM, or
  appearing in the seed / logs / argv / kernel cmdline.
- A secret from staged config surviving sanitization into the VM — `~/.claude.json` MCP tokens or
  headers, `git` credentials, or signing keys.
- With `egressAllowlist` set: a **non-root** in-VM agent reaching a non-allowlisted host/port, or
  flushing/altering the in-guest firewall — including regaining root (via sudo or a Nix
  trusted-user / `post-build-hook`) in order to do so.
- Recovering VM data after exit (the encrypted `vmDiskSize` pool; tmpfs `/home` and `/root`), or
  the LUKS key reaching the host.
- Bypassing the pinned SSH host key (MITM of the guest connection).

**Out of scope** — assumptions and non-goals (see CLAUDE.md, "Scope of the boundary"):

- Exploits of QEMU itself or of the guest **kernel**. We assume QEMU's device/Virtio isolation
  holds; ccvm is not a hardened hypervisor and does not defend the host against a malicious guest
  kernel.
- ccvm as a general-purpose VM manager — it builds exactly one guest, one way.

## Known, accepted trade-offs — not vulnerabilities

These are **documented design decisions** (full rationale in CLAUDE.md). Discussion is welcome, but
they are not treated as security bugs:

- **Open egress is the default.** With no `egressAllowlist`, a prompt-injected agent can read the
  project tree and **exfiltrate it**, and can reach host-loopback services via slirp `10.0.2.2`.
  The default buys *containment* (only the CWD crosses, nothing persists, the host login never
  auto-crosses) — **not** exfiltration resistance. Set `egressAllowlist` to close this.
- **Egress enforcement lives in the guest**, so it only binds a **non-root** agent. Setting
  `egressAllowlist` auto-drops the agent's sudo and Nix trusted-user status so the rule actually
  holds; forcing root back on alongside an allowlist re-opens it, by design.
- **Residual egress channels even with an allowlist:** low-bandwidth DNS tunneling through the stub
  resolver, and a session-static FQDN→IP pin that can go stale mid-session.
- **An in-VM `/login` token** lives in the (ephemeral, wiped-on-exit) tmpfs `~/.claude` and is
  readable by the in-VM agent — the same exposure as native `claude`, and under open egress it is
  exfiltratable. What ccvm guarantees is that the host's *stored* credential never crosses.
