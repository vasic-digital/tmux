#!/usr/bin/env bash
# Test 80 — creating a genuinely NEW password-protected session prompts
# TWICE (password + confirmation); mismatched confirmation retries up to
# 3 times then aborts cleanly with no session left behind.
#
# Purpose:    §3 mandate (2026-07-05): "We MUST BE asked twice to enter
#             password if we create new session password protected - the
#             password and confirmation." PTY-driven against a genuinely
#             fresh session name (no prior tmx-state record).
# Usage:      bash scripts/tests/80_new_password_confirm_flow.sh
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / 2 FAIL.
# Side-effects: private HOME/TMUX_TMPDIR/TMX_STATE_FILE sandbox, trap-cleaned;
#             only its own uniquely-named sessions are touched.
# Dependencies: built tmux binary, scripts/tmx wrapper, scripts/tmx-state-bin,
#             python3, lib/pty_harness.sh, lib/interactive_pty_probe.sh.
# Cross-refs: scripts/tmx.template (new verb); test 68 (harness consumer);
#             §3 forensic anchor 2026-07-05.
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
_pass() { echo "PASS 80: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 80: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 80: $*"; SKIP=$((SKIP+1)); }

echo "── Test 80: new-session password create+confirm flow ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 80: unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

. "$SELF_DIR/lib/interactive_pty_probe.sh"
if ! ipty_interactive_terminal_ok "$TMUX_BIN"; then
    _skip "headless: no functional interactive terminal — §11.4.3"
    echo "── Test 80 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 0
fi

SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
if [ "$(( ${#SCRATCH_REAL} + 60 ))" -gt 100 ]; then SCRATCH="/tmp/tmx80.$$"; else SCRATCH="$SCRATCH_REAL/tmx80.$$"; fi
mkdir -p "$SCRATCH/home" || { echo "SKIP 80: cannot create scratch"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

HARNESS="$SELF_DIR/lib/pty_harness.sh"
[ -f "$HARNESS" ] || { echo "SKIP 80: PTY harness missing"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }
# shellcheck disable=SC1090
. "$HARNESS"

if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ];  then _skip "scripts/tmx wrapper not generated"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$STATE_BIN" ]; then _skip "scripts/tmx-state-bin not built"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if ! pth_have_python; then _skip "python3 absent"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

HOME_DIR="$SCRATCH/home"
STATE_FILE="$SCRATCH/state.json"
export TMX_STATE_FILE="$STATE_FILE"
export TMUX_TMPDIR="$SCRATCH"
export PTH_TMUX="$TMUX_BIN"
export PTH_SOCK="tmx80drv-$$"
export PTH_TMPDIR="$SCRATCH"

_envpfx() { printf 'HOME=%s TMUX_TMPDIR=%s TMX_STATE_FILE=%s' "$HOME_DIR" "$SCRATCH" "$STATE_FILE"; }
_wrap_in_pane() { _ds="$1"; shift; pth_run_pane "$_ds" "$(_envpfx) '$WRAPPER' $*"; }

NAMES=""
_cleanup() {
    pth_driver_kill
    for _n in $NAMES; do
        "$WRAPPER" delete -t "$_n" >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "tmx-$_n" kill-server >/dev/null 2>&1 || true
    done
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Scenario A: matching password+confirmation succeeds ──────────────
NAME_A="t80a_$$"; NAMES="$NAMES $NAME_A"; SOCK_A="tmx-$NAME_A"
if ! _wrap_in_pane "drv_${NAME_A}" new -s "$NAME_A"; then
    _fail "A: could not start create driver pane"
elif ! pth_wait_text "drv_${NAME_A}" "Enter password for session" 12; then
    _fail "A: initial password prompt never appeared"
    pth_kill_pane "drv_${NAME_A}"
else
    pth_send "drv_${NAME_A}" "matchpw123"; pth_send_enter "drv_${NAME_A}"
    if pth_wait_text "drv_${NAME_A}" "Confirm password" 8; then
        echo "[evidence A] second 'Confirm password' prompt appeared after the first entry"
        pth_send "drv_${NAME_A}" "matchpw123"; pth_send_enter "drv_${NAME_A}"
        if pth_wait_attached "$TMUX_BIN" "$SOCK_A" "$NAME_A" "1" 12; then
            _pass "A: matching password+confirmation → session created and attached"
            if "$STATE_BIN" verify-password "$NAME_A" "matchpw123" >/dev/null 2>&1; then
                _pass "A: password persisted correctly (verify-password accepts it)"
            else
                _fail "A: password not persisted correctly after matching confirm"
            fi
        else
            _fail "A: session did not attach after matching confirmation"
        fi
    else
        _fail "A: no 'Confirm password' second prompt appeared — double-prompt requirement not met"
    fi
    CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK_A" "$NAME_A")"
    [ -n "$CPID" ] && pth_kill_hup "$CPID"
    pth_kill_pane "drv_${NAME_A}"
fi

# ── Scenario B: mismatched confirmation retries, 3rd mismatch aborts,
#    no session left behind ────────────────────────────────────────────
NAME_B="t80b_$$"; NAMES="$NAMES $NAME_B"; SOCK_B="tmx-$NAME_B"
if ! _wrap_in_pane "drv_${NAME_B}" new -s "$NAME_B"; then
    _fail "B: could not start create driver pane"
else
    # §11.4.1 harness observation fix (NOT a product change): after the 3rd
    # mismatch the wrapper prints "session not created" and exits IMMEDIATELY.
    # With tmux's default remain-on-exit=off, the driver pane is torn down
    # before a capture-pane poll tick can observe that final line — a
    # test-observation race, not a product defect. Keeping the dead pane's
    # final screen makes the (correct) abort message reliably capturable; the
    # fail-closed behaviour itself is separately asserted below and holds.
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        set-option -g remain-on-exit on >/dev/null 2>&1 || true
    _mismatch_ok=1
    for _try in 1 2 3; do
        if ! pth_wait_text "drv_${NAME_B}" "Enter password for session" 12; then
            _fail "B: attempt $_try: initial password prompt never appeared"
            _mismatch_ok=0; break
        fi
        pth_send "drv_${NAME_B}" "firstpw$_try"; pth_send_enter "drv_${NAME_B}"
        if ! pth_wait_text "drv_${NAME_B}" "Confirm password" 8; then
            _fail "B: attempt $_try: no confirm prompt appeared"
            _mismatch_ok=0; break
        fi
        pth_send "drv_${NAME_B}" "SECONDPW$_try"; pth_send_enter "drv_${NAME_B}"
        if [ "$_try" -lt 3 ]; then
            if ! pth_wait_text "drv_${NAME_B}" "did not match" 8; then
                _fail "B: attempt $_try: no mismatch retry message appeared"
                _mismatch_ok=0; break
            fi
            echo "[evidence B attempt=$_try] mismatch message shown, retrying"
        fi
    done
    if [ "$_mismatch_ok" -eq 1 ]; then
        # After the 3rd mismatch, expect an abort message and the driver
        # pane to exit (no session left behind).
        if pth_wait_text "drv_${NAME_B}" "not created" 10; then
            _pass "B: 3rd mismatch aborted with an explicit 'not created' message"
        else
            _fail "B: no abort message seen after 3rd mismatch"
        fi
        sleep 1
        if "$TMUX_BIN" -L "$SOCK_B" has-session -t "$NAME_B" 2>/dev/null; then
            _fail "B: a session was left behind after 3x password mismatch (fail-closed violated)"
        else
            _pass "B: no session left behind after 3x password mismatch (fail-closed honored)"
        fi
        "$STATE_BIN" has-password "$NAME_B" >/dev/null 2>&1
        if [ "$?" -eq 0 ]; then
            _fail "B: a password was somehow persisted despite the abort"
        else
            _pass "B: no password persisted after the abort"
        fi
    fi
    pth_kill_pane "drv_${NAME_B}"
fi

echo "── Test 80 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
