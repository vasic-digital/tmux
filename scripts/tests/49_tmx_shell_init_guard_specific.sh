#!/usr/bin/env bash
# Test 49 — tmx-shell-init non-TTY guard SPECIFIC layer-4 isolation.
#
# §103 / §11.4.1 / §11.4.4 FORENSIC ANCHOR:
#   Paired meta-test mutation P5-M20 strips the `[ -t 0 ] || [ ! -t 1 ]`
#   non-TTY guard from `scripts/tmx-shell-init.sh.template`. Existing test
#   30 ("non-TTY skip") asserts NEGATIVE properties (no prompt string,
#   fast exit). On Darwin POSIX libc returns 0 from `read -r ... < /dev/null`
#   with EOF — so even the GUARDED and the UNGUARDED runs both exit fast
#   and emit nothing on stdout. Test 30 cannot distinguish them → P5-M20
#   escapes test 30.
#
#   This test closes the escape. The template's guard branch is
#   instrumented with a single-line distinctive marker (only emitted when
#   TMX_INIT_DEBUG=1 is set, so end users never see it). Test 49 sets
#   TMX_INIT_DEBUG=1 and asserts the marker is in stderr. P5-M20 strips
#   the WHOLE guard block (including the marker line) → no marker on
#   stderr → test 49 FAILs.
#
# §11.4.2 captured evidence: stderr content + marker presence.
# §11.4.50 reliability: 3 iterations, identical evidence hash.
# §11.4.81 cross-platform: marker semantics identical on Linux + Darwin.
# §11.4.14 cleanup: trap removes the generated copy + any test session.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
GENERATED="$REPO_ROOT/scripts/tmx-shell-init.sh"
# §11.4.3 / D2 TMPDIR-HARDCODE-001 — route scratch through $TMPDIR so a full
# host `/` cannot false-FAIL this test. Preflight below.
SCRATCH="${TMPDIR:-/tmp}"
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 49: scratch root $SCRATCH not writable — §11.4.3"
    exit 77
fi
rmdir "$_wtest" 2>/dev/null || true
INIT_FILE="$SCRATCH/tmx-test-49-init-$$.sh"
PREFIX="tmx-test-49"
export TMX_STATE_FILE="$SCRATCH/tmx-test-49-state-$$.json"
MARKER_REGEX='tmx-shell-init: non-TTY guard fired'

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 49: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 49: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 49: $*"; SKIP=$((SKIP + 1)); }

_cleanup() {
    rm -f "$INIT_FILE" "$TMX_STATE_FILE" 2>/dev/null || true
}
trap _cleanup EXIT

echo "── Test 49: tmx-shell-init non-TTY guard SPECIFIC layer-4 isolation ──"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 49: unsupported platform $HOST_OS"; exit 77 ;;
esac

# ── T0: template + generated script present ───────────────────────────
if [ ! -f "$TEMPLATE" ]; then
    _fail "T0 template missing ($TEMPLATE)"
    echo "── summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi
_pass "T0 template present at $TEMPLATE"

# ── T1: STRUCTURAL — template carries the `[ -t 0 ]` guard with the
#     distinctive marker. Strip the guard block and the marker goes
#     with it.
if ! grep -qE 'if \[ ! -t 0 \] \|\| \[ ! -t 1 \]; then' "$TEMPLATE"; then
    _fail "T1 template missing the non-TTY guard structure"
elif ! grep -qF "$MARKER_REGEX" "$TEMPLATE"; then
    _fail "T1 template missing distinctive marker '$MARKER_REGEX' (P5-M20 escape vector)"
else
    _pass "T1 template guard + marker present"
fi

# Render the template the same way setup.sh does, so the test exercises
# the SAME bytes the end user runs on `source ~/.bashrc`. Independent of
# whether setup.sh has been run recently in this checkout.
sed \
    -e "s|__PROJECT__|$REPO_ROOT|g" \
    -e "s|__DATE__|test-49|" \
    "$TEMPLATE" > "$INIT_FILE"
chmod 644 "$INIT_FILE"

# ── T2: RUNTIME — invoke with stdin=/dev/null + TMX_INIT_DEBUG=1, capture
#     stderr, assert distinctive marker present. The marker fires ONLY
#     inside the guard branch — its presence proves the guard executed.
#     P5-M20 stripping the guard → marker absent → this assertion FAILs.
run_iteration() {
    local iter="$1"
    local stderr_file
    stderr_file="$SCRATCH/tmx-test-49-stderr-$$-$iter.txt"
    local rc=0
    # Drop TMUX so the "already inside tmux" early-return doesn't intercept.
    # Run with stdin=/dev/null (definitively non-TTY) + the debug env var.
    TMX_INIT_DEBUG=1 TMUX= timeout 5 bash -c \
        "exec </dev/null; bash \"$INIT_FILE\"" \
        >/dev/null 2>"$stderr_file" || rc=$?
    if [ "$rc" -eq 124 ]; then
        _fail "T2 iter=$iter: 5s timeout fired — guard missing/broken"
        rm -f "$stderr_file"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        _fail "T2 iter=$iter: init returned rc=$rc on non-TTY stdin"
        cat "$stderr_file" >&2 || true
        rm -f "$stderr_file"
        return 1
    fi
    if ! grep -qF "$MARKER_REGEX" "$stderr_file"; then
        _fail "T2 iter=$iter: distinctive marker absent from stderr (guard branch did NOT fire — P5-M20-class regression)"
        echo "  stderr was:" >&2
        cat "$stderr_file" >&2 || true
        rm -f "$stderr_file"
        return 1
    fi
    # Echo iteration evidence inline so summary log captures the proof.
    local marker_line
    marker_line="$(grep -F "$MARKER_REGEX" "$stderr_file" | head -1)"
    echo "[evidence 49] iter=$iter rc=0 marker=\"$marker_line\""
    rm -f "$stderr_file"
    return 0
}

# ── T3: §11.4.50 deterministic-consistency — 3 iterations, identical
#     evidence hash. All-or-nothing: any divergence = FAIL.
_hashes=()
_iter_failed=0
for i in 1 2 3; do
    if ! run_iteration "$i"; then _iter_failed=1; break; fi
    _h="$(printf '%s' "marker_present=yes guard=fired" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
done

if [ "$_iter_failed" -eq 1 ]; then
    echo "── summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi

if [ "${_hashes[0]}" = "${_hashes[1]}" ] && [ "${_hashes[1]}" = "${_hashes[2]}" ]; then
    _pass "T2 + T3 marker fired on 3/3 iterations (identical evidence) on $HOST_OS"
else
    _fail "T3 §11.4.50 divergent hashes: ${_hashes[*]}"
fi

echo "── summary 49: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
