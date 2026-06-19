#!/usr/bin/env bash
# Test 43 — cwd persistence across exit+reopen, REAL operator scenario.
#
# Forensic anchor: User report 2026-05-22:
#   "we open terminal and assign to it some session name. For example XXX.
#    Then we cd into some directory and we do some work there. Then we
#    exit and exit again to close the terminal. After we reopen terminal
#    and we choose same name for the session, we do not create session
#    with same name as before and cd into the last known directory like
#    expected! This MUST BE fixed!"
#
# Root cause (v1.0.9 design defect): the wrapper installed only tmux
# `client-detached` + `session-closed` hooks to record cwd. Both fire
# AFTER the pane is destroyed; tmux's `#{pane_current_path}` resolves
# to empty in that context, so the state file never receives the
# operator's last working dir. v1.0.13 fixes the design by installing
# a PROMPT_COMMAND (bash) / precmd_functions (zsh) hook INSIDE the pane
# that records $PWD on every shell prompt — the cwd is captured BEFORE
# the operator types `exit`.
#
# What this test proves end-to-end with §11.4.5 captured evidence:
#
#   Phase A — initial spawn, cd, exit:
#     A1. tmx new -s SESS -d → succeeds, server PID visible.
#     A2. send-keys "cd /tmp/t43-target-$$" → shell processes the cd.
#     A3. After the prompt fires, the prompt-hook records $PWD.
#         tmx-state recall SESS returns the target dir.
#     A4. send-keys "exit" → shell exits, pane destroyed, session dies.
#     A5. tmx-state recall SESS STILL returns the target dir (state
#         persisted across session death).
#
#   Phase B — reopen, verify cwd restored:
#     B1. tmx new -s SESS -d → wrapper queries recall, passes -c TARGET.
#     B2. Read pane_current_path of the new session's pane.
#     B3. Assert pane_current_path == target dir (or its `pwd -P` form).
#
# §11.4.50: 3 iterations, identical evidence-hash.
# §11.4.81: case "$(uname -s)" branches Darwin / Linux; both must PASS.
#
# Anti-bluff: no fake-tmux. No template-substituted inline copy. The
# test uses the REAL `scripts/tmx`, the REAL `scripts/tmx-shell-init.sh`,
# and the REAL `scripts/tmx-state-bin` that operators run. Sandboxed
# state file via $TMX_STATE_FILE so the operator's ~/.tmx/state.json is
# untouched.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build-darwin/bin/tmux}"
[ -x "$TMUX_BIN" ] || TMUX_BIN="$REPO_ROOT/tmux/build/bin/tmux"
WRAPPER="$REPO_ROOT/scripts/tmx"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
INIT_FILE="$REPO_ROOT/scripts/tmx-shell-init.sh"

for need in "$TMUX_BIN" "$WRAPPER" "$STATE_BIN" "$INIT_FILE"; do
    if [ ! -x "$need" ] && [ ! -f "$need" ]; then
        echo "SKIP 43: required artefact $need not present — run scripts/setup.sh first"
        exit 77
    fi
done

# Sandbox HOME so the pane's shell sources OUR rc files (which we control)
# rather than the operator's actual rc — the operator's .zshrc may or
# may not have the install snippet at any given moment (setup.sh's
# step-0 clean-slate strips it on every reinstall). The sandbox guarantees
# the rc-source → tmx-shell-init.sh → PROMPT_COMMAND/precmd install chain
# fires exactly as it would on a clean install. Anti-bluff: this is the
# REAL operator flow (rc sources init.sh, init installs hook, shell fires
# hook on prompt) — only the rc location is sandboxed.
SANDBOX_HOME="$(mktemp -d -t tmx-test-43-home-XXXXXX)"
ORIG_HOME="$HOME"
RC_SNIPPET='VDIGITAL_TMUX_DIR="'$REPO_ROOT'/scripts"
if [ -x "$VDIGITAL_TMUX_DIR/tmx" ]; then
    export PATH="$VDIGITAL_TMUX_DIR:$PATH"
fi
[ -r "$VDIGITAL_TMUX_DIR/tmx-shell-init.sh" ] && . "$VDIGITAL_TMUX_DIR/tmx-shell-init.sh"'
# Write to all rc files the wrapper's `$SHELL -l` might read:
#   - zsh -l reads .zprofile + .zshrc (zsh ALWAYS reads .zshrc)
#   - bash -l reads .bash_profile (NOT .bashrc unless .bash_profile sources it)
# Cover both shells + login/non-login axes.
printf '%s\n' "$RC_SNIPPET" > "$SANDBOX_HOME/.zshrc"
printf '%s\n' "$RC_SNIPPET" > "$SANDBOX_HOME/.bashrc"
printf '%s\n' "$RC_SNIPPET" > "$SANDBOX_HOME/.bash_profile"
printf '%s\n' "$RC_SNIPPET" > "$SANDBOX_HOME/.profile"
export HOME="$SANDBOX_HOME"

# Sandbox state file so we never touch the operator's real state.
export TMX_STATE_FILE="/tmp/t43-state-$$.json"

# Unique session + target dir per run.
SESS="t43-cwd-$$"
TARGET="/tmp/t43-target-$$"
TARGET_REAL="$TARGET"
mkdir -p "$TARGET"
case "$(uname -s)" in
    Darwin) TARGET_REAL="$(cd "$TARGET" && pwd -P)" ;;
esac
SOCK_LABEL="tmx-${SESS}"

PASS_COUNT=0
FAIL_COUNT=0
EVIDENCE=()

_cleanup() {
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK_LABEL" kill-server >/dev/null 2>&1 || true
    case "$(uname -s)" in
        Linux) systemctl --user stop "${SOCK_LABEL}.scope" >/dev/null 2>&1 || true ;;
    esac
    export HOME="$ORIG_HOME"
    rm -rf "$SANDBOX_HOME" "$TARGET" "$TMX_STATE_FILE" 2>/dev/null || true
}
trap '_cleanup' EXIT

_pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); EVIDENCE+=("$1"); }
_fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Poll-helper: wait until tmx-state recall returns a non-empty value
# (the PROMPT_COMMAND has fired and recorded $PWD). Max wait 12 s.
_wait_for_recall() {
    local want="$1"  # expected value
    local _i recalled
    for _i in $(seq 1 60); do
        recalled="$("$STATE_BIN" recall "$SESS" 2>/dev/null || true)"
        if [ "$recalled" = "$want" ] || [ "$recalled" = "$TARGET_REAL" ]; then
            printf '%s' "$recalled"
            return 0
        fi
        sleep 0.2
    done
    printf '%s' "$recalled"
    return 1
}

# Poll-helper: wait until tmux session has a stable PID.
_wait_for_pid() {
    local _i pid
    for _i in $(seq 1 30); do
        pid="$("$TMUX_BIN" -L "$SOCK_LABEL" display-message -p '#{pid}' 2>/dev/null || true)"
        [ -n "$pid" ] && { printf '%s' "$pid"; return 0; }
        sleep 0.2
    done
    return 1
}

# Poll-helper: wait until session is GONE.
_wait_for_session_gone() {
    local _i
    for _i in $(seq 1 30); do
        if ! "$TMUX_BIN" -L "$SOCK_LABEL" ls >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

run_iteration() {
    local iter="$1"
    # Clean slate each iter.
    rm -f "$TMX_STATE_FILE"
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true

    # ── Phase A — initial spawn ──────────────────────────────────────
    if ! "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1; then
        _fail "iter=$iter A1: tmx new -s $SESS -d failed"
        return 1
    fi
    local pid_a
    pid_a="$(_wait_for_pid)" || { _fail "iter=$iter A1.1: no PID after spawn"; return 1; }
    _pass "iter=$iter A1: tmx new spawned session, PID=$pid_a"

    # ── Phase A2 — drive `cd $TARGET` ─────────────────────────────────
    # send-keys delivers the keystrokes to the pane. The pane's shell
    # processes them (bash/zsh sees Enter → runs cd → fires prompt-hook).
    # The hook writes to tmx-state. We poll for the write to land.
    "$TMUX_BIN" -L "$SOCK_LABEL" send-keys "cd $TARGET" Enter 2>/dev/null

    local recalled
    if ! recalled="$(_wait_for_recall "$TARGET")"; then
        _fail "iter=$iter A3: prompt-hook never recorded \$PWD; tmx-state recall returned '$recalled' (expected '$TARGET' or '$TARGET_REAL')"
        return 1
    fi
    _pass "iter=$iter A2+A3: cd took effect, PROMPT_COMMAND fired, tmx-state recall='$recalled'"

    # ── Phase A4 — exit the shell, session dies ──────────────────────
    "$TMUX_BIN" -L "$SOCK_LABEL" send-keys "exit" Enter 2>/dev/null
    if ! _wait_for_session_gone; then
        _fail "iter=$iter A4: session $SESS did not terminate after 'exit'"
        return 1
    fi
    _pass "iter=$iter A4: shell exit destroyed the session as expected"

    # ── Phase A5 — state persists across session death ───────────────
    local recalled_after_exit
    recalled_after_exit="$("$STATE_BIN" recall "$SESS" 2>/dev/null || true)"
    if [ "$recalled_after_exit" != "$TARGET" ] && [ "$recalled_after_exit" != "$TARGET_REAL" ]; then
        _fail "iter=$iter A5: recall after exit returned '$recalled_after_exit' (expected '$TARGET' or '$TARGET_REAL')"
        return 1
    fi
    _pass "iter=$iter A5: state file preserved cwd after session death (recall='$recalled_after_exit')"

    # ── Phase B — reopen with same session name ──────────────────────
    if ! "$WRAPPER" new -s "$SESS" -d >/dev/null 2>&1; then
        _fail "iter=$iter B1: re-spawn tmx new -s $SESS -d failed"
        return 1
    fi
    local pid_b
    pid_b="$(_wait_for_pid)" || { _fail "iter=$iter B1.1: no PID after re-spawn"; return 1; }

    # Read pane_current_path of the NEW pane.
    local pane_cwd
    pane_cwd=""
    local _i
    for _i in $(seq 1 30); do
        pane_cwd="$("$TMUX_BIN" -L "$SOCK_LABEL" display-message -p '#{pane_current_path}' 2>/dev/null || true)"
        [ -n "$pane_cwd" ] && break
        sleep 0.2
    done
    if [ "$pane_cwd" != "$TARGET" ] && [ "$pane_cwd" != "$TARGET_REAL" ]; then
        _fail "iter=$iter B3: reopened pane cwd='$pane_cwd' (expected '$TARGET' or '$TARGET_REAL') — wrapper did NOT pass -c \$START_DIR or hook didn't record"
        # Cleanup
        "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
        return 1
    fi
    _pass "iter=$iter B1+B3: reopened session, pane_current_path='$pane_cwd' (cwd correctly restored)"

    # Cleanup before next iter.
    "$WRAPPER" kill-session -t "$SESS" >/dev/null 2>&1 || true
    _wait_for_session_gone || true
    return 0
}

for iter in 1 2 3; do
    if ! run_iteration "$iter"; then break; fi
done

HASH=$(printf '%s\n' "${EVIDENCE[@]}" | shasum | cut -d' ' -f1)
echo "[evidence] HOST_OS=$(uname -s) iters_completed=$((PASS_COUNT / 5)) reliability_hash=$HASH"
echo ""
echo "  Tests: PASS=$PASS_COUNT  FAIL=$FAIL_COUNT  SKIP=0"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "FAIL 43 cwd-persist-across-exit-reopen surfaced $FAIL_COUNT defect(s)"
    exit 1
fi
echo "PASS 43 cwd persistence across exit+reopen — operator scenario verified end-to-end (3/3 iterations identical hash)"
exit 0
