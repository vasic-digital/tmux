#!/usr/bin/env bash
# Test 77 — password input is masked with '*', never shown in plaintext.
#
# Purpose:    §2 mandate (2026-07-05): passwords MUST NOT be visible to a
#             naked eye while typing — presented with '*' characters
#             instead. PTY-driven: types a password character-by-character
#             into a real tmux pane running the wrapper, and asserts the
#             pane's VISIBLE buffer shows only '*' characters for the typed
#             password, never the plaintext, and that backspace erases one
#             '*'.
# Usage:      bash scripts/tests/77_password_masked_echo.sh
# Inputs:     TMUX_BIN (optional override).
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / 2 FAIL.
# Side-effects: creates/kills ONLY its own private driver + inner sessions
#             on private sockets under a private HOME/TMUX_TMPDIR/
#             TMX_STATE_FILE. trap-cleaned on every exit path.
# Dependencies: a built tmux binary, scripts/tmx wrapper, scripts/tmx-state-bin,
#             python3 (kill-HUP not needed here, but pth_have_python gates
#             the harness's other prerequisites consistently).
# Cross-refs: scripts/tmx.template (_read_password_masked); test 68 (uses
#             the same lib/pty_harness.sh); §2 forensic anchor 2026-07-05.
# Last verified: 2026-07-05 (authored; live run pending build).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# §11.4.3/§11.4.50: keep the pane free of wrapper diagnostics driven by the
# operator's ambient knobs. With TMX_SERVER_SPLIT=1 exported, the wrapper
# prints "...TMX_CPU='' is not splittable..." into this very pane, and the
# plaintext assertions below then match the needle inside "splitt-AB-le"
# (a §11.4.201(7)(a) carrier) -> a §11.4.1 FAIL-bluff on healthy masking.
. "$SELF_DIR/lib/hermetic_env.sh"
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
_pass() { echo "PASS 77: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 77: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 77: $*"; SKIP=$((SKIP+1)); }

echo "── Test 77: password input masked with '*' ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 77: unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

. "$SELF_DIR/lib/interactive_pty_probe.sh"
if ! ipty_interactive_terminal_ok "$TMUX_BIN"; then
    _skip "headless: no functional interactive terminal — §11.4.3"
    echo "── Test 77 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 0
fi

SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
if [ "$(( ${#SCRATCH_REAL} + 60 ))" -gt 100 ]; then
    SCRATCH="/tmp/tmx77.$$"
else
    SCRATCH="$SCRATCH_REAL/tmx77.$$"
fi
mkdir -p "$SCRATCH" || { echo "SKIP 77: cannot create scratch $SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

HARNESS="$SELF_DIR/lib/pty_harness.sh"
if [ ! -f "$HARNESS" ]; then
    echo "SKIP 77: PTY harness missing — §11.4.3"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
# shellcheck disable=SC1090
. "$HARNESS"

if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built at $TMUX_BIN"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ];  then _skip "scripts/tmx wrapper not generated (run setup.sh)"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$STATE_BIN" ]; then _skip "scripts/tmx-state-bin not built"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR"
STATE_FILE="$SCRATCH/state.json"
export TMX_STATE_FILE="$STATE_FILE"
export TMUX_TMPDIR="$SCRATCH"
export PTH_TMUX="$TMUX_BIN"
export PTH_SOCK="tmx77drv-$$"
export PTH_TMPDIR="$SCRATCH"

NAME="t77_$$"
SOCK="tmx-$NAME"

_cleanup() {
    pth_driver_kill
    "$WRAPPER" delete -t "$NAME" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

_envpfx() { printf 'HOME=%s TMUX_TMPDIR=%s TMX_STATE_FILE=%s' "$HOME_DIR" "$SCRATCH" "$STATE_FILE"; }
_wrap_in_pane() { _ds="$1"; shift; pth_run_pane "$_ds" "$(_envpfx) '$WRAPPER' $*"; }

# Create the session (interactive, foreground) so we hit the create-time
# password prompt.
if ! _wrap_in_pane "drv_${NAME}" new -s "$NAME"; then
    _fail "could not start create driver pane"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
if ! pth_wait_text "drv_${NAME}" "Enter password for session" 12; then
    _fail "create-time password prompt never appeared"
    pth_kill_pane "drv_${NAME}"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi

# Type "ab" then backspace then "c" — expect the visible pane to show
# exactly "**" after "ab" is typed, then one '*' erased, then "**" again
# after the backspace+"c" (never the literal a/b/c characters).
pth_send "drv_${NAME}" "ab"
sleep 0.3
_buf1="$(pth_capture "drv_${NAME}")"
# §11.4.201(7)(a) — match STRUCTURE, not a bare substring over the whole
# screen. The leak sentinel "ab" is only meaningful ON THE PROMPT LINE: that
# is where the wrapper echoes what the operator typed. Scanning the entire
# pane makes ANY unrelated text that merely CONTAINS "ab" a false leak — e.g.
# the wrapper's own "...TMX_CPU='' is not splittable..." diagnostic, whose
# "splitt-AB-le" FAILed this test on provably-correct masking (2026-08-12).
# An absent/empty prompt line fails safe: the star count below is then 0.
_prompt_line1="$(printf '%s\n' "$_buf1" | grep "Enter password for session")"
if printf '%s' "$_prompt_line1" | grep -qF "ab"; then
    _fail "plaintext 'ab' visible on the password prompt line — masking not applied: $_prompt_line1"
else
    # capture-pane -p is a live screen SNAPSHOT (one line per row, not an
    # accumulating log), so the prompt line's star count is exact at this
    # instant — count EXACTLY 2, not merely "contains **" (which would also
    # accept a stray-extra-star echo bug for 2 typed chars).
    _star_count1=$(printf '%s' "$_prompt_line1" | tr -dc '*' | wc -c)
    if [ "$_star_count1" -eq 2 ]; then
        _pass "exactly two '*' characters shown after typing 2 chars, no plaintext"
    else
        _fail "expected exactly 2 '*' characters after typing 'ab', got $_star_count1; line: $_prompt_line1"
    fi
fi

# Backspace (0x7f) then 'c'. Correct masking hides the retyped 'c' as a '*',
# so the visible buffer must show masked stars and NEVER the plaintext password
# characters. The typed sequence is "ab" → backspace → "c" (logical password
# "ac"); on the OLD unmasked wrapper the pane would echo "ac" (plaintext) and on
# an un-erased-backspace bug it would echo "ab" — both are plaintext leaks and
# MUST FAIL. On the masked wrapper the buffer shows "**" (star erased by
# backspace, star re-added by 'c') with no plaintext, and MUST PASS. The prompt
# text itself contains no "ab"/"ac" adjacency, so these are safe leak sentinels
# (same technique assertion 1 uses with "ab"). NOTE: a bare grep for the literal
# retyped 'c' is WRONG for a masking test — masking hides 'c' as '*', so 'c'
# never appears; asserting its presence would fail on correct code (§11.4.1 /
# §11.4.115). We assert absence-of-plaintext + presence-of-masked-stars instead.
pth_send "drv_${NAME}" $'\x7f'
pth_send "drv_${NAME}" "c"
sleep 0.3
_buf2="$(pth_capture "drv_${NAME}")"
# Scoped to the prompt line for the same §11.4.201(7)(a) carrier reason as
# assertion 1 — a leak echoes HERE, so this is where the sentinel belongs.
_prompt_line2="$(printf '%s\n' "$_buf2" | grep "Enter password for session")"
if printf '%s' "$_prompt_line2" | grep -qF "ab" || printf '%s' "$_prompt_line2" | grep -qF "ac"; then
    _fail "plaintext still visible on the password prompt line after backspace+retype: $_prompt_line2"
else
    # logical password is "ac" (2 chars) after "ab" -> backspace -> "c";
    # exact star count on the live snapshot must be 2, not merely "contains
    # **" (which would also accept a stray-extra-star backspace-erase bug).
    _star_count2=$(printf '%s' "$_prompt_line2" | tr -dc '*' | wc -c)
    if [ "$_star_count2" -eq 2 ]; then
        _pass "backspace + retype shows exactly 2 masked stars, no plaintext leaked"
    else
        _fail "expected exactly 2 '*' characters after backspace+retype, got $_star_count2; line: $_prompt_line2"
    fi
fi

pth_send_enter "drv_${NAME}"
pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12 || true
pth_kill_pane "drv_${NAME}"

echo "── Test 77 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
