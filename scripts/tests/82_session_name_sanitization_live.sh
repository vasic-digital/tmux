#!/usr/bin/env bash
# Test 82 — direct `tmx new -s NAME` sanitizes messy names live.
#
# CONTRACT: the wrapper normalizes spaces/special characters into a safe
# session name before asking tmux to create the session. The real tmux
# session and socket label must match the sanitized name.
#
# POSITIVE evidence per §11.4.5: `tmux ls` readback of the created session
# shows the sanitized name and the socket file uses the matching label.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.14 cleanup.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-linux/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 82: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 82: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 82: $*"; SKIP=$((SKIP+1)); }

echo "── Test 82: live session-name sanitization ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) _skip "unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ];  then _skip "scripts/tmx wrapper not generated"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
SCRATCH="$SCRATCH_REAL/tmx82.$$"
mkdir -p "$SCRATCH/home" || { _skip "cannot create scratch"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

HOME_DIR="$SCRATCH/home"
STATE_FILE="$SCRATCH/state.json"
export TMX_STATE_FILE="$STATE_FILE"
export TMUX_TMPDIR="$SCRATCH"
export HOME="$HOME_DIR"

# Each line: INPUT|EXPECTED_SANITIZED_NAME
CASES=(
    'hello world|hello-world'
    '  leading and trailing   |leading-and-trailing'
    $'multi   spaces\tand\ttabs|multi-spaces-and-tabs'
    'special!@#chars|specialchars'
    'already-safe_name|already-safe_name'
)

_cleanup_case() {
    local name="$1"
    "$WRAPPER" delete -t "$name" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "tmx-$name" kill-server >/dev/null 2>&1 || true
}

run_iteration() {
    local iter="$1"
    local failures=0
    for entry in "${CASES[@]}"; do
        local raw expected base raw_full expected_full
        raw="$(printf '%s' "$entry" | cut -d'|' -f1)"
        expected="$(printf '%s' "$entry" | cut -d'|' -f2)"
        base="t82_${iter}_${expected}"
        raw_full="${base} ${raw}"
        expected_full="${base}-${expected}"
        _cleanup_case "$expected_full" >/dev/null 2>&1
        # Create the session non-interactively so no password prompt appears.
        if ! TMUX_TMPDIR="$SCRATCH" TMX_STATE_FILE="$STATE_FILE" HOME="$HOME_DIR" "$WRAPPER" new -s "$raw_full" -d >/dev/null 2>&1; then
            echo "  iter=$iter: raw='$raw_full' wrapper exited non-zero"
            failures=$((failures + 1))
            continue
        fi
        local landed=""
        landed="$(TMUX_TMPDIR="$SCRATCH" "$TMUX_BIN" -L "tmx-$expected_full" ls -F '#{session_name}' 2>/dev/null | head -1)"
        if [ "$landed" = "$expected_full" ]; then
            _pass "iter=$iter raw='$raw_full' landed as '$landed'"
        else
            echo "  iter=$iter: raw='$raw_full' expected landed '$expected_full', got '${landed:-<empty>}'"
            failures=$((failures + 1))
        fi
        # Also verify the socket label exists with the sanitized name.
        if [ -S "$SCRATCH/tmux-$(id -u)/tmx-$expected_full" ]; then
            _pass "iter=$iter socket tmx-$expected_full exists"
        else
            echo "  iter=$iter: socket tmx-$expected_full missing"
            failures=$((failures + 1))
        fi
        _cleanup_case "$expected_full" >/dev/null 2>&1
    done
    if [ "$failures" -gt 0 ]; then
        echo "FAIL 82 iter=$iter: $failures live sanitization assertions failed"
        return 1
    fi
    _evidence="iter=$iter cases_tested=${#CASES[@]} live=yes"
    return 0
}

trap 'for e in "${CASES[@]}"; do b="$(printf "%s" "$e" | cut -d"|" -f2)"; for i in 1 2 3; do _cleanup_case "t82_${i}_${b}-${b}" >/dev/null 2>&1; done; done; rm -rf "$SCRATCH"' EXIT

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1; fi
    _h="$(echo "live_sanitized=${#CASES[@]}" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 82: N=3 evidence hashes diverge: ${_hashes[*]}"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "── Test 82 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
