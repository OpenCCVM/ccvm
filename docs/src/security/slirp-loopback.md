<!-- SPDX-License-Identifier: MIT
  -- Copyright (C) 2026 Jaxxen
  -->

# Slirp host-loopback reachability

ccvm uses QEMU's built-in slirp user-mode networking (see
[Design decisions → QEMU + slirp](../developing/design-decisions.md#qemu--slirp-not-firecracker--cloud-hypervisor)).
A property of slirp worth knowing about:

## The guest can reach the host's loopback via `10.0.2.2`

slirp maps its gateway `10.0.2.2` to the *host's* `127.0.0.1`. Verified: from the guest,
`10.0.2.2:22` answers with the **host's own sshd**.

So under **open egress (the default), any host service bound to `127.0.0.1` is reachable from inside
the VM** — local databases, unauthenticated dashboards, model servers (e.g. Ollama on 11434),
cloud metadata/credential proxies, a second ccvm. Many of these are unauthenticated *precisely
because* they assume only host-local processes reach them.

This is **network reach only, not a host-write path** — the filesystem boundary still holds. It
matters most when ccvm runs on a host with sensitive loopback-bound services.

## Closing it

An [`egressAllowlist`](egress.md) closes it: `10.0.2.2` isn't in the set, so the default-deny
firewall drops it along with everything else not allowlisted.

There is **no slirp knob** to keep internet access but drop only the host redirect (`restrict=on`
kills both). The only *complete* fix is the host-side namespace approach described under
[Egress → host-side enforcement](egress.md#why-not-complete-host-side-enforcement-yet), which is
gated on host setup and remains future work.
