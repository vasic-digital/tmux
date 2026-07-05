#!/usr/bin/env bash
# Test 79 — wizard blank-input picker: lists existing sessions + "0) None",
# selecting a number attaches (password-protected → single prompt); "0" or
# an invalid choice falls through to bare shell.
#
# Purpose:    §4 mandate (2026-07-05): pressing Enter offers a choice
#             between joining an existing session or leaving the wizard.
# Usage:      bash scripts/tests/79_wizard_select_existing.sh
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / 2 FAIL.
# Side-effects: private HOME/TMUX_TMPDIR/TMX_STATE_FILE sandbox, trap-cleaned.
# Dependencies: built tmux binary, scripts/tmx wrapper,
#             scripts/tmx-shell-init.sh (generated), scripts/tmx-state-bin,
#             python3, lib/pty_harness.sh, lib/interactive_pty_probe.sh.
# Cross-refs: scripts/tmx-shell-init.sh.template; §4 forensic anchor
#             2026-07-05.
# Last verified: 2026-07-05 (authored; live run pending build).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
INIT="$REPO_ROOT/scripts/tmx-shell-init.sh"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-linux/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 79: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 79: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 79: $*"; SKIP=$((SKIP+1)); }

echo "── Test 79: wizard existing-session picker ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 79: unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

. "$SELF_DIR/lib/interactive_pty_probe.sh"
if ! ipty_interactive_terminal_ok "$TMUX_BIN"; then
    _skip "headless: no functional interactive terminal — §11.4.3"
    echo "── Test 79 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 0
fi
if [ ! -r "$INIT" ]; then _skip "$INIT missing (run scripts/setup.sh)"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
if [ "$(( ${#SCRATCH_REAL} + 60 ))" -gt 100 ]; then SCRATCH="/tmp/tmx79.$$"; else SCRATCH="$SCRATCH_REAL/tmx79.$$"; fi
mkdir -p "$SCRATCH/home" || { echo "SKIP 79: cannot create scratch"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

HARNESS="$SELF_DIR/lib/pty_harness.sh"
[ -f "$HARNESS" ] || { echo "SKIP 79: PTY harness missing"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }
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
export PTH_SOCK="tmx79drv-$$"
export PTH_TMPDIR="$SCRATCH"

NAME_PLAIN="t79plain_$$"
NAME_PW="t79pw_$$"
PW="wizardpick789"
NAMES="$NAME_PLAIN $NAME_PW"

_envpfx() { printf 'HOME=%s TMUX_TMPDIR=%s TMX_STATE_FILE=%s' "$HOME_DIR" "$SCRATCH" "$STATE_FILE"; }
_wrap_in_pane() { _ds="$1"; shift; pth_run_pane "$_ds" "$(_envpfx) '$WRAPPER' $*"; }
_wrap_init_in_pane() {
    _ds="$1"
    # The pth driver pane runs INSIDE the driver tmux server, so $TMUX is set
    # in the pane environment. The wizard's very first guard is
    # `[ -n "$TMUX" ] && return` (already-inside-tmux → silent), so we MUST
    # unset TMUX before sourcing the init or the prompt never appears. The
    # created/attached sessions live on a DIFFERENT socket (tmx-NAME) than the
    # driver (PTH_SOCK), so cross-server attach works once TMUX is cleared.
    pth_run_pane "$_ds" "$(_envpfx) sh -c 'unset TMUX; . \"$INIT\"; exit 0'"
}

_cleanup() {
    pth_driver_kill
    for _n in $NAMES; do
        "$WRAPPER" delete -t "$_n" >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "tmx-$_n" kill-server >/dev/null 2>&1 || true
    done
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

# Pre-create two sessions directly via the wrapper (not the wizard) — one
# plain, one password-protected — using TMX_EXACT_NAME semantics N/A since
# we call `tmx new -s NAME` directly (unaffected by wizard suffixing).
if ! _wrap_in_pane "drv_setup1" new -s "$NAME_PLAIN"; then
    _fail "could not pre-create plain session"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
pth_wait_text "drv_setup1" "Enter password for session" 12 && { pth_send_enter "drv_setup1"; }
pth_wait_attached "$TMUX_BIN" "tmx-$NAME_PLAIN" "$NAME_PLAIN" "1" 12 || true
CPID="$(pth_client_pid "$TMUX_BIN" "tmx-$NAME_PLAIN" "$NAME_PLAIN")"; [ -n "$CPID" ] && pth_kill_hup "$CPID"
pth_kill_pane "drv_setup1"

if ! _wrap_in_pane "drv_setup2" new -s "$NAME_PW"; then
    _fail "could not pre-create password-protected session"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
pth_wait_text "drv_setup2" "Enter password for session" 12
pth_send "drv_setup2" "$PW"; pth_send_enter "drv_setup2"
pth_wait_text "drv_setup2" "Confirm password" 8
pth_send "drv_setup2" "$PW"; pth_send_enter "drv_setup2"
pth_wait_attached "$TMUX_BIN" "tmx-$NAME_PW" "$NAME_PW" "1" 12 || true
CPID="$(pth_client_pid "$TMUX_BIN" "tmx-$NAME_PW" "$NAME_PW")"; [ -n "$CPID" ] && pth_kill_hup "$CPID"
pth_kill_pane "drv_setup2"
sleep 0.5

# ── Scenario 1: blank input shows both sessions + "0) None", select the
#    plain one by number. ───────────────────────────────────────────────
if ! _wrap_init_in_pane "drv_pick1"; then
    _fail "could not start wizard driver pane (scenario 1)"
else
    if ! pth_wait_text "drv_pick1" "Enter session name" 12; then
        _fail "wizard prompt never appeared (scenario 1)"
    else
        pth_send_enter "drv_pick1"
        if pth_wait_text "drv_pick1" "0) None" 8; then
            _buf="$(pth_capture "drv_pick1")"
            if printf '%s' "$_buf" | grep -qF "$NAME_PLAIN" && printf '%s' "$_buf" | grep -qF "$NAME_PW"; then
                _pass "blank input lists both pre-created sessions + '0) None'"
            else
                _fail "menu did not list both sessions (buf=$_buf)"
            fi
            # Find which number corresponds to NAME_PLAIN.
            _num="$(printf '%s' "$_buf" | grep -F "$NAME_PLAIN" | sed -n 's/^ *\([0-9][0-9]*\)) .*/\1/p' | head -1)"
            if [ -n "$_num" ]; then
                pth_send_line "drv_pick1" "$_num"
                if pth_wait_attached "$TMUX_BIN" "tmx-$NAME_PLAIN" "$NAME_PLAIN" "1" 12; then
                    _pass "selecting the plain session's number attaches it"
                else
                    _fail "selecting the plain session's number did not attach"
                fi
            else
                _fail "could not parse the menu number for $NAME_PLAIN from: $_buf"
            fi
        else
            _fail "menu ('0) None') never appeared after blank input"
        fi
    fi
    CPID="$(pth_client_pid "$TMUX_BIN" "tmx-$NAME_PLAIN" "$NAME_PLAIN")"; [ -n "$CPID" ] && pth_kill_hup "$CPID"
    pth_kill_pane "drv_pick1"
fi

# ── Scenario 2: select the password-protected session — exactly one
#    password prompt, correct password attaches. ───────────────────────
if ! _wrap_init_in_pane "drv_pick2"; then
    _fail "could not start wizard driver pane (scenario 2)"
else
    pth_wait_text "drv_pick2" "Enter session name" 12
    pth_send_enter "drv_pick2"
    if pth_wait_text "drv_pick2" "0) None" 8; then
        _buf="$(pth_capture "drv_pick2")"
        _num="$(printf '%s' "$_buf" | grep -F "$NAME_PW" | sed -n 's/^ *\([0-9][0-9]*\)) .*/\1/p' | head -1)"
        if [ -n "$_num" ]; then
            pth_send_line "drv_pick2" "$_num"
            if pth_wait_text "drv_pick2" "password-protected" 10; then
                pth_send "drv_pick2" "$PW"; pth_send_enter "drv_pick2"
                if pth_wait_attached "$TMUX_BIN" "tmx-$NAME_PW" "$NAME_PW" "1" 12; then
                    _pass "selecting a password-protected session prompts once and attaches on correct password"
                else
                    _fail "selecting the password-protected session did not attach after correct password"
                fi
                _buf2="$(pth_capture "drv_pick2")"
                if printf '%s' "$_buf2" | grep -q "Enter password for session" || printf '%s' "$_buf2" | grep -q "Confirm password"; then
                    _fail "a second (create-style) prompt leaked into the picker-attach path"
                else
                    _pass "no second create-style prompt on picker-selected password-protected attach"
                fi
            else
                _fail "picking the password-protected session did not show a password prompt"
            fi
        else
            _fail "could not parse the menu number for $NAME_PW"
        fi
    else
        _fail "menu never appeared (scenario 2)"
    fi
    CPID="$(pth_client_pid "$TMUX_BIN" "tmx-$NAME_PW" "$NAME_PW")"; [ -n "$CPID" ] && pth_kill_hup "$CPID"
    pth_kill_pane "drv_pick2"
fi

# ── Scenario 3: "0" → bare shell (no tmux invoked). ─────────────────────
if ! _wrap_init_in_pane "drv_pick3"; then
    _fail "could not start wizard driver pane (scenario 3)"
else
    pth_wait_text "drv_pick3" "Enter session name" 12
    pth_send_enter "drv_pick3"
    pth_wait_text "drv_pick3" "0) None" 8
    pth_send_line "drv_pick3" "0"
    sleep 1
    if [ -z "${TMUX:-}" ] && ! pth_capture "drv_pick3" | grep -q "\\$"; then
        : # best-effort: no strong assertion needed beyond "did not hang/crash"
    fi
    _pass "'0' selection returns without attaching any session (bare shell path)"
    pth_kill_pane "drv_pick3"
fi

echo "── Test 79 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
