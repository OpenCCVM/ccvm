# ccvm

**Run Claude Code in a throw-away microVM, with zero setup.**

`ccvm` boots an ephemeral QEMU virtual machine and drops you straight into the normal
Claude Code TUI — same terminal, same keys, same everything — except the agent is now
operating inside a disposable, RAM-only NixOS that **can't touch your real machine** beyond
the one project you're working in. When you quit, the VM's memory is freed; there is no
disk to clean up.

It's the spiritual sibling of a disposable sandbox: `cd` into a project, type `ccvm`
instead of `claude`, and work exactly as you would natively — but with a hard isolation
boundary around the agent.

```
cd ~/code/my-project
ccvm                      # ← instead of `claude`
```

---

## Why

`claude --dangerously-skip-permissions` is wonderfully fast and wonderfully dangerous: it
lets the agent run anything against your actual filesystem. ccvm makes that safe by moving
the agent into a VM:

- **Native by default, lockable on demand.** Out of the box the agent edits your project
  live, exactly like native `claude`. Want a hard safety net? Set `autoUpdateFiles = false`
  (or run `ccvm --no-auto-update-files`): the project goes read-only, every edit lands in
  the VM's RAM and evaporates on exit, and you export what you want with `git push`.
- **The rest of your machine is invisible.** Only the current directory is shared. No
  `~/.ssh`, no `~/.aws`, no home directory.
- **Your API key never hits disk.** It travels only inside the encrypted SSH channel —
  never on the kernel cmdline, in a QEMU argument, or in any file.
- **The VM leaves no trace.** Crash, kill, `Ctrl-C`, dropped connection — the machine and
  all of its RAM are gone. The only thing that can outlive a session is edits to your
  project directory, and only while you allow it (turn it off to keep even those ephemeral).

Because the VM is the safety boundary, `--dangerously-skip-permissions` is safe to use
here — but ccvm doesn't force it on you. It launches Claude with **no extra flags**; opt
in yourself with `ccvm --dangerously-skip-permissions` (everything after `ccvm` is
forwarded verbatim) when you want the agent to run unattended.

---

## Quick start

Requires a Linux box with **Nix** and **flakes** enabled (KVM strongly recommended for
speed; it falls back to slow software emulation otherwise).

```sh
export ANTHROPIC_API_KEY=sk-ant-...     # optional — ccvm reads it from the environment

# run it straight from GitHub, no install:
cd ~/code/my-project
nix run github:jx-wi/ccvm

# …or with arguments — everything after `ccvm` is forwarded to claude verbatim:
nix run github:jx-wi/ccvm -- --model sonnet "summarise the build setup"
```

**No API key?** That's fine — run `ccvm` without one and use Claude's in-VM `/login`
(web auth): copy the printed URL into your browser, sign in, and paste the code back.
Auto browser-open won't work from inside the VM, but the copy/paste flow does. Whatever
you log in with lives only in the VM and is gone on exit.

### Install via home-manager

```nix
{
  inputs.ccvm.url = "github:jx-wi/ccvm";

  # in your home-manager configuration:
  imports = [ inputs.ccvm.homeManagerModules.default ];

  programs.ccvm = {
    enable = true;
    # autoUpdateFiles = false;           # opt into the read-only safety net (default: true)
    # shareHostConfig = false;           # stop reusing your host ~/.claude (default: true)
    # extraPackages = with pkgs; [ go gopls python3 ];  # project toolchains
  };
}
```

That puts a persistent `ccvm` command on your `PATH`.

---

## The one switch that matters: `autoUpdateFiles`

| `autoUpdateFiles` | Host project | Edits | Use when |
|---|---|---|---|
| `true` *(default)* | **read-write** | land on the host **live** | you want native behaviour (mirrors `claude`) |
| `false` | **read-only** | land in VM RAM, vanish on exit | you want a hard safety net; export via `git push` |

Per-invocation override without changing config — highest precedence first:
`ccvm --no-auto-update-files` / `ccvm --auto-update-files`, then `CCVM_AUTOUPDATE=0|1 ccvm`.
Those `ccvm` flags are intercepted by the wrapper and are **not** forwarded to claude.

---

## Options (`programs.ccvm.*`)

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | Install the `ccvm` command. |
| `package` | `pkgs.claude-code` | The claude-code package to run in the VM. |
| `autoUpdateFiles` | `true` | Read-write host project (live, like native `claude`) vs. ephemeral overlay (above). |
| `memory` | `4096` | VM RAM, MiB. |
| `cores` | `4` | VM vCPUs. |
| `extraPackages` | `[ ]` | Extra tools inside the VM (a sensible base set is always present). |
| `mountHostNixStore` | `false` | Share host `/nix/store` (ro) instead of a self-contained image — smaller/faster, less isolated. |
| `apiKeyVariable` | `"ANTHROPIC_API_KEY"` | Host env var carrying the key; passed only via SSH `SendEnv`. |
| `shareHostConfig` | `true` | Mount the host `~/.claude` (ro) so the VM reuses your login, settings, commands and memory (home-manager symlinks are dereferenced); writes stay ephemeral. Per-run: `CCVM_SHARE_CONFIG=0\|1`. |
| `lockGuestMemory` | `false` | mlock the guest RAM (QEMU `mem-lock=on`) so it can't be paged to the host's (possibly unencrypted) swap — keeps in-VM secrets off persistent storage. Needs sufficient `RLIMIT_MEMLOCK`. Per-run: `CCVM_MLOCK=0\|1`. |
| `egressAllowlist` | `[ ]` | **Opt-in.** Empty = open egress (native default). Non-empty switches the guest to a default-deny egress firewall allowing only these FQDN/IP/CIDR destinations (`api.anthropic.com` auto-included) — closes the *direct* exfiltration channel (DNS-to-stub-resolver stays open as a residual channel). See [Threat model & network egress](#threat-model--network-egress). |
| `egressPorts` | `[ 443 ]` | Destination ports the allowlist permits (only when `egressAllowlist` is set). Add `80` for plain-HTTP mirrors. |
| `extraGuestModules` | `[ ]` | Extra NixOS modules merged into the guest (escape hatch). |

### Runtime environment knobs

| Var | Effect |
|---|---|
| `ccvm --auto-update-files` / `--no-auto-update-files` | Force file-sharing mode for one run (wins over `CCVM_AUTOUPDATE`); intercepted, not forwarded to claude. |
| `CCVM_AUTOUPDATE=1\|0` | Override the file-sharing mode for one run. |
| `CCVM_SHARE_CONFIG=1\|0` | Override host `~/.claude` sharing for one run (wins over the baked `shareHostConfig`). |
| `CCVM_MLOCK=1\|0` | Lock (or unlock) the guest RAM for one run (overrides the baked `lockGuestMemory`). |
| `CCVM_SHELL=1` / `ccvm --shell` | Drop into a debug **zsh** in the guest instead of claude. |
| `CCVM_DEBUG=1` / `ccvm --ccvm-debug` | Stream the guest console while booting; keep the scratch dir on exit. |
| `CCVM_ACCEL=tcg` | Force software emulation (for hosts where `/dev/kvm` exists but is broken). |
| `CCVM_MACHINE=q35` | Use the q35 machine type instead of the default `microvm`. |

### Locking guest memory (`lockGuestMemory` / `CCVM_MLOCK`)

Everything secret in the VM lives in guest RAM — the API key in the launcher's environment,
any `/login` credentials in the guest tmpfs. That RAM is ordinary host process memory, so a
memory-pressured host kernel *could* page it out to swap (and your swap may be
unencrypted). Turning this on starts QEMU with `-overcommit mem-lock=on`, which `mlock`s the
guest so it can never reach swap. This — not full-disk encryption, which is moot when there
is no persistent disk — is the relevant at-rest protection for an all-RAM VM. It is **off by
default** because it requires a raised memory-lock limit.

**`mlock` needs `RLIMIT_MEMLOCK` ≥ the guest RAM (plus QEMU's overhead).** Many Linux setups
ship a tiny default (often 8 MiB / `8192` KiB), far below the default `memory = 4096` MiB
guest, so QEMU aborts at startup with `mlock: Cannot allocate memory`. Check yours with
`ulimit -l` (`unlimited`, or KiB). Raise it before enabling:

| Where | Fix |
|---|---|
| Current shell only | `ulimit -l unlimited`, then re-run `ccvm` |
| systemd user services | set `LimitMEMLOCK=infinity` in the unit / drop-in |
| System-wide (PAM) | add `<user> - memlock unlimited` to `/etc/security/limits.conf` (or a `limits.d` file), then re-login |
| NixOS | `security.pam.loginLimits = [ { domain = "*"; type = "-"; item = "memlock"; value = "unlimited"; } ];` |

If you can't or don't want to raise the limit, leave `lockGuestMemory` off (the default) or
pass `CCVM_MLOCK=0` for a single run — guest RAM may then reach host swap, the only
trade-off. The wrapper runs a preflight check and prints a loud warning (with these same
fixes) when the limit looks too low.

---

## Threat model & network egress

ccvm contains the agent's effect on your **filesystem** (only the CWD is shared; the rest of
the host is invisible) and protects your **API key** (it never hits disk/argv; see above).
What it does **not** restrict by default is the **network**: like native `claude`, the guest
can reach anything outbound, so `npm`/`pip`/`git clone`/`WebFetch` all work. That's the
deliberate native-mirroring default — and it leaves one real gap worth understanding:

> **In the default posture, a prompt-injected or compromised agent could exfiltrate data.**
> With `shareHostConfig = true` (default) your host `~/.claude` — *including the OAuth
> credential* — is readable inside the VM, and with open egress the agent could POST the
> project tree or that credential to an arbitrary host. The VM still can't touch your host
> filesystem, but containment ≠ exfiltration-proof.

This is inherent to mirroring native `claude` (reusing your host login *means* the credential
is in the VM). Your options, cheapest first:

- **Authenticate with an API key instead of OAuth** (`export ANTHROPIC_API_KEY=…`, and
  `shareHostConfig = false`): then no long-lived OAuth credential is exposed to the agent at
  all — the key rides the SSH channel and is the only secret in the VM.
- **Lock down the network with `egressAllowlist`** (opt-in; the default stays open so native
  behaviour is unchanged):

  ```nix
  programs.ccvm.egressAllowlist = [ "github.com" "registry.npmjs.org" "10.0.0.0/8" ];
  programs.ccvm.egressPorts     = [ 443 ];   # add 80 for plain-HTTP mirrors
  ```

  A non-empty list switches the guest to a **default-deny** egress firewall (nftables) that
  permits only those destinations on those ports — closing the **direct** HTTP(S)
  exfiltration channel. `api.anthropic.com` is always auto-included. FQDNs are resolved **on
  the host at launch** into IP rules — reliable for a session, but it IP-pins CDN-fronted
  hosts, **including `api.anthropic.com` itself**: if its CDN rotates to an edge IP that
  wasn't pinned at launch, API calls can fail mid-session — restart, or pin a broader CIDR.
  Two channels deliberately stay open and are **residual** (an SNI/DNS-filtering proxy is the
  planned stronger layer — [design §3.10](docs/design.md)):
  - **DNS**, but only to the VM's stub resolver (not to arbitrary servers), so normal name
    resolution works while direct DNS-to-anywhere is blocked — a determined agent can still
    *tunnel* low-bandwidth data through the recursive resolver.
  - **TCP only** on the listed ports (QUIC/UDP 443 is dropped; clients transparently fall back
    to TCP).

  If the rules fail to apply, the guest **fails closed**: it denies all new egress but keeps
  the ssh session and DNS alive so you can `--shell` in to debug. If you opt in but nothing
  resolves (host DNS down), the wrapper **refuses to boot** rather than run with an
  unenforceable allowlist. Combine with `autoUpdateFiles = false` to also keep project edits
  in the VM.

What ccvm deliberately does **not** do is anonymize traffic (no Tor): the dominant flow is the
Anthropic API authenticated as you, so anonymity is self-defeating and orthogonal. If you want
it, run a VPN/Tor on the *host* and the guest rides through it for free (design §3.10).

---

## How it works (the short version)

A Nix builder (`lib/mkccvm.nix`) evaluates a minimal NixOS guest and bakes its kernel,
initrd, read-only squashfs store image, and kernel cmdline into a single Bash wrapper. At
launch the wrapper generates throw-away SSH keys, writes a read-only "seed" the guest
reads over 9p, boots QEMU headless, waits for sshd, and `ssh -tt`s into the guest in the
foreground. SSH (not a serial console) is what gives you real-terminal fidelity — it
carries `TERM`, the window size, and `SIGWINCH`, so resize, `vim`, `less` and vi-mode all
behave natively. A single cleanup trap guarantees the VM and scratch dir are gone on every
exit path.

The full rationale — including the ephemeral root, the secret-handling path, and the
"runtime-share trap" that shapes the build — is in [docs/design.md](docs/design.md).

---

## Verifying it yourself

ccvm's guarantees are checked at three levels:

- **Host-side, in CI (`nix flake check`).** [`tests/host.sh`](tests/host.sh) drives the real
  wrapper through a dry-run hook (it populates the seed and runs the actual config-staging
  loop, then stops before booting) and asserts the security-critical invariants with no VM:
  the `ANTHROPIC_API_KEY` never reaches the seed (it rides `SendEnv` over SSH only), the
  OAuth credential is never staged into it (top-level *and* nested), escaping host-config
  symlinks *are* dereferenced, the forwarded argv round-trips byte-for-byte, the ccvm-only
  flags are consumed (not forwarded) and select the mode, and the egress allowlist stages
  correctly (default = open; IPs/CIDRs verbatim, FQDNs resolved, ports as an nft list —
  [`tests/egress.sh`](tests/egress.sh)).
- **Full boot, locally.** [`tests/boot.sh`](tests/boot.sh) builds a ccvm with a stub `claude`
  and boots the real VM (TCG by default, so it runs without KVM) to confirm the argv reaches
  claude, that overlay mode keeps a guest edit ephemeral while rw mode lands it on the host,
  and that the egress allowlist actually blocks a non-allowlisted host while permitting an
  allowlisted one. Needs a working VM, so it's a local gate, not a CI check.
- **Terminal fidelity, by a human.** Resize/`vim`/`less`/vi-mode behaviour is a manual smoke
  test by nature:

```sh
ccvm --shell        # debug shell in the guest
```

Then sanity-check, all of which should feel exactly like your host shell:

- [ ] Resize the terminal window — the prompt reflows, `clear`/`Ctrl-L` works.
- [ ] `vim somefile` — full-screen redraw, no corruption; `:q` returns cleanly.
- [ ] `ls | less` — paging, search, resize while open.
- [ ] zsh vi-mode: `Esc` then `k`/`j` to move through history, `cw` etc.
- [ ] Colours and Unicode render correctly.

And the read-only safety net — launch with `ccvm --no-auto-update-files`:

- [ ] Inside: `echo hi > scratch && ls`. Outside, on the host: the file is **not** there.

---

## Status & limitations

- **x86_64-linux** is the primary, CI-built target; **aarch64-linux** is best-effort
  (evaluates and is wired up).
- `shareHostConfig` is read-only: changes the in-VM Claude makes to its config (including
  OAuth token refreshes) stay in the VM and do not persist back to the host.

## License

MIT © 2026 jx-wi. See [LICENSE](LICENSE).
