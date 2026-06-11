# shellcheck shell=bash
#
# ccvm — boot an ephemeral microVM and drop the user straight into Claude Code.
#
# writeShellApplication supplies the shebang and `set -euo pipefail`. The @TOKENS@
# below are substituted with store paths / config at build time by lib/mkccvm.nix.
#
# Flow (see CLAUDE.md): generate throwaway SSH keys, pin the guest
# host key, write a read-only "seed" the guest reads over 9p, boot QEMU headless in the
# background, wait for sshd, then `ssh -tt` into it in the FOREGROUND (never exec — the
# wrapper must regain control to tear the VM down). A single trap guarantees the qemu
# process and the tmpfs scratch dir are gone on every exit path.

# ---- baked-in configuration (build time) -----------------------------------
KERNEL="@KERNEL@"
INITRD="@INITRD@"
STOREIMG="@STOREIMG@"
APPEND="@APPEND@"
MEMORY="@MEMORY@"
CORES="@CORES@"
APIKEYVAR="@APIKEYVAR@"
SHARE_SETTINGS="@SHARE_SETTINGS@"   # 1 = stage ~/.claude/settings.json + settings.local.json; 0 = off
SHARE_CLAUDEMD="@SHARE_CLAUDEMD@"   # 1 = stage ~/.claude/CLAUDE.md (global memory); 0 = off
SHARE_COMMANDS="@SHARE_COMMANDS@"   # 1 = stage ~/.claude/commands/; 0 = off
SHARE_AGENTS="@SHARE_AGENTS@"       # 1 = stage ~/.claude/agents/; 0 = off
SHARE_SKILLS="@SHARE_SKILLS@"       # 1 = stage ~/.claude/skills/; 0 = off
SHARE_PLUGINS="@SHARE_PLUGINS@"     # 1 = stage ~/.claude/plugins/ (off by default); 0 = off
SHARE_CONFIG="@SHARE_CONFIG@"       # 1 = stage ~/.claude/config/ (off by default); 0 = off
PERSISTPROJECTS="@PERSISTPROJECTS@" # 1 = mount host ~/.claude/projects rw (resume + memory persist); 0 = off
SHAREGIT="@SHAREGIT@" # 1 = stage a sanitized host git config into the guest; 0 = off
CLAUDEMD="@CLAUDEMD@" # path to the baked ccvm-context CLAUDE.md (empty = inject nothing)
MODE="@MODE@" # rw (writableCwd=true, default — mirrors native claude) | overlay (secure)
MEMLOCK="@MEMLOCK@" # 1 = mlock guest RAM (lockGuestMemory) so it can't hit host swap; 0 = off
EGRESSALLOW="@EGRESSALLOW@" # space-separated FQDN/IP/CIDR allowlist; empty = open egress (default)
EGRESSPORTS="@EGRESSPORTS@" # space-separated dst ports the allowlist permits (default 443)
VERSION="@VERSION@"         # ccvm's own version string (baked from lib/mkccvm.nix)
VMDISKSIZE="@VMDISKSIZE@"   # GiB; 0=off. >0 attaches an encrypted ephemeral disk pool (/scratch, …)

# ---- helpers ---------------------------------------------------------------
warn() { printf 'ccvm: %s\n' "$*" >&2; }
die() {
  printf 'ccvm: error: %s\n' "$*" >&2
  exit 1
}

# ccvm's own usage. Only ccvm's flags live here; every other argument is forwarded verbatim
# to claude (so `ccvm --help` reaches *claude's* help, by design — this is `--ccvm-help`).
ccvm_help() {
  cat <<'EOF'
ccvm — run Claude Code in an ephemeral, RAM-only QEMU microVM.

Usage: ccvm [ccvm flags] [claude args...]

All arguments are forwarded verbatim to `claude` EXCEPT ccvm's own flags below
(so `ccvm --help` / `ccvm --version` reach claude; use the --ccvm-* forms for ccvm).

ccvm flags:
  --shell                 Drop into a guest shell instead of launching claude.
  --ccvm-debug            Stream the guest console while booting; keep the scratch dir.
  --writable-cwd          Host CWD writable — edits land LIVE on the host (rw mode).
  --read-only-cwd         Host CWD read-only — edits ephemeral, discarded on exit.
  --ccvm-help             Show this help and exit.
  --ccvm-version          Print the ccvm version and exit.

Per-run environment overrides (a CCVM_* var overrides the baked default; an explicit
flag wins over the env var):
  CCVM_SHELL=1                  same as --shell
  CCVM_DEBUG=1                  same as --ccvm-debug
  CCVM_WRITABLE_CWD=0|1         host CWD writable (rw) or read-only (overlay)
  CCVM_SHARE_SETTINGS=0|1       stage ~/.claude/settings.json + settings.local.json
  CCVM_SHARE_CLAUDEMD=0|1       stage ~/.claude/CLAUDE.md (global memory)
  CCVM_SHARE_COMMANDS=0|1       stage ~/.claude/commands/
  CCVM_SHARE_AGENTS=0|1         stage ~/.claude/agents/
  CCVM_SHARE_SKILLS=0|1         stage ~/.claude/skills/
  CCVM_SHARE_PLUGINS=0|1        stage ~/.claude/plugins/ (off by default)
  CCVM_SHARE_CONFIG=0|1         stage ~/.claude/config/ (off by default)
  CCVM_SHARE_CLAUDE_CONFIG=0|1  deprecated: toggle all claude items at once (use per-item vars)
  CCVM_PERSIST_PROJECTS=0|1     persist ~/.claude/projects (resume + memory) to the host
  CCVM_SHARE_GIT_CONFIG=0|1     stage a sanitized host git config into the guest
  CCVM_CLAUDE_MD=<file>         alternate ccvm-context CLAUDE.md (empty disables it)
  CCVM_MLOCK=0|1                lock guest RAM so it can't reach host swap
  CCVM_MEMORY=<MiB>             guest RAM for this run
  CCVM_ACCEL=auto|kvm|tcg       override the acceleration mode for this run
  CCVM_MACHINE=<type>           QEMU machine type (default microvm on x86_64)

See the README for the full option reference (and CLAUDE.md for the threat model).
EOF
}

# Animated boot progress on stderr. The wrapper is otherwise silent through wait_for_boot,
# which is slow under TCG and looks hung. PROGRESS is enabled only when stderr is a real
# terminal AND we're not in debug mode (which already streams the guest console to stderr) —
# so redirected stderr / pipelines / the dry-run + test captures see nothing ([[ -t 2 ]] is
# false there), keeping those outputs byte-for-byte clean. Set just before the boot section.
PROGRESS=0
SPINNER_PID=""
# Braille spinner as an ARRAY (not a string sliced with ${s:i:1}: each frame is 3 UTF-8 bytes,
# and bash substring extraction is byte-based in a non-multibyte locale, which would emit a
# partial byte). Array indexing sidesteps the locale dependency entirely.
SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
# Spin in the BACKGROUND so the animation stays smooth no matter how long a boot probe blocks:
# QEMU's slirp accepts the forwarded port immediately, so wait_for_boot's banner read can sit
# for up to its timeout — driving frames from that loop made the spinner freeze for seconds at a
# time. A detached subshell renders ~30 fps independent of the probe cadence. No-op unless
# PROGRESS=1, so tests/pipelines/dry-run (stderr not a TTY) never spawn it.
spinner_start() { # $1 = status text
  [[ $PROGRESS == 1 ]] || return 0
  local msg="$1"
  (
    i=0
    while :; do
      printf '\r\033[K%s %s' "${SPIN[i]}" "$msg" >&2
      i=$(((i + 1) % ${#SPIN[@]}))
      sleep 0.03
    done
  ) &
  SPINNER_PID=$!
}
# Stop the spinner and clear its line so it never bleeds into the TUI or a following message.
# `wait` reaps the subshell so no stray frame can land after we clear (same discipline as the
# debug-tail kill before handing the terminal to ssh -tt). Safe to call when not running.
spinner_stop() {
  [[ -n ${SPINNER_PID:-} ]] || return 0
  kill "$SPINNER_PID" 2>/dev/null || true
  wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=""
  if [[ $PROGRESS == 1 ]]; then printf '\r\033[K' >&2; fi
}

# shellcheck disable=SC2329  # invoked indirectly via `trap` below, not by name.
cleanup() {
  # Stop the boot spinner / debug log tail first so neither outlives us (e.g. Ctrl-C mid-boot).
  if [[ -n ${SPINNER_PID:-} ]]; then kill "$SPINNER_PID" 2>/dev/null || true; fi
  if [[ -n ${TAILPID:-} ]]; then kill "$TAILPID" 2>/dev/null || true; fi
  # Tear down the VM: ask politely, then insist. Freeing qemu discards all guest RAM,
  # which is the entire ephemeral story — there is no disk state to clean up.
  if [[ -n ${QEMU_PID:-} ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ -n ${TMP:-} ]]; then
    if [[ ${DEBUG:-0} == 1 ]]; then
      warn "debug mode — scratch dir kept at $TMP (contains logs + ephemeral keys)"
    elif [[ ${DRYRUN:-0} == 1 ]]; then
      : # dry run prints and keeps $TMP itself; leave it for the caller to inspect/remove.
    else
      rm -rf "$TMP"
    fi
  fi
  # The encrypted disk image (vmDiskSize) lives OUTSIDE $TMP (a disk-backed dir, not the
  # tmpfs scratch). Its real erasure is cryptographic — the LUKS key died with guest RAM, so
  # the file is inert ciphertext the instant qemu stops — but remove it too (belt + suspenders).
  if [[ -n ${SCRATCH_IMG:-} ]]; then
    if [[ ${DEBUG:-0} == 1 ]]; then
      warn "debug mode — scratch disk image kept at $SCRATCH_IMG (inert: the LUKS key is gone)"
    elif [[ ${DRYRUN:-0} == 1 ]]; then
      : # dry run keeps it for the caller (host.sh asserts on it, then removes).
    else
      rm -f "$SCRATCH_IMG"
    fi
  fi
}

# Returns a free localhost TCP port. A connect that fails means nothing is listening, so
# the port is (very likely) free. A tiny TOCTOU race to the qemu bind is acceptable for a
# localhost dev tool.
pick_port() {
  local p _
  for _ in $(seq 1 50); do
    p=$(((RANDOM % 20000) + 20000))
    # The 2>/dev/null must wrap the whole group: redirections apply left-to-right, so on a
    # bare `exec 3<>… 2>/dev/null` the failing /dev/tcp connect prints "Connection refused"
    # to the still-current stderr *before* 2>/dev/null takes effect. The brace group routes
    # that message to /dev/null while leaving fd 3 open in this shell on success.
    if { exec 3<>"/dev/tcp/127.0.0.1/$p"; } 2>/dev/null; then
      exec 3<&- 3>&- # in use; try another
    else
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Wait until the guest sshd answers with its banner. We probe the raw port (not a full
# ssh session) because the sshd ForceCommand would otherwise launch claude on every probe.
wait_for_boot() {
  # Cold TCG (software emulation) boots are far slower than KVM and vary with host load, so
  # a ~36s cap (120 × 0.3s) produces spurious "boot failed" under emulation (the box may still
  # be booting). The cap is a TIMEOUT, not a fixed wait — the loop returns the instant sshd
  # answers — so a generous budget costs nothing on a fast boot. Give the long budget to anything
  # that might run emulated (tcg, or auto's `kvm:tcg` that could fall back at init); only the
  # committed `kvm` accel keeps the snappy cap. CCVM_BOOT_TRIES overrides for pathological cases.
  # The spinner (if any) animates in the background — see spinner_start — so this loop just
  # probes and sleeps; it never touches the terminal itself.
  local _ banner tries="${CCVM_BOOT_TRIES:-120}"
  [[ -z ${CCVM_BOOT_TRIES:-} && ${ACCEL:-} != kvm ]] && tries=600
  for _ in $(seq 1 "$tries"); do
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    # Brace group, not a bare `exec … 2>/dev/null`: the connect is attempted before a
    # trailing redirect applies, leaking "Connection refused" to the terminal on every
    # pre-boot probe. See pick_port for the full explanation.
    if { exec 3<>"/dev/tcp/127.0.0.1/$PORT"; } 2>/dev/null; then
      if IFS= read -r -t 2 banner <&3; then
        exec 3<&- 3>&-
        case "$banner" in SSH-*) return 0 ;; esac
      else
        exec 3<&- 3>&-
      fi
    fi
    sleep 0.3
  done
  return 1
}

# ---- argument handling -----------------------------------------------------
# Intercept ccvm-only flags; everything else is forwarded verbatim to claude.
# (We deliberately do NOT claim bare --debug so that `claude --debug` still passes
# through; ccvm's own debug is CCVM_DEBUG=1 or --ccvm-debug.)
SHELL_MODE=0
DEBUG="${CCVM_DEBUG:-0}"
# Host-side test hook: populate the seed and assemble the QEMU args, then stop before
# booting (see the dry-run block just before boot). Not a documented user flag.
DRYRUN="${CCVM_DRYRUN:-0}"
[[ ${CCVM_SHELL:-0} == 1 ]] && SHELL_MODE=1
MODE_OVERRIDE=""
SHOW_HELP=0
SHOW_VERSION=0
FWD=()
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=1 ;;
    --ccvm-debug) DEBUG=1 ;;
    # ccvm-only file-sharing toggles. Consumed here (never appended to FWD), so they are
    # NOT forwarded to claude — claude still receives only the user's own arguments.
    --writable-cwd) MODE_OVERRIDE=rw ;;
    --read-only-cwd) MODE_OVERRIDE=overlay ;;
    # ccvm's own help/version. Namespaced (--ccvm-*) so bare --help/--version still pass
    # through to claude, preserving transparent passthrough.
    --ccvm-help) SHOW_HELP=1 ;;
    --ccvm-version) SHOW_VERSION=1 ;;
    *) FWD+=("$arg") ;;
  esac
done

# Help/version short-circuit: print and exit before any VM work (no scratch dir, keys, or
# boot), so they are instant and side-effect-free. Help wins if both are given.
if [[ $SHOW_HELP == 1 ]]; then
  ccvm_help
  exit 0
fi
if [[ $SHOW_VERSION == 1 ]]; then
  printf 'ccvm %s\n' "$VERSION"
  exit 0
fi

# File-sharing mode precedence: an explicit ccvm flag wins, else the CCVM_WRITABLE_CWD env
# var, else the baked default (writableCwd, true by default).
case "${CCVM_WRITABLE_CWD:-}" in
  1 | true | yes) MODE=rw ;;
  0 | false | no) MODE=overlay ;;
esac
[[ -n $MODE_OVERRIDE ]] && MODE="$MODE_OVERRIDE"

# Back-compat: CCVM_SHARE_CLAUDE_CONFIG=0|1 toggles ALL claude items together (the old
# shareClaudeConfig knob). Per-item CCVM_SHARE_<ITEM> overrides below take precedence.
case "${CCVM_SHARE_CLAUDE_CONFIG:-}" in
  1 | true | yes)
    SHARE_SETTINGS=1; SHARE_CLAUDEMD=1; SHARE_COMMANDS=1
    SHARE_AGENTS=1; SHARE_SKILLS=1; SHARE_PLUGINS=1; SHARE_CONFIG=1 ;;
  0 | false | no)
    SHARE_SETTINGS=0; SHARE_CLAUDEMD=0; SHARE_COMMANDS=0
    SHARE_AGENTS=0; SHARE_SKILLS=0; SHARE_PLUGINS=0; SHARE_CONFIG=0 ;;
esac

# Per-item overrides (win over the back-compat block above and the baked defaults).
case "${CCVM_SHARE_SETTINGS:-}" in 1 | true | yes) SHARE_SETTINGS=1 ;; 0 | false | no) SHARE_SETTINGS=0 ;; esac
case "${CCVM_SHARE_CLAUDEMD:-}" in 1 | true | yes) SHARE_CLAUDEMD=1 ;; 0 | false | no) SHARE_CLAUDEMD=0 ;; esac
case "${CCVM_SHARE_COMMANDS:-}" in 1 | true | yes) SHARE_COMMANDS=1 ;; 0 | false | no) SHARE_COMMANDS=0 ;; esac
case "${CCVM_SHARE_AGENTS:-}" in 1 | true | yes) SHARE_AGENTS=1 ;; 0 | false | no) SHARE_AGENTS=0 ;; esac
case "${CCVM_SHARE_SKILLS:-}" in 1 | true | yes) SHARE_SKILLS=1 ;; 0 | false | no) SHARE_SKILLS=0 ;; esac
case "${CCVM_SHARE_PLUGINS:-}" in 1 | true | yes) SHARE_PLUGINS=1 ;; 0 | false | no) SHARE_PLUGINS=0 ;; esac
case "${CCVM_SHARE_CONFIG:-}" in 1 | true | yes) SHARE_CONFIG=1 ;; 0 | false | no) SHARE_CONFIG=0 ;; esac

# Project-history persistence precedence: CCVM_PERSIST_PROJECTS overrides the baked
# persistClaudeProjects default for one run (mounts host ~/.claude/projects read-write so
# session transcripts + memory survive — `claude --resume` across runs, persistent memory).
case "${CCVM_PERSIST_PROJECTS:-}" in
  1 | true | yes) PERSISTPROJECTS=1 ;;
  0 | false | no) PERSISTPROJECTS=0 ;;
esac

# Git-config sharing precedence: CCVM_SHARE_GIT_CONFIG overrides the baked share.gitConfig
# default for one run, same pattern as above.
case "${CCVM_SHARE_GIT_CONFIG:-}" in
  1 | true | yes) SHAREGIT=1 ;;
  0 | false | no) SHAREGIT=0 ;;
esac

# ccvm-context CLAUDE.md precedence: CCVM_CLAUDE_MD, if SET (even to empty), overrides the baked
# default file for one run — a path names an alternate context file; empty disables injection.
# `+x` distinguishes "set empty" (disable) from "unset" (use the baked @CLAUDEMD@).
[[ -n ${CCVM_CLAUDE_MD+x} ]] && CLAUDEMD="$CCVM_CLAUDE_MD"

# Guest-memory locking precedence: CCVM_MLOCK overrides the baked lockGuestMemory default for
# one run, same override pattern as the toggles above.
case "${CCVM_MLOCK:-}" in
  1 | true | yes) MEMLOCK=1 ;;
  0 | false | no) MEMLOCK=0 ;;
esac

# VM-disk precedence: CCVM_VM_DISK_SIZE overrides the baked vmDiskSize for one run. A positive
# integer (GiB) turns it on; 0/off/no/empty turns it off. Carries a value, so we match the
# off-words explicitly and otherwise take the integer as the size (validated in the disk block).
case "${CCVM_VM_DISK_SIZE:-__unset__}" in
  __unset__) : ;; # not set — keep the baked default
  0 | off | no | false | "") VMDISKSIZE=0 ;;
  *) VMDISKSIZE="$CCVM_VM_DISK_SIZE" ;;
esac

# Guest RAM precedence: CCVM_MEMORY (MiB) overrides the baked `memory` default for one run.
# Memory is a runtime QEMU arg (no rebuild), so a heavy project can ask for more without
# touching config: CCVM_MEMORY=16384 ccvm … . Resolved before the mlock preflight, which
# sizes its RLIMIT_MEMLOCK check against MEMORY.
if [[ -n ${CCVM_MEMORY:-} ]]; then
  if [[ $CCVM_MEMORY =~ ^[1-9][0-9]*$ ]]; then
    MEMORY="$CCVM_MEMORY"
  else
    die "CCVM_MEMORY must be a positive integer (MiB); got '$CCVM_MEMORY'"
  fi
fi

# ---- preflight -------------------------------------------------------------
WORKDIR="$PWD"
[[ -d $WORKDIR ]] || die "current directory '$WORKDIR' is not a directory"

# Refuse to run as host root. The workspace 9p share uses security_model=none (passthrough), so the
# file ops the guest performs execute with QEMU's host privileges — as root that lets a (prompt-
# injected) guest agent create root-owned / setuid-root files on the host workspace, i.e. host
# privilege escalation. Skip under the dry-run test hook (no VM, no 9p mount), so the host-side
# tests don't depend on the builder's uid. CCVM_ALLOW_ROOT=1 overrides for the rare case where it
# genuinely doesn't apply (e.g. a rootless-container "host").
if [[ $DRYRUN != 1 && ${CCVM_ALLOW_ROOT:-0} != 1 && $(id -u) -eq 0 ]]; then
  die "refusing to run as root — the workspace share uses 9p passthrough (security_model=none), so a guest agent could create root-owned/setuid files on the host. Run ccvm as a normal user (or set CCVM_ALLOW_ROOT=1 to override)."
fi

# ---- acceleration mode -----------------------------------------------------
# Declarative default baked from `programs.ccvm.acceleration`; CCVM_ACCEL overrides for one run.
# Three deliberately distinct modes (kept consistent in their checks + messaging):
#   auto — use KVM when usable, else fall back to TCG. NEVER hard-fails on acceleration (best
#          first-run experience). KVM path uses `-cpu max` (not host) so QEMU's own kvm->tcg
#          fallback (`-accel kvm:tcg`) stays valid if KVM dies at init on a present-but-broken host.
#   kvm  — you DECLARED KVM: error fast with an actionable reason if /dev/kvm is missing / not in
#          the kvm group / not writable, and NO silent TCG fallback (`-accel kvm`, `-cpu host`), so
#          a broken-but-present KVM surfaces QEMU's own KVM error instead of running slow.
#   tcg  — force software emulation; same clear messaging, never touches /dev/kvm.
ACCEL_MODE="@ACCELERATION@"
case "${CCVM_ACCEL:-}" in
  "") ;;
  auto | kvm | tcg) ACCEL_MODE="$CCVM_ACCEL" ;;
  *) die "CCVM_ACCEL must be 'auto', 'kvm', or 'tcg' (got '$CCVM_ACCEL')" ;;
esac

# Is /dev/kvm usable by this user? On failure sets KVM_REASON to an actionable explanation.
# CCVM_KVM_DEV overrides the device path (internal seam: lets tests simulate states portably).
KVM_REASON=""
kvm_usable() {
  local dev="${CCVM_KVM_DEV:-/dev/kvm}" grp
  if [[ ! -e $dev ]]; then
    KVM_REASON="$dev does not exist — the KVM kernel modules aren't loaded, or hardware virtualization (VT-x/AMD-V) is disabled in firmware."
    return 1
  fi
  if [[ ! -w $dev ]]; then
    grp="$(stat -c '%G' "$dev" 2>/dev/null || echo kvm)"
    KVM_REASON="$dev is not writable by you — add yourself to the '$grp' group (sudo usermod -aG $grp ${USER:-<you>}, then re-login) or fix its permissions."
    return 1
  fi
  return 0
}

case "$ACCEL_MODE" in
  tcg)
    ACCEL="tcg"
    CPU="max"
    ;;
  kvm)
    if kvm_usable; then
      ACCEL="kvm" # committed — no TCG fallback, so a broken KVM surfaces QEMU's own error
      CPU="host"  # full near-native model (valid because we're committed to KVM)
    else
      die "acceleration is 'kvm' but KVM is unavailable: $KVM_REASON Use acceleration = \"auto\" to fall back to software emulation, or \"tcg\" to force it."
    fi
    ;;
  auto)
    if kvm_usable; then
      ACCEL="kvm:tcg" # prefer KVM, let QEMU fall back to TCG if it dies at init
      CPU="max"       # valid under BOTH kvm and tcg, so that fallback actually works
    else
      warn "KVM unavailable ($KVM_REASON) — using software emulation (TCG): correct but slower. Set acceleration = \"kvm\" to require KVM, or \"tcg\" to silence this."
      ACCEL="tcg"
      CPU="max"
    fi
    ;;
  *)
    die "internal: invalid acceleration mode '$ACCEL_MODE' (expected auto, kvm, or tcg)"
    ;;
esac

# Auth is optional, and shareClaudeConfig does NOT provide it: the host login (the OAuth
# credential) is deliberately not shared into the VM. If present, the API key rides the
# encrypted SSH channel via SendEnv -> AcceptEnv — never on disk or argv. With no key, claude
# starts unauthenticated: run its in-VM `/login` (web/OAuth) flow — copy the printed URL into
# your browser, paste the code back. Anything obtained that way lives only in the VM's tmpfs
# and evaporates on exit (ephemeral, by design).
if [[ $SHELL_MODE != 1 && -z ${!APIKEYVAR:-} ]]; then
  warn "\$$APIKEYVAR is not set — starting Claude unauthenticated (ccvm shares your settings and memory, not your login). Run /login inside the VM for web auth, or set \$$APIKEYVAR; either way the credential stays in the VM and vanishes on exit."
fi

# mlock preflight: QEMU started with mem-lock=on aborts if it cannot lock the guest RAM, so
# surface a clear, loud hint early instead of a cryptic qemu failure when RLIMIT_MEMLOCK is
# too low. The required lock is the guest RAM plus QEMU's own overhead; we warn when the
# limit is below the guest size (a limit at or just above it can still be borderline).
if [[ $MEMLOCK == 1 ]]; then
  memlock_kib="$(ulimit -l)"
  if [[ $memlock_kib != unlimited ]] && ((memlock_kib < MEMORY * 1024)); then
    warn "============================================================================"
    warn "lockGuestMemory (mlock) is ON, but this shell's RLIMIT_MEMLOCK is too low:"
    warn "    limit:       ${memlock_kib} KiB"
    warn "    guest needs: $((MEMORY * 1024)) KiB (${MEMORY} MiB) + QEMU overhead"
    warn "QEMU will almost certainly fail to start with 'mlock: Cannot allocate memory'."
    warn "Fix it one of these ways:"
    warn "  - this shell only:   ulimit -l unlimited   (then re-run ccvm)"
    warn "  - systemd user units: set LimitMEMLOCK=infinity"
    warn "  - PAM/limits.conf:   add '<user> - memlock unlimited' (then re-login)"
    warn "  - skip locking once: CCVM_MLOCK=0 ccvm ...   (RAM may reach host swap)"
    warn "See README 'Locking guest memory' for details."
    warn "============================================================================"
  fi
fi

# ---- scratch dir + trap ----------------------------------------------------
TMP="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ccvm.XXXXXX")"
trap cleanup EXIT INT TERM HUP

# ---- ephemeral SSH identities ---------------------------------------------
ssh-keygen -t ed25519 -N "" -q -f "$TMP/id"      # client identity
ssh-keygen -t ed25519 -N "" -q -f "$TMP/hostkey" # guest host key (pinned below)

PORT="$(pick_port)" || die "could not find a free localhost port"

# We generated the guest's host key ourselves, so we can pin it and keep
# StrictHostKeyChecking=yes — no blind TOFU.
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cat "$TMP/hostkey.pub")" >"$TMP/known_hosts"

# ---- seed (read-only 9p share the guest consumes) --------------------------
SEED="$TMP/seed"
mkdir -p "$SEED"
cp "$TMP/id.pub" "$SEED/authorized_keys"
cp "$TMP/hostkey" "$SEED/ssh_host_ed25519_key"
chmod 600 "$SEED/ssh_host_ed25519_key"
cp "$TMP/hostkey.pub" "$SEED/ssh_host_ed25519_key.pub"
printf '%s' "$WORKDIR" >"$SEED/workdir"
printf '%s' "$MODE" >"$SEED/mode"
printf '%s' "$SHELL_MODE" >"$SEED/shell"
# Dry-run only: record the resolved acceleration (mode + QEMU accel + cpu) so host.sh can assert
# the mode→args mapping without booting. Not written on real runs (the guest never reads it).
[[ $DRYRUN == 1 ]] && printf '%s %s %s\n' "$ACCEL_MODE" "$ACCEL" "$CPU" >"$SEED/accel"
# Host user identity. The guest remaps its agent user (ccvm) to these so 9p passthrough
# (security_model=none) yields correct workspace ownership in rw mode: a host uid != 1000
# would otherwise see the project owned by a foreign uid (agent can't write its own files)
# and create files owned by 1000 on the host. Non-secret integers — never the API key.
printf '%s' "$(id -u)" >"$SEED/host-uid"
printf '%s' "$(id -g)" >"$SEED/host-gid"
# Forwarded argv, NUL-separated so spaces/quotes/globs survive (reconstructed in the
# guest with `mapfile -d ''`). Never reassembled by string-splitting.
if ((${#FWD[@]})); then
  printf '%s\0' "${FWD[@]}" >"$SEED/claude-args"
else
  : >"$SEED/claude-args"
fi
# NOTE: the API key is deliberately absent from the seed.

# ---- assemble QEMU device args --------------------------------------------
MACHINE="${CCVM_MACHINE:-@DEFAULTMACHINE@}"
if [[ $MACHINE == microvm ]]; then
  MACHINE_ARG="microvm,accel=$ACCEL,rtc=on" # rtc=on so the guest clock is correct for TLS
  BUS="device"                              # virtio-mmio transport
else
  MACHINE_ARG="$MACHINE,accel=$ACCEL"
  BUS="pci"
fi

# Root store: always a self-contained read-only squashfs (max isolation — nothing of the
# host store is exposed). The guest mounts it at /nix/store, or (with in-VM nix) as the
# read-only overlay lower under a writable upper.
STORE_ARGS=()
STORE_ARGS+=(-drive "id=store,file=$STOREIMG,format=raw,if=none,readonly=on")
STORE_ARGS+=(-device "virtio-blk-$BUS,drive=store")

# Workspace share. security_model=none (passthrough) — not mapped-xattr — so files
# created in rw mode are owned by the host user with real perms (truly native), and no
# .virtfs_metadata pollution is scattered across the project.
WS_FSDEV="local,id=ws,path=$WORKDIR,security_model=none"
[[ $MODE == overlay ]] && WS_FSDEV="$WS_FSDEV,readonly=on"

# ---- ~/.claude allowlist staging (replaces the old whole-dir 9p config mount) ----
# Each enabled share.* item is copied with cp -aL (dereferences home-manager symlinks into
# real files) into $SEED/claude-config/<name>. The guest lays them into a fresh tmpfs
# ~/.claude at boot — no 9p config mount, no root-private lower, no overlay whiteout.
# Everything NOT listed here (projects/, sessions/, history.jsonl, .credentials.json, etc.)
# NEVER reaches the seed by construction. Defense in depth: a final find strips any
# .credentials.json that a directory cp dragged in at any depth.
CLAUDEDIR="$HOME/.claude"
if [[ -d "$CLAUDEDIR" ]]; then
  CFGOUT="$SEED/claude-config"
  mkdir -p "$CFGOUT"

  # File items: copy individual files if they exist (cp -aL dereferences symlinks).
  if [[ $SHARE_SETTINGS == 1 ]]; then
    for f in settings.json settings.local.json; do
      [[ -e "$CLAUDEDIR/$f" ]] && cp -aL "$CLAUDEDIR/$f" "$CFGOUT/$f" 2>/dev/null || true
    done
  fi
  if [[ $SHARE_CLAUDEMD == 1 ]]; then
    [[ -e "$CLAUDEDIR/CLAUDE.md" ]] && cp -aL "$CLAUDEDIR/CLAUDE.md" "$CFGOUT/CLAUDE.md" 2>/dev/null || true
  fi

  # Directory items: copy the whole dir if it exists.
  if [[ $SHARE_COMMANDS == 1 ]]; then
    [[ -d "$CLAUDEDIR/commands" ]] && cp -aL "$CLAUDEDIR/commands" "$CFGOUT/commands" 2>/dev/null || true
  fi
  if [[ $SHARE_AGENTS == 1 ]]; then
    [[ -d "$CLAUDEDIR/agents" ]] && cp -aL "$CLAUDEDIR/agents" "$CFGOUT/agents" 2>/dev/null || true
  fi
  if [[ $SHARE_SKILLS == 1 ]]; then
    [[ -d "$CLAUDEDIR/skills" ]] && cp -aL "$CLAUDEDIR/skills" "$CFGOUT/skills" 2>/dev/null || true
  fi
  if [[ $SHARE_PLUGINS == 1 ]]; then
    [[ -d "$CLAUDEDIR/plugins" ]] && cp -aL "$CLAUDEDIR/plugins" "$CFGOUT/plugins" 2>/dev/null || true
  fi
  if [[ $SHARE_CONFIG == 1 ]]; then
    [[ -d "$CLAUDEDIR/config" ]] && cp -aL "$CLAUDEDIR/config" "$CFGOUT/config" 2>/dev/null || true
  fi

  # Defense in depth: strip any .credentials.json a directory copy dragged in at any depth.
  # The credential must never reach the on-disk seed. Invariant: grep $SEED for the credential -> 0.
  find "$CFGOUT" -name '.credentials.json' -delete 2>/dev/null || true
fi

# ~/.claude.json (home-root, distinct from ~/.claude/ dir) is config, but it CAN carry MCP
# server blocks with inline secrets (env tokens, Authorization headers) and a legacy primaryApiKey.
# Gated on share.settings (it is startup config). Stage a SANITIZED copy: drop mcpServers[].env,
# mcpServers[].headers and primaryApiKey (same pattern as share.gitConfig strips credential.*),
# keeping the non-secret structure. That retained structure DOES include identifying account
# metadata (oauthAccount: email + org/account UUIDs, userID) — not a credential (the token lives
# only in the excluded .credentials.json), and the same identity already crosses via share.gitConfig.
# Secure-fail: if jq is missing or the file is not valid JSON,
# stage NOTHING rather than risk leaking a token — hence jq is a wrapper runtimeInput.
if [[ $SHARE_SETTINGS == 1 && -f "$HOME/.claude.json" ]]; then
  if command -v jq >/dev/null 2>&1 &&
    jq 'if has("mcpServers") then .mcpServers |= with_entries(.value |= del(.env, .headers)) else . end | del(.primaryApiKey)' \
      "$HOME/.claude.json" >"$SEED/claude-json" 2>/dev/null; then
    : # sanitized copy staged
  else
    rm -f "$SEED/claude-json"
    warn "could not sanitize ~/.claude.json (jq missing or invalid JSON) — not staging it into the VM"
  fi
fi

# ---- persist ~/.claude/projects (opt-in) -----------------------------------
# Claude stores per-project SESSION TRANSCRIPTS (read by `claude --resume`) and per-project
# MEMORY under ~/.claude/projects/<cwd-slug>/. By default those live in the ephemeral tmpfs
# ~/.claude and vanish on exit — a session started in ccvm can't be resumed later. When opted
# in we mount the host's ~/.claude/projects read-WRITE into the guest's tmpfs ~/.claude so
# those writes persist back to the host. Scoped to projects/ ONLY: the OAuth credential
# (~/.claude/.credentials.json, at the ~/.claude ROOT) is never staged and never in this share.
PROJECTS_ARGS=()
if [[ $PERSISTPROJECTS == 1 ]]; then
  PROJDIR="$HOME/.claude/projects"
  mkdir -p "$PROJDIR" # create on the host so the share exists even on a first-ever run
  PROJECTS_ARGS+=(-fsdev "local,id=cproj,path=$PROJDIR,security_model=none")
  PROJECTS_ARGS+=(-device "virtio-9p-$BUS,fsdev=cproj,mount_tag=ccvm-claude-projects")
  printf '1' >"$SEED/persist-claude-projects"
fi

# ---- encrypted ephemeral disk pool (opt-in: vmDiskSize) --------------------
# vmDiskSize (GiB) attaches a raw SPARSE virtio-blk image the guest will LUKS-encrypt with a key
# it generates in its OWN RAM — the key never crosses 9p, so the host only ever sees ciphertext
# (same spirit as the API key). It is the VM's writable disk POOL for bulk, non-secret data
# that would OOM the RAM-backed tmpfs: a /scratch mount today (build outputs, node_modules,
# caches) and, once the writable-store increment lands, an overlay upper for /nix/store. HOME and
# root stay tmpfs, so secrets never leave guest RAM. The image MUST live in a disk-backed dir,
# never tmpfs/$TMP — putting the "disk" back in RAM defeats the point — so we refuse a tmpfs target
# (override CCVM_SCRATCH_ALLOW_TMPFS=1). Wiped on exit cryptographically (key dies with guest RAM)
# and via the cleanup rm.
SCRATCH_ARGS=()
SCRATCH_IMG=""
# String compare first (not (( )) arithmetic): a non-numeric VMDISKSIZE evaluates to 0 in (( ))
# and would silently disable the disk — we want a loud error on a typo instead.
if [[ $VMDISKSIZE != 0 ]]; then
  [[ $VMDISKSIZE =~ ^[1-9][0-9]*$ ]] ||
    die "vmDiskSize must be a positive integer (GiB) or 0 to disable (got '$VMDISKSIZE')"
  SCRATCH_DIR="${CCVM_SCRATCH_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ccvm}"
  mkdir -p "$SCRATCH_DIR" || die "could not create disk-image dir '$SCRATCH_DIR'"
  if [[ ${CCVM_SCRATCH_ALLOW_TMPFS:-0} != 1 ]]; then
    fstype="$(stat -f -c %T "$SCRATCH_DIR" 2>/dev/null || echo unknown)"
    case "$fstype" in
      tmpfs | ramfs)
        die "disk-image dir '$SCRATCH_DIR' is on $fstype (RAM) — a disk-backed dir is the whole point; point CCVM_SCRATCH_DIR at real disk, or set CCVM_SCRATCH_ALLOW_TMPFS=1 to override" ;;
    esac
  fi
  # Sparse: only consumes what the guest actually writes, up to this cap. Unique per run so
  # concurrent ccvm sessions don't collide; the trap removes exactly this file.
  SCRATCH_IMG="$SCRATCH_DIR/vmdisk-$$-$RANDOM.img"
  truncate -s "${VMDISKSIZE}G" "$SCRATCH_IMG" || die "could not create disk image '$SCRATCH_IMG'"
  # serial=ccvm-scratch so the guest finds it at /dev/disk/by-id/virtio-ccvm-scratch regardless
  # of disk ordering (the squashfs store is /dev/vda, so this scratch disk is /dev/vdb — by-id
  # avoids hardcoding either).
  SCRATCH_ARGS+=(-drive "id=scratch,file=$SCRATCH_IMG,format=raw,if=none")
  SCRATCH_ARGS+=(-device "virtio-blk-$BUS,drive=scratch,serial=ccvm-scratch")
  printf '1' >"$SEED/vm-disk"
fi

# ---- git config passthrough (default on) -----------------------------------
# Native devex: in-VM `git` should commit as you, with your aliases and global ignores —
# like native claude. We stage a SANITIZED copy of your GLOBAL git config into the seed (the
# guest lays it at ~/.config/git/config). Sanitized because home-manager writes absolute
# /nix/store/… paths for the editor/pager/diff tools and the gh credential helper — those
# paths don't exist in the guest, so carried verbatim they would dangle (broken pager) or
# fail commits. So we:
#   * drop any setting whose value points into /nix/store (host-only tool paths),
#   * drop credential.* entirely (no host credentials cross into the VM; ~/.ssh and gh tokens
#     are never shared — `git commit` works, `git push` to an SSH remote is out of scope),
#   * stage core.excludesfile's resolved CONTENT to the guest's default ignore path,
#   * force-disable commit/tag signing (the signing key is deliberately not carried; a leftover
#     gpgsign=true would otherwise break `git commit` in the guest).
# Non-secret config only — never the API key or any credential. Best-effort: a hiccup here must
# not block the launch. Runtime override: CCVM_SHARE_GIT_CONFIG=0|1.
if [[ $SHAREGIT == 1 ]] && command -v git >/dev/null 2>&1 &&
  [[ -n "$(git config --global --list 2>/dev/null)" ]]; then
  staged="$SEED/gitconfig"
  : >"$staged"
  # Global key/value pairs, NUL-delimited (key\nvalue\0) so values with spaces/newlines
  # survive. Keep everything except host-only/store-path settings and credentials.
  while IFS= read -r -d '' pair; do
    key="${pair%%$'\n'*}"
    val="${pair#*$'\n'}"
    case "$key" in
      credential.*) continue ;;                 # no host credentials inside the VM
      core.excludesfile) continue ;;            # staged separately as the default ignore file
      commit.gpgsign | tag.gpgsign) continue ;; # forced off below
    esac
    case "$val" in
      */nix/store/*) continue ;; # home-manager tool path — would dangle in the guest
    esac
    git config --file "$staged" "$key" "$val" || true
  done < <(git config --global --list -z 2>/dev/null)
  # The signing key lives in ~/.ssh / the host keyring and is never shared, so disable signing
  # or `git commit` would fail in the guest.
  git config --file "$staged" commit.gpgsign false || true
  git config --file "$staged" tag.gpgsign false || true
  # Drop the file if nothing survived sanitization beyond the forced gpgsign lines (keeps the
  # guest from installing a near-empty config). user.name/aliases/etc. make it worth staging.
  if [[ "$(git config --file "$staged" --list 2>/dev/null | grep -cv '^\(commit\|tag\)\.gpgsign=')" == 0 ]]; then
    rm -f "$staged"
  fi
  # Global ignore: stage the RESOLVED contents at the guest's XDG-default ignore path so your
  # personal ignores apply even though the host excludesfile path doesn't exist in the guest.
  ex="$(git config --global --path core.excludesfile 2>/dev/null || true)"
  if [[ -n $ex ]]; then
    exreal="$(readlink -f "$ex" 2>/dev/null || true)"
    [[ -n $exreal && -r $exreal ]] && cp -L "$exreal" "$SEED/gitignore"
  fi
fi

# ---- ccvm-context CLAUDE.md (default on) -----------------------------------
# Stage the agent-facing "you are inside ccvm" global memory into the seed; the guest lays it
# at ~/.claude/CLAUDE.md (appending to any host-shared one). Staged via the seed — never a
# claude flag — so transparent passthrough holds. We PREPEND a runtime-accurate note about the
# current file-sharing mode, which the build-time-baked file cannot know (mode is resolved per
# run via flags / CCVM_WRITABLE_CWD). Empty CLAUDEMD (extraClaudeMd="" or CCVM_CLAUDE_MD=) => skip.
if [[ -n $CLAUDEMD && -r $CLAUDEMD ]]; then
  {
    printf '# ccvm session\n\n'
    if [[ $MODE == rw ]]; then
      printf 'File edits in the project directory are written LIVE to the host filesystem (writableCwd=true) — treat changes here as real edits to the user'\''s working tree.\n\n'
    else
      printf 'File edits are kept in an ephemeral overlay and are DISCARDED when the VM exits — they do NOT reach the host (writableCwd=false). Anything worth keeping must be exported before exit (e.g. committed and pushed, or copied out by the user).\n\n'
    fi
    if [[ $PERSISTPROJECTS == 1 ]]; then
      printf 'Your session history and memory PERSIST to the host this run (CCVM_PERSIST_PROJECTS is on), so saved memory survives and sessions can be resumed later.\n\n'
    else
      printf 'Your session history and memory do NOT persist across runs — they live only in this throwaway VM and are discarded on exit. So strongly PREFER writing durable information into the codebase (CLAUDE.md, README, docs/, code) and committing it, over saving it to memory. (Set CCVM_PERSIST_PROJECTS=1 to persist memory + resumable sessions.)\n\n'
    fi
    if ((VMDISKSIZE > 0)); then
      printf 'A disk-backed, encrypted scratch area is mounted at /scratch — use it for LARGE ephemeral writes (build outputs, node_modules, target/, caches) that would otherwise exhaust the RAM-backed filesystem. It is wiped on exit like everything else, so nothing there is durable.\n\n'
    fi
    cat "$CLAUDEMD"
  } >"$SEED/claude-md"
fi

# ---- egress allowlist (opt-in) --------------------------------------------
# Empty baked list => open egress (the native default; no firewall, nothing written to the
# seed). A non-empty list switches the guest to default-deny egress: we resolve any FQDNs
# HERE (the host has working DNS) into IP rules, pass bare IPs/CIDRs through unchanged, and
# hand the guest the resolved set + ports via the seed. api.anthropic.com is always included
# so authentication never breaks even if the user forgot to list it.
if [[ -n ${EGRESSALLOW// /} ]]; then
  : >"$SEED/egress-allow"
  # name->IP pin map (FQDN entries only): the guest writes these into /etc/hosts so the in-VM
  # resolver returns exactly the IPs the firewall allows. Without it the host (launch-time) and
  # guest (runtime) resolvers diverge on round-robin/CDN hosts — the guest dials an unpinned IP
  # and it's silently dropped (the request hangs). See guest/launcher.nix + CLAUDE.md "Egress".
  : >"$SEED/egress-hosts"
  # The "lock down" marker: present whenever the user opted in, independent of how many IPs
  # actually resolved. The guest enforces the firewall on THIS file, not on a non-empty
  # allow set, so an empty allow set fails CLOSED (deny-all) instead of silently reverting to
  # open egress — the allowlist must never degrade into "no containment".
  printf '1' >"$SEED/egress-enforce"
  resolve_into_seed() {
    local entry="$1" ip _
    case "$entry" in
      */* | *:*) printf '%s\n' "$entry" >>"$SEED/egress-allow" ;; # CIDR or IPv6 literal — verbatim
      *[!0-9.]*)                                                   # has a non-IPv4 char => FQDN; resolve to A/AAAA
        while read -r ip _; do
          if [[ -n $ip ]]; then
            printf '%s\n' "$ip" >>"$SEED/egress-allow"
            printf '%s %s\n' "$ip" "$entry" >>"$SEED/egress-hosts" # pin name->IP (see above)
          fi
        done < <(getent ahosts "$entry" 2>/dev/null)
        ;;
      *) printf '%s\n' "$entry" >>"$SEED/egress-allow" ;; # bare IPv4 — verbatim
    esac
  }
  resolve_into_seed api.anthropic.com
  # Explicit word-split of the space-separated allowlist into an array (keeps shellcheck
  # happy — SC2086 — and makes the intent unambiguous).
  read -ra _egress_entries <<<"$EGRESSALLOW"
  for entry in "${_egress_entries[@]}"; do resolve_into_seed "$entry"; done
  sort -u "$SEED/egress-allow" -o "$SEED/egress-allow"
  sort -u "$SEED/egress-hosts" -o "$SEED/egress-hosts"
  # Fail closed, loudly, if the user opted in but NOTHING resolved (no literal IP/CIDR and
  # total DNS failure — even api.anthropic.com). Booting on would either (a) leave egress
  # open were the guest gating on a non-empty set, or (b) start a VM that can't reach the API
  # anyway. Refuse with an actionable message instead. (The guest still fails closed via the
  # enforce marker as defense in depth; this just turns a dead VM into a clear error.)
  if [[ ! -s "$SEED/egress-allow" ]]; then
    die "egressAllowlist is set but nothing resolved (host DNS down?) — refusing to boot rather than run with an unenforceable allowlist. Fix DNS, or add a literal IP/CIDR to the allowlist."
  fi
  # Ports as an nft-ready comma list (squeeze runs of spaces to single commas, trim edges).
  ports_csv="$(printf '%s' "${EGRESSPORTS:-443}" | tr -s ' ' ',')"
  ports_csv="${ports_csv#,}"
  printf '%s' "${ports_csv%,}" >"$SEED/egress-ports"
fi

# QEMU seccomp sandbox (consumed in QEMU_ARGS below). On by default; CCVM_QEMU_SANDBOX=0 is an
# escape hatch for a host whose qemu was built without seccomp support (rare on nixpkgs).
SANDBOX_ARGS=()
if [[ ${CCVM_QEMU_SANDBOX:-1} != 0 ]]; then
  # Quote the option value: the commas are QEMU's sub-option syntax, not array separators (SC2054).
  SANDBOX_ARGS+=(-sandbox "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny")
fi

QEMU_ARGS=(
  -machine "$MACHINE_ARG"
  -cpu "$CPU"
  -m "$MEMORY"
  -smp "$CORES"
  -kernel "$KERNEL"
  -initrd "$INITRD"
  -append "$APPEND"
  "${STORE_ARGS[@]}"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22"
  -device "virtio-net-$BUS,netdev=net0"
  -fsdev "local,id=seed,path=$SEED,security_model=none,readonly=on"
  -device "virtio-9p-$BUS,fsdev=seed,mount_tag=ccvm-seed"
  -fsdev "$WS_FSDEV"
  -device "virtio-9p-$BUS,fsdev=ws,mount_tag=ccvm-workspace"
  "${PROJECTS_ARGS[@]}"
  "${SCRATCH_ARGS[@]}"
  -device "virtio-rng-$BUS"
  # Confine QEMU itself with the seccomp sandbox. QEMU is the trust boundary, so a device-emulation /
  # 9p / slirp escape should hit a seccomp wall instead of running with the launching user's full
  # privileges and environment. obsolete=deny + elevateprivileges=deny + spawn=deny + resourcecontrol=
  # deny is the standard hardened set; slirp is built in and we invoke no external network/disk
  # helpers, so nothing here legitimately needs to fork/exec. (nixpkgs' qemu is built with seccomp
  # support; set CCVM_QEMU_SANDBOX=0 to disable if a future host lacks it.)
  "${SANDBOX_ARGS[@]}"
  -display none
  -monitor none
  -serial "file:$TMP/console.log"
  -no-reboot
)

# Optionally mlock the guest RAM (lockGuestMemory / CCVM_MLOCK) so it can never be paged out
# to the host's possibly-unencrypted swap — keeping in-VM secrets (the API key in the guest
# environment, /login credentials in tmpfs) off host disk. Off by default; QEMU aborts at
# startup if RLIMIT_MEMLOCK is too small (see the preflight warning above).
[[ $MEMLOCK == 1 ]] && QEMU_ARGS+=(-overcommit mem-lock=on)

# ---- dry run (host-side test hook) -----------------------------------------
# CCVM_DRYRUN=1 performs every host-side step — generate keys, populate the seed, run the
# real config-staging loop, assemble the QEMU args — then stops before booting QEMU and
# prints the scratch dir. This is how the security-critical host guarantees are checked
# automatically without a VM: that the API key and the OAuth credential never reach the
# seed, that the forwarded argv round-trips verbatim, that the mode/share flags resolve
# correctly, and that escaping host-config symlinks are staged. The scratch dir is kept
# (the EXIT trap skips the rm under dry run) for the caller to grep, then remove.
if [[ $DRYRUN == 1 ]]; then
  printf '%s\n' "$TMP"
  warn "dry-run: seed populated at $SEED; no VM booted. Scratch kept at $TMP."
  exit 0
fi

# ---- boot ------------------------------------------------------------------
# Enable the boot spinner now (past the dry-run early-exit, so it never runs under a test).
# Only when stderr is a TTY and not in debug mode (whose console tail owns stderr already).
[[ -t 2 && $DEBUG != 1 ]] && PROGRESS=1
boot_msg="booting microVM, waiting for guest sshd…"
[[ $ACCEL == tcg ]] && boot_msg="booting microVM (software emulation — slow), waiting for guest sshd…"

# qemu runs headless in the background with stdio detached from the terminal so it never
# touches the TTY the user's claude session will own.
@QEMU@ "${QEMU_ARGS[@]}" </dev/null >"$TMP/qemu.log" 2>&1 &
QEMU_PID=$!

# In debug mode stream the guest console while it boots (killed before we hand the
# terminal to the TUI, so it never corrupts the screen).
if [[ $DEBUG == 1 ]]; then
  ( tail -n +1 -F "$TMP/console.log" >&2 2>/dev/null ) &
  TAILPID=$!
fi

# Spin while we wait (background; no-op unless PROGRESS=1). Stopped on both paths below.
spinner_start "$boot_msg"
if ! wait_for_boot; then
  spinner_stop # clear the spinner line so the failure dump starts clean
  warn "guest did not come up within timeout. Last console output:"
  tail -n 40 "$TMP/console.log" 2>/dev/null >&2 || true
  tail -n 20 "$TMP/qemu.log" 2>/dev/null >&2 || true
  die "boot failed"
fi
spinner_stop # boot succeeded — clear the line before handing the terminal to ssh -tt

# Stop the debug tail before handing the terminal to the interactive session.
if [[ -n ${TAILPID:-} ]]; then
  kill "$TAILPID" 2>/dev/null || true
  TAILPID=""
fi

# ---- connect (FOREGROUND — never exec, so the trap can tear down the VM) ----
ssh -tt -p "$PORT" -i "$TMP/id" \
  -o UserKnownHostsFile="$TMP/known_hosts" \
  -o StrictHostKeyChecking=yes \
  -o SendEnv="$APIKEYVAR" \
  -o LogLevel=ERROR \
  -o ConnectTimeout=5 \
  ccvm@127.0.0.1
RC=$?

exit "$RC"
