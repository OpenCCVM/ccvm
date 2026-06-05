# shellcheck shell=bash
#
# ccvm — boot an ephemeral microVM and drop the user straight into Claude Code.
#
# writeShellApplication supplies the shebang and `set -euo pipefail`. The @TOKENS@
# below are substituted with store paths / config at build time by lib/mkccvm.nix.
#
# Flow (see docs/design.md and spec §5): generate throwaway SSH keys, pin the guest
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
SHARECONFIG="@SHARECONFIG@"
MOUNTHOSTSTORE="@MOUNTHOSTSTORE@"
HOSTSTOREPATH="@HOSTSTOREPATH@"
MODE="@MODE@" # rw (autoUpdateFiles=true, default — mirrors native claude) | overlay (secure)

# ---- helpers ---------------------------------------------------------------
warn() { printf 'ccvm: %s\n' "$*" >&2; }
die() {
  printf 'ccvm: error: %s\n' "$*" >&2
  exit 1
}

# shellcheck disable=SC2329  # invoked indirectly via `trap` below, not by name.
cleanup() {
  # Stop the optional debug log tail first so it does not outlive us.
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
    else
      rm -rf "$TMP"
    fi
  fi
}

# Returns a free localhost TCP port. A connect that fails means nothing is listening, so
# the port is (very likely) free. A tiny TOCTOU race to the qemu bind is acceptable for a
# localhost dev tool (spec §3.2).
pick_port() {
  local p _
  for _ in $(seq 1 50); do
    p=$(((RANDOM % 20000) + 20000))
    if exec 3<>"/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
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
  local _ banner
  for _ in $(seq 1 120); do
    kill -0 "$QEMU_PID" 2>/dev/null || return 1
    if exec 3<>"/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
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
[[ ${CCVM_SHELL:-0} == 1 ]] && SHELL_MODE=1
MODE_OVERRIDE=""
FWD=()
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=1 ;;
    --ccvm-debug) DEBUG=1 ;;
    # ccvm-only file-sharing toggles. Consumed here (never appended to FWD), so they are
    # NOT forwarded to claude — claude still receives only the user's own arguments.
    --auto-update-files) MODE_OVERRIDE=rw ;;
    --no-auto-update-files) MODE_OVERRIDE=overlay ;;
    *) FWD+=("$arg") ;;
  esac
done

# File-sharing mode precedence: an explicit ccvm flag wins, else the CCVM_AUTOUPDATE env
# var, else the baked default (autoUpdateFiles, now true by default).
case "${CCVM_AUTOUPDATE:-}" in
  1 | true | yes) MODE=rw ;;
  0 | false | no) MODE=overlay ;;
esac
[[ -n $MODE_OVERRIDE ]] && MODE="$MODE_OVERRIDE"

# ---- preflight -------------------------------------------------------------
WORKDIR="$PWD"
[[ -d $WORKDIR ]] || die "current directory '$WORKDIR' is not a directory"

# KVM (near-native) when /dev/kvm is usable, else TCG software emulation. CCVM_ACCEL=tcg
# forces TCG even when /dev/kvm exists — needed under nested virt / CI where the device is
# present but broken.
if [[ ${CCVM_ACCEL:-} == tcg ]]; then
  ACCEL="tcg"
  CPU="max"
elif [[ -w /dev/kvm ]]; then
  ACCEL="kvm:tcg"
  CPU="host"
else
  warn "/dev/kvm is not writable — falling back to software emulation (TCG). This is correct but slow."
  ACCEL="tcg"
  CPU="max"
fi

# Auth is optional. If present, the API key rides the encrypted SSH channel via
# SendEnv -> AcceptEnv — never on disk or argv. With neither a key nor shared host
# config, claude simply starts unauthenticated: run its in-VM `/login` (web/OAuth)
# flow — copy the printed URL into your browser, paste the code back. Anything obtained
# that way lives only in the VM's tmpfs and evaporates on exit (ephemeral, by design).
if [[ $SHELL_MODE != 1 && $SHARECONFIG != 1 && -z ${!APIKEYVAR:-} ]]; then
  warn "\$$APIKEYVAR is not set and shareHostConfig is off — starting Claude unauthenticated. Run /login inside the VM for web auth (its credentials stay in the VM and vanish on exit)."
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
# Forwarded argv, NUL-separated so spaces/quotes/globs survive (reconstructed in the
# guest with `mapfile -d ''`). Never reassembled by string-splitting.
if ((${#FWD[@]})); then
  printf '%s\0' "${FWD[@]}" >"$SEED/claude-args"
else
  : >"$SEED/claude-args"
fi
# NOTE: the API key is deliberately absent from the seed.

# ---- assemble QEMU device args --------------------------------------------
MACHINE="${CCVM_MACHINE:-microvm}"
if [[ $MACHINE == microvm ]]; then
  MACHINE_ARG="microvm,accel=$ACCEL,rtc=on" # rtc=on so the guest clock is correct for TLS
  BUS="device"                              # virtio-mmio transport
else
  MACHINE_ARG="$MACHINE,accel=$ACCEL"
  BUS="pci"
fi

# Root store: a self-contained read-only squashfs by default (max isolation), or the
# host /nix/store shared read-only when mountHostNixStore is set (smaller/faster).
STORE_ARGS=()
if [[ $MOUNTHOSTSTORE == 1 ]]; then
  STORE_ARGS+=(-fsdev "local,id=nixstore,path=$HOSTSTOREPATH,security_model=none,readonly=on")
  STORE_ARGS+=(-device "virtio-9p-$BUS,fsdev=nixstore,mount_tag=ccvm-nixstore")
else
  STORE_ARGS+=(-drive "id=store,file=$STOREIMG,format=raw,if=none,readonly=on")
  STORE_ARGS+=(-device "virtio-blk-$BUS,drive=store")
fi

# Workspace share. security_model=none (passthrough) — not mapped-xattr — so files
# created in rw mode are owned by the host user with real perms (truly native), and no
# .virtfs_metadata pollution is scattered across the project.
WS_FSDEV="local,id=ws,path=$WORKDIR,security_model=none"
[[ $MODE == overlay ]] && WS_FSDEV="$WS_FSDEV,readonly=on"

# Optional: the host's Claude config, read-only — reuse your host login, settings, custom
# commands and global memory inside the VM. The ~/.claude directory rides a read-only 9p
# mount, so the OAuth credential it contains is never copied into the scratch dir. The
# separate home-root ~/.claude.json (non-secret config) is staged through the seed. The
# guest overlays both onto a writable tmpfs, so claude's writes are ephemeral and never
# reach the host.
CONFIG_ARGS=()
if [[ $SHARECONFIG == 1 ]]; then
  if [[ -d "$HOME/.claude" ]]; then
    CONFIG_ARGS+=(-fsdev "local,id=cfg,path=$HOME/.claude,security_model=none,readonly=on")
    CONFIG_ARGS+=(-device "virtio-9p-$BUS,fsdev=cfg,mount_tag=ccvm-config")
    printf '1' >"$SEED/share-config"
  fi
  [[ -f "$HOME/.claude.json" ]] && cp "$HOME/.claude.json" "$SEED/claude-json"
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
  "${CONFIG_ARGS[@]}"
  -device "virtio-rng-$BUS"
  -display none
  -monitor none
  -serial "file:$TMP/console.log"
  -no-reboot
)

# ---- boot ------------------------------------------------------------------
# qemu runs headless in the background with stdio detached from the terminal so it never
# touches the TTY the user's claude session will own.
qemu-system-x86_64 "${QEMU_ARGS[@]}" </dev/null >"$TMP/qemu.log" 2>&1 &
QEMU_PID=$!

# In debug mode stream the guest console while it boots (killed before we hand the
# terminal to the TUI, so it never corrupts the screen).
if [[ $DEBUG == 1 ]]; then
  ( tail -n +1 -F "$TMP/console.log" >&2 2>/dev/null ) &
  TAILPID=$!
fi

if ! wait_for_boot; then
  warn "guest did not come up within timeout. Last console output:"
  tail -n 40 "$TMP/console.log" 2>/dev/null >&2 || true
  tail -n 20 "$TMP/qemu.log" 2>/dev/null >&2 || true
  die "boot failed"
fi

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
