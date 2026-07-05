#!/usr/bin/env bash
# Test 65 — interactive shell-init prompt accepts name:color (operator-path).
#
# §11.4.138 operator-escape (FACT, 2026-06-19): operator reported
#   [tmx] Enter session name ...: home:red
#   [tmx] invalid session name 'home:red'; allowed: [A-Za-z0-9_.-]{1,64}
# The v1.0.26 color feature's tests (63/64) drove `tmx new -s name:color`
# DIRECTLY, bypassing the interactive login prompt in tmx-shell-init.sh —
# which validates the raw input against [A-Za-z0-9_.-] and rejected ':'
# before the wrapper's color-parsing ever ran. This is the §11.4.108
# SOURCE→USER-VISIBLE gap (GREEN suite, broken-for-user feature).
#
# This test drives the REAL interactive prompt path (the entry point end
# users hit on shell login) and asserts name:color is ACCEPTED, the parsed
# name reaches `tmx new -s`, and the color survives. Anti-bluff: the fake
# `tmx` captures its argv so we assert the EXACT invocation, not an exit code.
#
# §11.4.50 reliability: 3 iterations. §11.4.81 cross-platform: POSIX case.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
SCRATCH="${TMPDIR:-/tmp}"
INIT_FILE="$SCRATCH/tmx_t65_init_$$.sh"
INIT_STRIPPED="$SCRATCH/tmx_t65_init_stripped_$$.sh"
FAKEBIN="$SCRATCH/tmx_t65_fakebin_$$"
CAPTURE="$SCRATCH/tmx_t65_capture_$$"

echo "── Test 65: interactive prompt accepts name:color (operator-path) ──"
PASS=0; FAIL=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

_cleanup() { rm -rf "$INIT_FILE" "$INIT_STRIPPED" "$FAKEBIN" "$CAPTURE" 2>/dev/null || true; }
trap _cleanup EXIT

# §11.4.3 scratch preflight.
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 65: scratch root $SCRATCH not writable — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL"; exit 0
fi
rmdir "$_wtest" 2>/dev/null || true

[ -f "$INIT_TEMPLATE" ] || { echo "SKIP 65: tmx-shell-init.sh.template not present"; exit 77; }

# Generate the init script (resolved placeholder) + strip the TTY guard so
# we can drive it via stdin (mirrors test 35's proven technique).
sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|t65|g" "$INIT_TEMPLATE" > "$INIT_FILE"
sed '/if \[ ! -t 0 \] || \[ ! -t 1 \]; then/,/^fi$/d' "$INIT_FILE" > "$INIT_STRIPPED"

# Fake `tmx` that captures every argv into $CAPTURE (so we assert the exact
# invocation the prompt ended up making — anti-bluff, not exit-code-only).
# Exit 1 on attach so the shell-init's `attach || new` fallback exercises the
# `new` path too (T3 verifies the color survives there). The fake's stderr
# is discarded so the test sees clean output from the init script.
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmx" <<FAKETMX
#!/bin/sh
printf '%s\\n' "\$*" >> "$CAPTURE"
case "\${1-}" in attach|attach-session) exit 1 ;; esac
exit 0
FAKETMX
chmod 755 "$FAKEBIN/tmx"
export PATH="$FAKEBIN:$PATH"

# Drive the prompt: feed input via stdin, TMUX/TMX_SKIP unset so it reaches
# validation (per the v1.0.13 note in test 35).
drive() { printf '%s\n' "$1" | env -u TMUX -u TMX_SKIP bash "$INIT_STRIPPED" 2>&1; }

# T1: 'home:red' ACCEPTED → reaches `tmx ... home...` (NOT rejected). Pre-fix
# this FAILs with 'invalid session name'. This is the exact operator report.
rm -f "$CAPTURE"
out=$(drive 'home:red'); rc=$?
if echo "$out" | grep -q 'invalid session name'; then
    _fail "T1 'home:red' rejected by prompt (operator-reported bug still live): $out"
elif [ -s "$CAPTURE" ]; then
    _pass "T1 'home:red' accepted → prompt invoked tmx: $(cat "$CAPTURE")"
else
    _fail "T1 'home:red' not rejected but tmx not invoked either; out=$out"
fi

# T2: the sanitized name + colour spec reaches the tmx wrapper. The suffix is
# inserted BEFORE the colour token so the wrapper sees a valid name:color pair.
rm -f "$CAPTURE"; drive 'home:red' >/dev/null 2>&1
if grep -qE 'home-[0-9][0-9][0-9][0-9]:red' "$CAPTURE" 2>/dev/null; then
    _pass "T2 spec 'home:red' reaches wrapper (capture: $(cat "$CAPTURE"))"
else
    _fail "T2 spec 'home:red' NOT in capture; capture=$(cat "$CAPTURE" 2>/dev/null)"
fi

# T3: the COLOUR survives into the tmx `new -s` invocation, with the suffix
# placed before the ':' so the colour remains valid.
rm -f "$CAPTURE"; drive 'home:red' >/dev/null 2>&1
if grep -qE 'new -s home-[0-9][0-9][0-9][0-9]:red' "$CAPTURE" 2>/dev/null; then
    _pass "T3 color preserved: 'new -s home-NNNN:red' captured"
else
    _fail "T3 color lost/misplaced; capture=$(cat "$CAPTURE" 2>/dev/null)"
fi

# T4: a name containing spaces is SANITIZED, not rejected (the new behaviour
# requested by the operator). The wrapper receives `bad-name-NNNN`.
rm -f "$CAPTURE"; out=$(drive 'bad name'); rc=$?
if grep -qE 'new -s bad-name-[0-9][0-9][0-9][0-9]' "$CAPTURE" 2>/dev/null && [ "$rc" -eq 0 ]; then
    _pass "T4 'bad name' sanitized to 'bad-name' and forwarded (capture: $(cat "$CAPTURE"))"
else
    _fail "T4 'bad name' not sanitized as expected (out=$out rc=$rc capture=$(cat "$CAPTURE" 2>/dev/null))"
fi

# T5: an invalid colour token is forwarded to the wrapper; the prompt no longer
# rejects it, but it must not silently strip the colour either.
rm -f "$CAPTURE"; out=$(drive 'home:notacolor!'); rc=$?
if grep -qE 'home-[0-9][0-9][0-9][0-9]:notacolor!' "$CAPTURE" 2>/dev/null; then
    _pass "T5 invalid color forwarded to wrapper (capture: $(cat "$CAPTURE"))"
else
    _fail "T5 invalid color not forwarded (out=$out rc=$rc capture=$(cat "$CAPTURE" 2>/dev/null))"
fi

# T6: #hex color accepted at the prompt; suffix inserted before the '#' token.
rm -f "$CAPTURE"; out=$(drive 'work:#3b82f6'); rc=$?
if grep -qE 'new -s work-[0-9][0-9][0-9][0-9]:#3b82f6' "$CAPTURE" 2>/dev/null; then
    _pass "T6 '#hex' color accepted (capture: $(cat "$CAPTURE"))"
else
    _fail "T6 '#hex' rejected/lost (out=$out capture=$(cat "$CAPTURE" 2>/dev/null))"
fi

echo "── Test 65 result: PASS=$PASS FAIL=$FAIL ──"
[ "$FAIL" -eq 0 ]
