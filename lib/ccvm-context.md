# Running inside ccvm

You are running inside **ccvm**, an ephemeral, RAM-only QEMU microVM sandbox — not the
user's host machine directly. A few things follow from that:

- **Nothing here persists.** The entire VM (root filesystem, installed packages, shell
  history, anything outside the shared project directory) lives in RAM and is destroyed when
  the session ends. There is no disk to recover state from after exit.
- **Only the project directory is shared with the host.** The rest of the host filesystem —
  the user's home directory, `~/.ssh`, cloud credentials — is not mounted here.
- **You can be more autonomous than usual.** Because this is a disposable sandbox isolated
  from the host, exploratory commands, builds, and installs are low-risk: they vanish on
  exit. Prefer getting routine, reversible work done over pausing to ask permission for it.
- **Git: commits work, pushing usually does not.** Your host git identity and aliases are
  available so `git commit` records authorship as you, but the host's SSH keys are not shared,
  so `git push` to an SSH remote cannot authenticate. Commit freely; hand the push (or a
  `git fetch`) to the user — see **Handing work to the host** below — or use an HTTPS remote
  with a token they provide.
- **Network egress may be locked to an allowlist.** When it is, the `# ccvm session` header at
  the top of this file names the **exact** hosts you can reach this run (plus `api.anthropic.com`
  for the Claude API). A request to any host NOT on that list does not fail fast — it HANGS and
  then times out. That is the firewall doing its job, not a transient error, so retrying will not
  help. Do not attempt to fetch, clone, `curl`, install packages from, or `git fetch`/`pull` from
  a host that is not reachable — hand that work to the user instead (below). If the header says
  egress is OPEN this run, ignore this and fetch normally.
- **Prefer the codebase over agent memory for anything durable.** Write lasting knowledge into
  the project's own files — `CLAUDE.md`, `README.md`, `docs/`, code comments — and commit it,
  rather than relying on saved memory. Memory is brittle for developer workflows, and in ccvm it
  is **ephemeral by default**: it lives in this throwaway VM and is discarded on exit. Only when
  `CCVM_PERSIST_PROJECTS=1` does it survive across runs — see the session note above for whether
  it persists right now.

## Handing work to the host

Some things simply cannot run inside this VM: fetching from a host the egress allowlist blocks,
`git fetch`/`git push` that needs the host's credentials, running the project's host-side CI, or
anything else that needs host network or host secrets. Do NOT keep retrying these — they will
hang or fail every time. Hand them to the user to run in a **host terminal** instead, and make
the commands trivially copy-pasteable:

- Put the exact commands in a fenced code block, **one command per line**.
- **No inline or trailing comments inside the block** — a `#` comment pasted into the user's
  shell (zsh) can break the command. Describe what each command does in prose *outside* the
  block, then give the clean block.
- Keep it to what the user must actually run; nothing else.

For example, to get the local CI run after you have committed:

> Committed as `abc1234`. My egress is limited, so I can't run the CI myself. Please run this in
> a host terminal:
>
> ```sh
> ./ci.sh
> ```

Or when you need content from a host you can't reach — here `git fetch` needs host credentials,
and the second command saves a doc page you'll read next into an ignored file:

> I can't reach those hosts from inside the VM. Please run these in a host terminal, then tell me
> when they're done:
>
> ```sh
> git fetch origin
> curl -fsSL https://docs.example.com/page > .ccvm-scratch/page.html
> ```
>
> Then I'll pick up from `.ccvm-scratch/page.html`.

When file edits reach the host live (writableCwd=true, see the session header), a fetch the user
runs into a file in the project tree becomes visible to you immediately.
