# ccvm — design notes

`ccvm` runs Claude Code inside a throw-away QEMU microVM and drops you into it in
your current terminal, so the agent operates against an isolated, RAM-only copy of
your machine instead of the real thing. When the session ends the VM's RAM is freed
and **nothing it did survives** — there is no disk to clean up.

This document explains *why* it is built the way it is. For how to use it, see the
[README](../README.md).

---

## 1. Goals

1. **Indistinguishable UX.** `cd` into a project, run `ccvm` instead of `claude`,
   and land in the normal Claude Code TUI — same terminal, foreground, full fidelity
   (resize, `Ctrl-L`, `vim`, `less`, zsh vi-mode, colours). Arguments pass through
   verbatim. This is the contract; everything else bends to preserve it.
2. **Ephemeral by construction.** No persistent disk image anywhere. Power-off is the
   only cleanup. A crash, a kill, a dropped connection — all leave zero trace.
3. **The VM is the trust boundary.** The rest of the host is invisible — only the project
   directory is shared — and the Anthropic API key never touches disk, argv or the kernel
   cmdline. That boundary is what makes `--dangerously-skip-permissions` safe to opt into;
   ccvm passes no flags of its own, so you add that one yourself when you want it. A
   file-level safety net sits on top and is opt-in: `autoUpdateFiles = false` makes the
   project read-only too, so even edits stay in the VM (§3.6).
4. **Zero host setup.** `nix run github:jx-wi/ccvm` from any flakes-enabled NixOS box,
   or add the home-manager module for a persistent `ccvm` command.

### Non-goals

- Persistence of the VM's own state (installed tools, root fs — all RAM, all discarded).
  Your *project* edits are a separate matter: live on the host by default, or `git push`
  from inside when running under the read-only safety net.
- A general-purpose VM manager. ccvm builds exactly one guest and boots it one way.
- Defending the *host* against a malicious *guest kernel*. The boundary is QEMU; we
  assume QEMU's device/Virtio isolation holds. We do defend the host filesystem and
  the user's credentials.

---

## 2. Architecture at a glance

```
            host                                   guest (QEMU microVM)
  ┌───────────────────────────┐          ┌────────────────────────────────────┐
  │ ccvm (wrapper/ccvm.sh)     │          │  tmpfs /        (RAM, discarded)    │
  │                            │          │  /nix/store     (ro squashfs/vda)  │
  │  1. gen ephemeral ssh keys │  9p ro   │                                    │
  │  2. write seed ───────────────────────▶  ccvm-seed.service (root oneshot)  │
  │  3. boot QEMU (headless)   │          │     ├ install host key + authkeys  │
  │  4. wait for sshd banner   │          │     └ mount workspace per mode      │
  │  5. ssh -tt  ───────────────── SSH ───▶  sshd ─ForceCommand→ launcher       │
  │       (foreground)         │  :22     │            └ cd workdir; exec claude│
  │  6. on exit: kill qemu,    │          │                                    │
  │     rm scratch (trap)      │   slirp  │  networkd/DHCP 10.0.2.x, NAT out    │
  └───────────────────────────┘  net     └────────────────────────────────────┘
```

The wrapper is a single Bash script (`wrapper/ccvm.sh`) with the guest's boot
artifacts baked in at build time by `lib/mkccvm.nix`. The guest is a plain
`nixosSystem` (`guest/*.nix`). There is no daemon, no state directory, no config file.

---

## 3. Design decisions

### 3.1 QEMU + slirp, not cloud-hypervisor / firecracker

We need outbound HTTPS to `api.anthropic.com` with **zero host configuration** — no
bridges, no TAP devices, no `sudo`. QEMU's built-in **slirp** user-mode networking
gives an unprivileged NAT (guest `10.0.2.x`, DNS + DHCP synthesised by QEMU) plus
`hostfwd` for the inbound SSH port. cloud-hypervisor/firecracker are faster to boot but
expect you to wire up host networking yourself, which breaks goal 4. Boot speed matters,
but "works on a stock box as a normal user" matters more.

### 3.2 SSH over a localhost-forwarded port

QEMU forwards a random high port on `127.0.0.1` to the guest's `:22`
(`hostfwd=tcp:127.0.0.1:PORT-:22`). Binding to loopback only keeps the guest sshd off
the LAN. The wrapper picks the port by probing for a free one; there is a tiny TOCTOU
window between probe and QEMU's bind, which is acceptable for a single-user localhost
dev tool. If the bind ever loses the race, boot fails fast and you re-run.

### 3.3 SSH is the transport — for PTY fidelity, not just convenience

This is the load-bearing decision. The obvious way to talk to a VM is the serial
console, but a serial line is **not** a terminal: it does not carry `SIGWINCH`, window
size, or full termios, so resize breaks, full-screen TUIs corrupt, and `vim`/`less`
misbehave. The whole point of ccvm is that you can't tell you're in a VM.

`ssh -tt` to a real `sshd` gives us a genuine **PTY** on the guest side. SSH natively
propagates the client's `TERM`, the initial window size, and — critically — relays
`SIGWINCH` as window-change messages on every resize. termios (raw mode, signals,
flow control) is negotiated end to end. So `Ctrl-L`, vi-mode, `less`, and
arbitrary full-screen programs behave exactly as they do natively.

`-tt` *forces* PTY allocation even though the wrapper's own stdin may not be a tty at
the moment it execs ssh; without the double `-t`, ssh would decline the PTY and we'd
be back to a dumb pipe.

The wrapper runs ssh in the **foreground but never `exec`s it** — it must regain control
after the session to tear the VM down (§5).

### 3.4 Ephemeral root: tmpfs `/` + read-only `/nix/store`

The guest root is a **tmpfs** (RAM), so every byte the agent writes outside the project
lives only in guest memory and vanishes on power-off. The system closure is mounted
**read-only** at `/nix/store` — either a self-contained **squashfs** on a virtio-blk
disk (default, maximal isolation) or the host store shared over 9p
(`mountHostNixStore = true`, smaller/faster, less isolated). This is the well-worn
"erase your darlings" pattern, so first-boot risk is low.

Boot is **direct kernel boot**: no bootloader. `mkccvm` extracts the kernel + initrd and
hands QEMU `-kernel/-initrd/-append`. The initrd is the **systemd** one (the scripted
initrd is deprecated upstream for 26.11); it mounts the tmpfs root and read-only squashfs
store from generated units, with the virtio transports and `squashfs`/`overlay` modules
forced into the initrd so the store device and overlay are available before switch-root.

### 3.5 The seed: a read-only 9p share for per-invocation inputs

Everything that differs per launch — the SSH host key, `authorized_keys`, the workspace
path, the file-sharing mode, the debug-shell flag, and the forwarded argv — is written
by the wrapper into a scratch directory and exported to the guest as a **read-only 9p
share** tagged `ccvm-seed`. A boot oneshot, `ccvm-seed.service`, mounts it, installs the
SSH identity with strict perms, and performs every privileged mount **before sshd
starts**. Because all the privileged work happens there, the sshd `ForceCommand`
launcher runs **completely unprivileged** — it only `cd`s and `exec`s.

The forwarded argv is serialised **NUL-separated** (`printf '%s\0'`) and reconstructed
with `mapfile -d ''`, so spaces, quotes and glob characters survive byte-for-byte and
are never rebuilt by word-splitting.

The API key is **deliberately not in the seed** (§3.7).

### 3.6 File-sharing modes: rw (default) vs overlay

The host CWD is shared over 9p and **mounted at the identical absolute path** inside the
guest, so any path the agent prints or writes matches the host's mental model.

- **`autoUpdateFiles = true` (default): read-write passthrough.** The host CWD is mounted
  read-write; edits land on the host live — identical to running `claude` natively. With
  `security_model=none`, files are created with real host uid/gid (no `.virtfs_metadata`
  litter), because the guest `ccvm` user is uid 1000 to match a typical host user. This
  mirrors native `claude`, which is why it is the default.
- **`autoUpdateFiles = false`: overlay (the safety net).** The host tree is the
  read-only **lower** of an overlayfs; a tmpfs is the **upper**. The agent sees and edits
  a full working tree, but every write lands in guest RAM. The host project is never
  modified; on exit the edits evaporate. Export deliberately via `git push`.

The mode is resolved at launch, highest precedence first: the per-run flags
`ccvm --no-auto-update-files` / `--auto-update-files` (intercepted by the wrapper and
**not** forwarded to claude), then `CCVM_AUTOUPDATE=0|1`, then the baked-in
`autoUpdateFiles` default. The flags win, so you can flip either way for a single run
without touching config — and because they are consumed by the wrapper, claude still
receives only the user's own arguments.

### 3.7 Secret handling: the API key rides the SSH channel only

The Anthropic key must never be persisted or observable. It is **not** put on the kernel
cmdline, **not** in any QEMU argument, **not** in the seed, **not** in any file. Instead
the wrapper passes only the *variable name* to ssh via `SendEnv`; sshd accepts exactly
that name via `AcceptEnv`; the value travels **inside the encrypted SSH channel** and
arrives as an environment variable in the launcher, which `exec`s claude with it already
in the environment. `ps`, `/proc/<pid>/cmdline`, and the scratch dir never see it.

`SendEnv` (send the host's current value of a named var) is used rather than `SetEnv`
(put a literal `VAR=value` on the ssh command line), precisely because `SetEnv` would
place the secret in argv.

`shareHostConfig` (**on by default**, so ccvm mirrors native `claude`) is the other way to
authenticate: it surfaces the host's `~/.claude` (settings, custom commands, global memory,
and the OAuth credential) inside the VM as the read-only **lower** of an overlay, with a
tmpfs **upper** for claude's own writes. Set `CCVM_SHARE_CONFIG=0` to disable it for one run
(or `=1` to force it on); the env var overrides the baked `shareHostConfig` default.
The OAuth credential therefore rides the read-only 9p mount and is **never copied into the
scratch dir or the seed** — only the non-secret home-root `~/.claude.json` is staged through
the seed and installed into the writable home. Claude's writes (including token refreshes)
land in the tmpfs upper and do not persist back to the host.

**home-manager symlinks.** A managed `~/.claude` typically has config files symlinked *out of
the tree* — e.g. `settings.json -> /nix/store/…-home-manager-files/.claude/settings.json`. 9p
passthrough preserves those symlinks verbatim, but their targets don't exist inside the guest,
so they would dangle and claude would read no config. The wrapper therefore walks `~/.claude`
and stages the **dereferenced contents** of every symlink whose target escapes the tree into
`seed/config-deref`; the guest lays those real files over the overlay's writable upper,
shadowing the dangling links. The walk **never follows `.credentials.json`** (it stays a 9p-only
secret), and only escaping links are dereferenced — internal relative links already resolve on
the mount. This is what makes a home-manager-managed config readable in the VM regardless of
whether the host `/nix/store` is shared.

A key is **not required**, though. With no `ANTHROPIC_API_KEY` set and `shareHostConfig`
turned off (or no host `~/.claude` to share), the wrapper warns (it no longer aborts) and
starts claude unauthenticated, so the in-VM **`/login` web-auth flow** works: claude prints an
authorization URL, you open it in your host browser and paste the resulting code back into
the TUI. No inbound connection to the guest is needed (the code is pasted, not delivered to
a callback), so nothing about the network model changes. The credentials claude writes to
its tmpfs `~/.claude` are, like everything else in the VM, discarded on exit.

**Guest RAM vs. host swap.** Everything secret in the VM lives in guest RAM — the API key in
the launcher's environment, any `/login` credentials in tmpfs. That RAM is ordinary host
process memory, so a memory-pressured host kernel *could* page it out to swap. `lockGuestMemory`
(off by default; `CCVM_MLOCK=1` for one run) starts QEMU with `-overcommit mem-lock=on`, which
mlocks the guest so it can never reach the host's possibly-unencrypted swap. It needs a large
enough `RLIMIT_MEMLOCK` or QEMU won't start. This — not full-disk encryption, which is moot
when there is no persistent disk — is the relevant at-rest protection for an all-RAM VM.

### 3.8 The microvm.nix runtime-share trap

It is tempting to declare the workspace 9p mount inside the guest NixOS config (or to use
microvm.nix's share mechanism). **We can't:** the workspace path and the SSH port are
only known at `ccvm` *launch* time, not at *build* time. If they were baked into the
guest closure, every new project directory would force a guest rebuild, and the same
built artifact couldn't be reused across launches.

So `mkccvm` bakes only what is launch-invariant — kernel, initrd, store image, kernel
cmdline, and the scalar config — into the wrapper. The wrapper constructs the
**runtime** QEMU args (the workspace `-fsdev`, the seed share, the `hostfwd` port) itself,
at launch. The guest learns the workspace path and mode by *reading the seed*, not from
its own configuration. This split is the single most important structural choice in the
codebase; getting it wrong is the "runtime-share trap".

### 3.9 Guest hardening

`sshd` is single-purpose: key-only (`publickey` only, no passwords, no
keyboard-interactive), `PermitRootLogin no`, no TCP/agent/X11 forwarding, one
`ForceCommand`. The host key is the per-run ephemeral key from the seed, so the client
pins it (`StrictHostKeyChecking=yes`, known_hosts entry written before connect) — there
is no blind trust-on-first-use. The firewall is off because slirp already NATs the guest
off any real network and nothing should be reaching *in* except the forwarded port.

### 3.10 Egress: open by default, opt-in allowlist (not Tor)

Outbound is **open by default**: the guest NATs through slirp, so the agent can reach the
Anthropic API and anything else it wants — `WebFetch` URLs, `npm`/`pip`/`git clone`. That is
the deliberate native-mirroring default and is fine for the *containment* goal (the agent
still can't touch the host beyond the CWD), but it leaves one gap: a prompt-injected or
compromised agent can **exfiltrate** the shared project tree — or, under the default
`shareHostConfig`, the host OAuth credential it can read in-VM — to an arbitrary host.

The on-threat-model answer is an **egress allowlist**, not anonymity, and it is now
**implemented as an opt-in mode** (`egressAllowlist` / `egressPorts`). An empty list (the
default) keeps egress fully open; a non-empty list switches the guest to a **default-deny**
nftables OUTPUT chain that permits only the listed destinations on the listed ports (TCP),
plus a small base set: loopback, conntrack replies (so the inbound ssh session and DNS
answers keep working), DNS **only to the slirp stub resolver** (10.0.2.3 / fec0::3), DHCPv4
renewal, and IPv6 NDP. `api.anthropic.com` is always auto-included. This stays inside ccvm's
existing model — agent containment + credential hygiene — at zero latency cost.

**Where the work happens.** The allowlist is a per-launch runtime input, so it follows the
runtime-share split (§3.8), not a baked guest closure value: `egressAllowlist`/`egressPorts`
are baked into the wrapper as scalars (`@EGRESSALLOW@`/`@EGRESSPORTS@`), but the **host**
resolves any FQDN entries at launch (it has working DNS), passes IPs/CIDRs through verbatim,
and writes the resolved set + ports into the **seed** alongside an `egress-enforce` marker.
The guest's `ccvm-seed.service` enforces the firewall whenever that **marker** is present —
not merely when the resolved set is non-empty — so an empty set fails closed (deny-all)
instead of reverting to open egress. Two layers guard the fail-open hole: if the user opts in
but *nothing* resolves (host DNS down, no literal IPs), the **wrapper refuses to boot** rather
than run an unenforceable allowlist; and the guest enforces on the marker regardless. If
`nft -f` fails (atomic — nothing installed on error), the guest **fails closed but keeps the
base rules** (ssh session + DNS survive) so you can `--shell` in to debug, rather than a bare
deny-all that would drop sshd's own replies and hang the boot.

```nix
programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" "10.0.0.0/8" ];
programs.ccvm.egressPorts     = [ 443 ];   # add 80 for plain-HTTP mirrors
```

**Known limitations (the MVP) — three residual channels the IP-filter MVP can't close,**
each the job of the future SNI/DNS-filtering proxy that layers on top:
- **FQDN staleness.** Hostnames can't be matched by a stateless packet filter (the kernel
  sees IPs), so they're handled by host-side DNS pre-resolution at launch — pinned A/AAAA
  records, with the round-robin/CDN caveat for a long session. This bites `api.anthropic.com`
  itself (Cloudflare-fronted): if it rotates to an unpinned edge mid-session, API calls fail —
  the user restarts or pins a broader CIDR. "Auto-included" guarantees it's *attempted*, not
  that the pinned IPs stay valid forever.
- **DNS tunneling.** DNS is restricted to the stub resolver (not arbitrary servers), which
  blocks direct DNS-to-anywhere, but a determined agent can still tunnel low-bandwidth data
  through the recursive resolver. Closing this needs a filtering resolver, not a packet filter.
- **TCP-only.** Only TCP on the listed ports is allowed; QUIC/UDP 443 is dropped and clients
  fall back to TCP. UDP-only services would need explicit handling.

**Why not Tor.** Routing guest traffic through Tor was considered and rejected. It solves
network *anonymity*, which is orthogonal to this project: the dominant flow is the Anthropic
API authenticated with the user's own credential, so Tor hides the source IP while the
application layer still identifies you exactly — self-defeating. It also adds latency and
runs into Anthropic blocking Tor exit IPs, both of which violate the "no compromise on
devex/ux" rule, and a `tor` daemon is new long-running surface to harden. Crucially it is
**redundant**: because the guest egresses through the *host* network stack (§3.1), a user
who wants anonymity runs Tor or a VPN on the host and the guest rides through it for free,
with no guest-side code. Egress *control* (where the agent may connect) belongs in ccvm;
egress *anonymization* (how those packets reach the wire) belongs on the host.

---

## 4. Boot & connect flow (wrapper)

1. Parse args: peel off ccvm-only flags (`--shell`, `--ccvm-debug`); everything else is
   forwarded to claude. Resolve mode (overlay/rw) and acceleration (KVM if usable, else
   TCG; `CCVM_ACCEL=tcg` forces software emulation for broken nested-virt hosts).
2. Check auth: if no API key and no shared host config, warn (don't abort) so the
   in-VM `/login` web-auth flow can run.
3. Make a scratch dir under `$XDG_RUNTIME_DIR`; arm a single `trap cleanup EXIT INT TERM
   HUP`.
4. Generate two throw-away ed25519 keys (client identity + guest host key); pin the host
   key into a known_hosts file.
5. Populate the seed; build the runtime QEMU device args (store, seed share, workspace
   share, slirp + hostfwd, rng).
6. Boot QEMU **headless in the background**, stdio detached from the terminal so it never
   touches the TTY the TUI will own. Guest serial goes to a log file.
7. Poll the forwarded port for the `SSH-*` banner (not a full ssh — a real connection
   would trip the ForceCommand and launch claude on every probe).
8. `ssh -tt` in the foreground. Hand the terminal to Claude Code.

## 5. Teardown

A single `cleanup` trap fires on every exit path — normal quit, `Ctrl-C`, a dropped
connection, `SIGTERM`/`SIGHUP`, or boot failure. It kills the QEMU process (TERM, then
KILL) and removes the scratch dir (which holds the only copies of the ephemeral keys).
Freeing QEMU discards all guest RAM, which **is** the ephemeral story — there is no disk
state to scrub. The wrapper deliberately does **not** `exec ssh`, so it always regains
control to run this. `Ctrl-C` during a session is forwarded by `ssh -tt` to Claude Code
(it interrupts the agent, as it would natively); the VM is torn down only when the
session itself ends.

---

## 6. Build topology

- `guest/default.nix` — the ephemeral NixOS system (boot, fs, networking, user, packages).
- `guest/sshd.nix` — the hardened, single-ForceCommand sshd.
- `guest/launcher.nix` — `ccvm-seed.service` (privileged setup) + `ccvm-guest-launch`
  (unprivileged `cd`+`exec`).
- `lib/mkccvm.nix` — evaluates the guest, extracts boot artifacts, bakes them + scalar
  config into the wrapper. Called with the caller's own `pkgs`, so host and guest share
  one nixpkgs.
- `wrapper/ccvm.sh` — the host-side launcher (§4–5). Built with `writeShellApplication`,
  so it is shellcheck-clean by construction.
- `modules/home-manager.nix` — `programs.ccvm.*` → installs the `ccvm` command.
- `tests/` — `host.sh` (host-side guarantees via the `CCVM_DRYRUN` hook; wired into
  `nix flake check` by `default.nix`) and `boot.sh`/`stub-claude.sh`/`boot.nix` (local
  full-boot smoke test).

## 7. Known limitations

- **Coverage is layered (see `tests/`).** The host-side security invariants are checked in
  CI by `tests/host.sh`, which drives the real wrapper through a dry-run hook (`CCVM_DRYRUN`:
  populate the seed + run the config-staging loop, then stop before boot): the API key never
  reaching the seed, the OAuth credential never being staged (top-level and nested), escaping
  host-config symlinks being dereferenced, verbatim NUL-separated argv, and ccvm-flag
  consumption + mode selection. `tests/boot.sh` boots a stub-`claude` VM locally to confirm
  the argv reaches claude and that overlay vs. rw file visibility is correct. PTY/`TERM`
  propagation, `SIGWINCH`/resize, and teardown are **not** auto-tested — interactive fidelity
  is a human smoke test by nature (README checklist), and teardown is verified by inspection.
- **aarch64-linux is best-effort.** It evaluates and is wired up, but the primary,
  CI-built target is x86_64-linux.
- **`shareHostConfig` is read-only.** The in-VM Claude's writes to its config — including
  OAuth token refreshes — stay in the ephemeral overlay and do not persist back to the
  host (§3.7).
