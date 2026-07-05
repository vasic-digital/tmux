#!/usr/bin/env bash
# Test 81 — root-cause regression guard for the exact user-reported bug:
# reopening a recycled (dead-but-state-persisted) password-protected
# session shows EXACTLY ONE password prompt, and the persisted password
# hash is UNCHANGED after a successful reopen.
#
# Purpose:    §11.4.115/§11.4.146 permanent regression guard. Forensic
#             anchor 2026-07-05 (user report): "When we open sessions
#             which are password protected, and we enter valid password,
#             we are then asked twice to enter (maybe new) password! ...
#             Once we enter the password we enter the session which is
#             already password protected." Root-caused to scripts/tmx.template
#             (fixed in the commits touching the attach/new verbs on
#             2026-07-05 — see git log for this file around that date).
#             This test reproduces the EXACT scenario: create a
#             password-protected session, tear its tmux server down
#             WITHOUT clearing tmx-state (mirrors tmx-recycler.sh's idle
#             teardown), then re-create/reopen it by name via `tmx new -s
#             NAME` (what a wizard "type the same name again" resolves
#             to) and asserts exactly one password prompt appears, the
#             correct password attaches, and the persisted hash is
#             unchanged (proving it was verified, not silently reset).
# Usage:      bash scripts/tests/81_open_existing_password_single_prompt.sh
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / 2 FAIL.
# Side-effects: private HOME/TMUX_TMPDIR/TMX_STATE_FILE sandbox, trap-cleaned.
# Dependencies: built tmux binary, scripts/tmx wrapper, scripts/tmx-state-bin,
#             python3, lib/pty_harness.sh, lib/interactive_pty_probe.sh.
# Cross-refs: scripts/tmx.template (attach + new verbs); tests 68, 80, 84;
#             §3 forensic anchor 2026-07-05; docs/superpowers/specs/
#             2026-07-05-tmx-wizard-password-redesign-design.md.
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
_pass() { echo "PASS 81: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 81: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 81: $*"; SKIP=$((SKIP+1)); }

echo "── Test 81: reopen recycled protected session shows exactly ONE prompt ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 81: unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

. "$SELF_DIR/lib/interactive_pty_probe.sh"
if ! ipty_interactive_terminal_ok "$TMUX_BIN"; then
    _skip "headless: no functional interactive terminal — §11.4.3"
    echo "── Test 81 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 0
fi

SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
if [ "$(( ${#SCRATCH_REAL} + 60 ))" -gt 100 ]; then SCRATCH="/tmp/tmx81.$$"; else SCRATCH="$SCRATCH_REAL/tmx81.$$"; fi
mkdir -p "$SCRATCH/home" || { echo "SKIP 81: cannot create scratch"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }

HARNESS="$SELF_DIR/lib/pty_harness.sh"
[ -f "$HARNESS" ] || { echo "SKIP 81: PTY harness missing"; rm -rf "$SCRATCH"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; }
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
export PTH_SOCK="tmx81drv-$$"
export PTH_TMPDIR="$SCRATCH"

NAME="t81_$$"
SOCK="tmx-$NAME"
PW="reopen_secret_456"

_cleanup() {
    pth_driver_kill
    "$WRAPPER" delete -t "$NAME" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

_envpfx() { printf 'HOME=%s TMUX_TMPDIR=%s TMX_STATE_FILE=%s' "$HOME_DIR" "$SCRATCH" "$STATE_FILE"; }
_wrap_in_pane() { _ds="$1"; shift; pth_run_pane "$_ds" "$(_envpfx) '$WRAPPER' $*"; }

# ── Step 1: create the session with a password (double-prompt: password +
#    confirm, per Task 4). ─────────────────────────────────────────────
if ! _wrap_in_pane "drv_${NAME}_c" new -s "$NAME"; then
    _fail "could not start create driver pane"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
if ! pth_wait_text "drv_${NAME}_c" "Enter password for session" 12; then
    _fail "initial create password prompt never appeared"
    pth_kill_pane "drv_${NAME}_c"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
pth_send "drv_${NAME}_c" "$PW"; pth_send_enter "drv_${NAME}_c"
pth_wait_text "drv_${NAME}_c" "Confirm password" 8 || true
pth_send "drv_${NAME}_c" "$PW"; pth_send_enter "drv_${NAME}_c"
if ! pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12; then
    _fail "session did not attach after create+confirm"
    pth_kill_pane "drv_${NAME}_c"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
_hash_before="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sessions']['$NAME']['password_hash'])" "$STATE_FILE" 2>/dev/null || true)"
if [ -z "$_hash_before" ]; then
    _fail "could not read the persisted password hash from state file (schema mismatch?) — check the JSON field name in $STATE_FILE and adjust this test's python3 accessor"
    pth_kill_pane "drv_${NAME}_c"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
echo "[evidence] session created, password set, hash captured: ${_hash_before:0:12}..."

# ── Step 2: tear the tmux server down WITHOUT clearing tmx-state — this
#    is EXACTLY what tmx-recycler.sh does on idle timeout: kill-session
#    (+ scope-stop on Linux), state record untouched. ────────────────────
CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK" "$NAME")"
[ -n "$CPID" ] && pth_kill_hup "$CPID"
pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "0" 10 || true
pth_kill_pane "drv_${NAME}_c"
"$WRAPPER" kill-session -t "$NAME" >/dev/null 2>&1 || true
"$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
sleep 0.5
if "$TMUX_BIN" -L "$SOCK" has-session -t "$NAME" 2>/dev/null; then
    _fail "setup error: session still alive after simulated recycle teardown"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
if ! "$STATE_BIN" has-password "$NAME" >/dev/null 2>&1; then
    _fail "setup error: password state did NOT survive the simulated recycle (test setup bug, not the fix under test)"
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
echo "[evidence] tmux server torn down (has-session fails), password state SURVIVES (has-password exit 0) — exact recycled-session shape reproduced"

# ── Step 3: reopen by the SAME name via `tmx new -s NAME` (what a wizard
#    "type the same name" / a direct re-create resolves to). Count how
#    many times "Enter password for session" OR "is password-protected"
#    appears — the bug's signature was BOTH appearing (verify prompt from
#    the dead attach, THEN the unconditional create-prompt). ────────────
if ! _wrap_in_pane "drv_${NAME}_r" new -s "$NAME"; then
    _fail "could not start reopen driver pane"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
if ! pth_wait_text "drv_${NAME}_r" "password-protected" 12; then
    _fail "reopen did not show the expected single verify-style prompt at all"
    pth_kill_pane "drv_${NAME}_r"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 2
fi
echo "[evidence] reopen shows the verify-style 'is password-protected' prompt"
pth_send "drv_${NAME}_r" "$PW"; pth_send_enter "drv_${NAME}_r"
if pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12; then
    _pass "reopen: correct password attaches"
else
    _fail "reopen: correct password did NOT attach"
fi
# The bug's signature: a SECOND, different-style prompt ("Enter password
# for session ... blank = none" or "Confirm password") appearing after the
# first. Capture the pane and assert NEITHER appears.
_buf="$(pth_capture "drv_${NAME}_r")"
if printf '%s' "$_buf" | grep -q "Enter password for session" || printf '%s' "$_buf" | grep -q "Confirm password"; then
    _fail "THE BUG REGRESSED: a second (create-style) password prompt appeared after the verify-style one"
else
    _pass "exactly ONE password prompt shown on reopen (no phantom second create/confirm prompt)"
fi

_hash_after="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sessions']['$NAME']['password_hash'])" "$STATE_FILE" 2>/dev/null || true)"
if [ "$_hash_after" = "$_hash_before" ]; then
    _pass "persisted password hash UNCHANGED after successful reopen (verified, not silently reset)"
else
    _fail "persisted password hash CHANGED after reopen (hash before=$_hash_before after=$_hash_after) — reopen silently reset the password"
fi

# ── Step 4: a WRONG password on reopen must still be rejected (proves
#    this isn't a blanket bypass). ──────────────────────────────────────
CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK" "$NAME")"
[ -n "$CPID" ] && pth_kill_hup "$CPID"
pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "0" 10 || true
pth_kill_pane "drv_${NAME}_r"
"$WRAPPER" kill-session -t "$NAME" >/dev/null 2>&1 || true
"$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
sleep 0.5
if ! _wrap_in_pane "drv_${NAME}_w" new -s "$NAME"; then
    _fail "could not start wrong-password reopen driver pane"
elif ! pth_wait_text "drv_${NAME}_w" "password-protected" 12; then
    _fail "second reopen (wrong-pw check) did not show the verify prompt"
    pth_kill_pane "drv_${NAME}_w"
else
    pth_send "drv_${NAME}_w" "totally_wrong_password"; pth_send_enter "drv_${NAME}_w"
    if pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 8; then
        _fail "WRONG password was accepted on reopen — verification is not enforced"
    else
        _pass "wrong password on reopen is correctly rejected (session not attached)"
    fi
    pth_kill_pane "drv_${NAME}_w"
fi

echo "── Test 81 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
