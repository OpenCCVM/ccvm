#!/usr/bin/env bash
# Image-paste bridge checks (clipboard.images). No VM, no socat: the security-critical half of
# the bridge is the HOST-SIDE reader (the part that talks to the real host clipboard), and the
# property that matters is that it is IMAGE-ONLY — it must stream clipboard images but never
# clipboard text, and never let the guest's request string widen that or inject a command. So we
# extract the REAL reader verbatim from wrapper/ccvm.sh (no drift) and drive it over a pipe, plus
# assert the guest shim's request-mapping in guest/default.nix refuses non-image targets.
#
# Driven by tests/default.nix (the `clipboard` check). Sources are passed in:
#   WRAPPER_SRC = wrapper/ccvm.sh   GUEST_SRC = guest/default.nix
set -euo pipefail

WRAPPER_SRC="${WRAPPER_SRC:?set WRAPPER_SRC to wrapper/ccvm.sh}"
GUEST_SRC="${GUEST_SRC:?set GUEST_SRC to guest/default.nix}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
ok() {
  printf '  ok   %s\n' "$1"
  pass=$((pass + 1))
}
fail() {
  printf '  FAIL %s\n' "$1" >&2
  exit 1
}

# ---- extract the real reader heredoc from the wrapper (between <<'CLIPEOF' and CLIPEOF) -------
awk '/<<.CLIPEOF.$/{f=1;next} /^CLIPEOF$/{f=0} f' "$WRAPPER_SRC" >"$WORK/clip-reader"
[ -s "$WORK/clip-reader" ] || fail "could not extract the clip-reader heredoc from $WRAPPER_SRC"
chmod +x "$WORK/clip-reader"
grep -q '^#!/bin/sh' "$WORK/clip-reader" || fail "extracted reader is missing its shebang"

# ---- a fake host clipboard tool: an image IS present, and so is a secret TEXT selection -------
printf '\x89PNG\r\n\x1a\nCCVM-FAKE-IMAGE-PAYLOAD' >"$WORK/expected.png"
cat >"$WORK/fakexclip" <<'EOF'
#!/bin/sh
t=""; while [ $# -gt 0 ]; do case "$1" in -t) t="$2"; shift 2;; *) shift;; esac; done
case "$t" in
  TARGETS) printf 'TIMESTAMP\nTARGETS\nimage/png\nimage/bmp\ntext/plain\nUTF8_STRING\n' ;;
  image/png) cat "$WORK/expected.png" ;;
  text/plain) printf 'SUPER-SECRET-PASSWORD-DO-NOT-LEAK' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/fakexclip"
export WORK

reader() { printf '%s\n' "$1" | "$WORK/clip-reader" x "$WORK/fakexclip"; }

# Dump what the reader saw when detection comes back empty. The reader discards the tool's stderr
# and its grep's status (`2>/dev/null`, `|| true`), so without this a failure is one opaque line.
# Seen once as a CI-only flake that passed on rerun; this makes the next occurrence self-explaining.
targets_diag() {
  {
    printf '  --- diagnostics ---\n'
    printf '  /bin/sh -> %s\n' "$(readlink -f /bin/sh 2>&1 || true)"
    printf '  grep    -> %s\n' "$(command -v grep 2>&1 || true)"
    printf '  reader stdout: [%s]\n' "$targets"
    printf '  reader stderr: [%s]\n' "$(printf 'TARGETS\n' | "$WORK/clip-reader" x "$WORK/fakexclip" 2>&1 >/dev/null || true)"
    rc=0
    raw="$("$WORK/fakexclip" -selection clipboard -t TARGETS -o 2>&1)" || rc=$?
    printf '  fakexclip TARGETS (rc=%s): [%s]\n' "$rc" "$raw"
    ls -l "$WORK" 2>&1 | sed 's/^/  /'
  } >&2
}

# 1. detection: a TARGETS request reports the image types, and NOTHING text-shaped.
targets="$(reader TARGETS)"
if ! printf '%s\n' "$targets" | grep -qi 'image/png'; then
  targets_diag
  fail "TARGETS did not advertise image/png"
fi
if printf '%s\n' "$targets" | grep -qiE 'text/|utf8|utf-8|string'; then
  fail "TARGETS leaked a text/non-image target: [$targets]"
fi
ok "detection reports image targets only (no text)"

# 2. image read round-trips byte-for-byte (binary-safe).
reader image/png >"$WORK/got.png"
cmp -s "$WORK/expected.png" "$WORK/got.png" || fail "image bytes did not round-trip"
ok "image/png streams the exact host clipboard bytes"

# 3. THE INVARIANT: host clipboard TEXT must never cross, in any text-ish form.
for t in 'text/plain' 'text/plain;charset=utf-8' 'UTF8_STRING' 'STRING'; do
  out="$(reader "$t" || true)"
  case "$out" in
    *SECRET* | *PASSWORD*) fail "host clipboard text crossed for target '$t'" ;;
  esac
  [ -z "$out" ] || fail "reader returned data for non-image target '$t': [$out]"
done
ok "host clipboard TEXT never crosses (image-only enforced host-side)"

# 4. the guest request is matched against literal case arms, so a crafted request can neither
#    widen to text nor inject a command. Build the payload with an ESCAPED \$ so the value is a
#    literal string (variable-expansion never re-triggers command substitution) and feed it through.
rm -f "$WORK/pwned"
inj="image/png\$(touch $WORK/pwned)" # literal: image/png$(touch /tmp/…/pwned)
out="$(reader "$inj" || true)"
[ ! -e "$WORK/pwned" ] || fail "request string was evaluated as a command (injection!)"
[ -z "$out" ] || fail "a non-allowlisted request produced output: [$out]"
ok "crafted request strings are inert (no widening, no injection)"

# ---- guest shim (guest/default.nix): its request-mapping must refuse non-image targets --------
grep -q 'image/png|image/bmp|image/jpeg|image/gif|image/webp) req=' "$GUEST_SRC" ||
  fail "guest xclip shim no longer maps image targets to a request"
# The shim's catch-all for any other target (text/plain, etc.) must be a hard refusal (exit 1),
# so it never even contacts the host for text.
grep -q '\*) exit 1 ;;.*# text/plain' "$GUEST_SRC" ||
  grep -qE '\*\) exit 1' "$GUEST_SRC" ||
  fail "guest xclip shim lost its non-image refusal (text could reach the bridge)"
ok "guest shim refuses non-image targets (text never even requested)"

printf 'clipboard: %d checks passed\n' "$pass"
