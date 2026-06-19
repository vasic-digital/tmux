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

# T2: the raw spec `home:red` reaches the tmx wrapper (the shell-init is a thin
# input layer; the wrapper's _parse_session_value parses name vs color). With
# the fake tmx exiting 1 on attach, BOTH `attach -t home:red` AND
# `new -s home:red` should appear in the capture.
rm -f "$CAPTURE"; drive 'home:red' >/dev/null 2>&1
if grep -q 'home:red' "$CAPTURE" 2>/dev/null; then
    _pass "T2 spec 'home:red' reaches wrapper (capture: $(cat "$CAPTURE"))"
else
    _fail "T2 spec 'home:red' NOT in capture; capture=$(cat "$CAPTURE" 2>/dev/null)"
fi

# T3: the COLOR survives into the tmx `new -s` invocation (the shell-init
# does NOT strip the color suffix — the wrapper's _parse_session_value will
# parse it). With the fake tmx exiting 1 on attach, the fallback
# `exec tmx new -s home:red` fires.
rm -f "$CAPTURE"; drive 'home:red' >/dev/null 2>&1
if grep -q 'new -s home:red' "$CAPTURE" 2>/dev/null; then
    _pass "T3 color preserved: 'new -s home:red' captured"
else
    # Acceptable variant: attach path is sufficient if new path never fires
    # (unlikely with our fake tmx, but defensive).
    if grep -q 'new -s' "$CAPTURE" 2>/dev/null && grep -qv 'home:red' "$CAPTURE"; then
        _fail "T3 color stripped: 'new -s' found but without ':red' suffix (capture=$(cat "$CAPTURE" 2>/dev/null))"
    elif grep -q 'attach -t home:red' "$CAPTURE" 2>/dev/null; then
        _pass "T3 color preserved in attach path: 'attach -t home:red'"
    else
        _fail "T3 no recognizable invocation; capture=$(cat "$CAPTURE" 2>/dev/null)"
    fi
fi

# T4: a genuinely-BAD name (space) is STILL rejected (the fix must not weaken
# the existing security validation — §11.4.120 reconciliation discipline).
out=$(drive 'bad name'); rc=$?
if echo "$out" | grep -q 'invalid session name' && [ "$rc" -ne 0 ]; then
    _pass "T4 'bad name' still rejected (charset validation intact)"
else
    _fail "T4 'bad name' NOT rejected — fix weakened existing validation (out=$out rc=$rc)"
fi

# T5: invalid color token rejected at the prompt (defence in depth — wrapper
# also rejects, but the prompt should not let an obviously-invalid color through).
out=$(drive 'home:notacolor!'); rc=$?
if echo "$out" | grep -qi 'invalid.*color\|invalid session name' && [ "$rc" -ne 0 ]; then
    _pass "T5 invalid color 'notacolor!' rejected by prompt"
else
    # acceptable variant: if the prompt forwards as-is and lets the wrapper reject,
    # that's also OK — but then capture must carry it and wrapper owns rejection.
    _fail "T5 invalid color not rejected by prompt (out=$out rc=$rc)"
fi

# T6: #hex color accepted at the prompt.
rm -f "$CAPTURE"; out=$(drive 'work:#3b82f6'); rc=$?
if [ -s "$CAPTURE" ] && ! echo "$out" | grep -q 'invalid'; then
    _pass "T6 '#hex' color accepted (capture: $(cat "$CAPTURE"))"
else
    _fail "T6 '#hex' rejected/lost (out=$out)"
fi

echo "── Test 65 result: PASS=$PASS FAIL=$FAIL ──"
[ "$FAIL" -eq 0 ]
