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
| `extraGuestModules` | `[ ]` | Extra NixOS modules merged into the guest (escape hatch). |

### Runtime environment knobs

| Var | Effect |
|---|---|
| `ccvm --auto-update-files` / `--no-auto-update-files` | Force file-sharing mode for one run (wins over `CCVM_AUTOUPDATE`); intercepted, not forwarded to claude. |
| `CCVM_AUTOUPDATE=1\|0` | Override the file-sharing mode for one run. |
| `CCVM_SHARE_CONFIG=1\|0` | Override host `~/.claude` sharing for one run (wins over the baked `shareHostConfig`). |
| `CCVM_SHELL=1` / `ccvm --shell` | Drop into a debug **zsh** in the guest instead of claude. |
| `CCVM_DEBUG=1` / `ccvm --ccvm-debug` | Stream the guest console while booting; keep the scratch dir on exit. |
| `CCVM_ACCEL=tcg` | Force software emulation (for hosts where `/dev/kvm` exists but is broken). |
| `CCVM_MACHINE=q35` | Use the q35 machine type instead of the default `microvm`. |

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

Most of ccvm's guarantees are checked automatically (mount isolation, the key never
reaching disk/argv, verbatim argument forwarding, clean teardown). Terminal **fidelity**,
however, is best confirmed by a human at a real terminal:

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
