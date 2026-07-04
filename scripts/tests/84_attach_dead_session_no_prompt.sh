#!/usr/bin/env bash
# Test 84 — `tmx attach -t NAME` on a DEAD session (no live tmux server)
# whose name has a PERSISTED password must NOT prompt at all.
#
# Purpose:    Root-cause half 1 of the §3 double-password-prompt bug
#             (forensic anchor 2026-07-05): the attach verb used to check
#             the PERSISTED password state before checking whether a live
#             tmux session existed, so a recycled (dead) session with a
#             persisted password still triggered a verify prompt that
#             could never succeed in actually attaching. This test
#             reproduces the "dead name with a persisted password" state
#             directly (create → set password → tear down the tmux server
#             WITHOUT clearing state, mirroring what tmx-recycler.sh does)
#             and asserts `tmx attach -t NAME` prints a clean error with
#             NO password prompt.
# Usage:      bash scripts/tests/84_attach_dead_session_no_prompt.sh
# Inputs:     TMUX_BIN (optional override).
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / 2 FAIL.
# Side-effects: private HOME/TMUX_TMPDIR/TMX_STATE_FILE sandbox, trap-cleaned.
# Dependencies: built tmux binary, scripts/tmx wrapper, scripts/tmx-state-bin.
# Cross-refs: scripts/tmx.template (attach verb); §3 forensic anchor
#             2026-07-05; test 68 (pty_harness.sh consumer).
# Last verified: 2026-07-05 (authored; live run pending build).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-linux/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 84: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 84: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 84: $*"; SKIP=$((SKIP+1)); }

echo "── Test 84: attach on dead session with persisted password → no prompt ──"

if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built at $TMUX_BIN"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ];  then _skip "scripts/tmx wrapper not generated (run setup.sh)"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$STATE_BIN" ]; then _skip "scripts/tmx-state-bin not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

SCRATCH="${TMPDIR:-/tmp}/tmx84.$$"
mkdir -p "$SCRATCH/home" || { echo "SKIP 84: cannot create scratch"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }
STATE_FILE="$SCRATCH/state.json"
export TMX_STATE_FILE="$STATE_FILE"
export TMUX_TMPDIR="$SCRATCH"
export HOME="$SCRATCH/home"

NAME="t84_$$"
SOCK="tmx-$NAME"

_cleanup() {
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    "$STATE_BIN" forget "$NAME" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

# Persist a password for NAME directly (no live session needed for this —
# mirrors the STATE that survives a tmx-recycler.sh teardown, which kills
# the tmux server + scope but does NOT clear tmx-state).
if ! "$STATE_BIN" set-password "$NAME" "s3cret" >/dev/null 2>&1; then
    _fail "could not persist a password for $NAME"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
if ! "$STATE_BIN" has-password "$NAME" >/dev/null 2>&1; then
    _fail "has-password does not confirm the persisted password (setup broken)"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
echo "[evidence] persisted password confirmed via has-password (exit 0), no live tmux session exists for $NAME"

# `tmx attach -t NAME` — NAME has a persisted password but there is
# genuinely NO live tmux server on $SOCK. Run non-interactively (input
# from /dev/null) so if the wrapper WERE to prompt, `read` would hit EOF
# immediately rather than hanging the test — but the whole point is that
# NO /dev/tty interaction should be attempted at all in this case.
_out="$("$WRAPPER" attach -t "$NAME" 2>&1 </dev/null)"
_rc=$?

if [ "$_rc" -eq 0 ]; then
    _fail "attach on a dead session unexpectedly exited 0 (rc=$_rc, out=$_out)"
elif printf '%s' "$_out" | grep -qi "password"; then
    _fail "attach on a dead session mentioned 'password' at all — should be silent on this path (out=$_out)"
elif printf '%s' "$_out" | grep -qi "no session named"; then
    _pass "attach on dead session printed a clean 'no session named' error, exit=$_rc, no password mention"
else
    _fail "attach on dead session gave unexpected output: rc=$_rc out=$_out"
fi

echo "── Test 84 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
