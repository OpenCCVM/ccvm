# Egress control

`egressAllowlist` is ccvm's primary hardening knob. Empty (the default) = open egress, just like
native `claude`. Non-empty = a default-deny firewall: only the FQDNs / IPs / CIDRs you list (plus
`api.anthropic.com`, always allowed) can be reached.

```nix
programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" ];
```

## An allowlist, not Tor

Tor solves *anonymity* — which is orthogonal here: the API authenticates you by credential
regardless, and Tor adds latency and hits exit blocking. Users who want anonymity run Tor on the
host and the guest rides it. Egress *control* belongs in ccvm; *anonymization* belongs on the host.

## How it's enforced

The firewall is installed inside the guest by a **root systemd unit** (not the agent), using
`nftables`. Allowlisted FQDNs are pre-resolved **host-side** at launch into a name→IP map
(`egress-hosts`), written into the guest's `/etc/hosts`, so the agent resolves each FQDN to exactly
the IP the firewall allows. DNS is pinned to the slirp stub resolver.

## The agent is told its reachable hosts

A default-deny firewall fails *silently*: a request to a blocked host hangs until it times out,
which reads to an agent like a flaky network, so it retries and burns turns. To avoid that, the
per-run `# ccvm session` header ccvm prepends to the guest `~/.claude/CLAUDE.md` names the **exact**
reachable hosts this run — the allowlist plus the always-added `api.anthropic.com` — and tells the
in-VM agent that anything else will hang, not to attempt it, and to hand unreachable fetches (and
host-credential work like `git fetch`/`push`) back to the user in a copy-pasteable block. Built in
`wrapper/ccvm.sh` from the resolved `EGRESSALLOW`; the generic handoff rules live in
`lib/ccvm-context.md`. So a locked allowlist changes agent *behaviour*, not just packet fate.

## The load-bearing caveat: enforcement lives in the guest

Because enforcement lives in the guest, it only binds a **non-root** agent — a root agent could
`nft flush` it. That's why setting `egressAllowlist`:

- **auto-drops `agentSudo`**, and
- under `nix.enable`, **drops the agent from Nix `trusted-users`**.

A Nix trusted-user is root-equivalent (a `post-build-hook` runs as root); audit S-1 demonstrated the
bypass end-to-end, now closed. Together these raise the bar from one command to a guest-kernel
exploit. A non-trusted agent can still `nix build` / `nix develop` (builds run as the `nixbld`
users).

> Forcing `agentSudo = true` alongside an `egressAllowlist` re-opens the `nft flush` bypass (and
> re-grants trusted-user), so it's only sensible behind host-side egress control.

## The three residual channels

The IP-filter MVP has three residual channels — known and accepted, not bugs:

1. **FQDN staleness.** The kernel sees IPs, not names. ccvm pins each allowlisted FQDN to the IPs it
   resolved to at launch, in both the firewall and the guest resolver. Residual: a host that rotates
   *every* pinned IP away mid-session breaks — restart, or pin a CIDR for round-robin hosts. (GitHub
   publishes its ranges at `api.github.com/meta`.)
2. **DNS tunneling.** DNS is pinned to the slirp stub resolver, blocking DNS-to-anywhere, but
   low-bandwidth tunneling through the recursive resolver remains.
3. **TCP-only.** QUIC / UDP 443 is dropped; clients fall back to TCP.

## Building ccvm from inside a hardened VM

Any build that re-realizes the guest closure must fetch the **unfree** `claude-code`, whose
fixed-output derivation downloads from `storage.googleapis.com` (deliberately never on a binary
cache). That host is **not** in a typical allowlist, so from inside a hardened ccvm such a build
hangs, then fails with `cannot download claude from any mirror` — the firewall doing its job, not a
bug. Add `storage.googleapis.com` to the allowlist when you need to rebuild ccvm in-VM.

## Why not complete host-side enforcement (yet)

The *complete* fix is **host-side egress enforcement**: put the allowlist `nft` in a namespace the
guest can't reach, with a filtered uplink via `pasta` / `slirp4netns`. The uplink + filtering half
is prototyped and works — but integrating it hit a hard **uid/caps/9p trilemma**. Three constraints
can't all hold in a plain *unprivileged* user namespace:

- **nft needs `CAP_NET_ADMIN`** inside the namespace;
- **9p `security_model=none`** needs QEMU's effective host uid to be the real user, and the guest
  agent's uid to match;
- **caps don't survive `execve` for a non-root uid.**

The consequences:

- `--map-current-user` (uid preserved → 9p OK) *loses* `CAP_NET_ADMIN` at `execve` — **verified:
  `nft` fails with "Operation not permitted."**
- `--map-root` keeps caps but maps to uid 0, and **claude hard-refuses
  `--dangerously-skip-permissions` when euid == 0** — so that path is **ruled out**.
- `--runas` can't bridge it.

The only way out is to use host `/etc/subuid` + `newuidmap` to map a uid *range* (holding both uid 0
for nft AND the real uid for QEMU/9p). Clean and correct, but it requires **host setup** (against
ccvm's zero-setup principle) and a delicate boot-path rework needing a human `--shell` pass.

Net: `agentSudo` is the shipped interim — it raises exfil from one command to a guest-kernel
exploit; the host-side fix would raise it to a full QEMU escape, a marginal gain for real setup
cost, so it stays opt-in / future. **Don't re-attempt map-root.**

## Related: slirp host-loopback

An empty allowlist (open egress) also leaves the host's loopback reachable from inside the VM via
slirp's `10.0.2.2` gateway. An `egressAllowlist` closes that too (`10.0.2.2` isn't in the set). See
[Slirp host-loopback reachability](slirp-loopback.md).
