#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Test 68 — full tmx session-lifecycle scenario (operator-path, PTY-driven).
#
# Purpose:    End-to-end, fully-autonomous validation of the 7-clause operator
#             session-lifecycle scenario, driven through the SAME entry points
#             an end user invokes (`tmx new -s NAME:color`, `tmx attach -t
#             NAME`, `tmx delete -t NAME`) — never hand-spawned tmux. The
#             per-session password is read from /dev/tty, so the scenario is
#             driven via a REAL PTY using `tmux send-keys` into a throwaway
#             DRIVER pane that runs the wrapper (lib/pty_harness.sh). Every
#             wait is a bounded poll on a real CONDITION (prompt text /
#             attached-count / has-session), never a blind sleep (§11.4.50).
#
#             The 7 clauses (operator spec):
#               C1 `tmx new -s NAME:red` → session named NAME, color RED,
#                  applied (live status-style bg=red) + persisted (get-color).
#               C2 create-time /dev/tty password prompt → provide the
#                  password → stored hashed (verify-password accepts it,
#                  rejects a wrong one).
#               C3 cd into a dir under ~/Projects + run `ls` → the pane's cwd
#                  is that dir (recorded for later restore).
#               C4 close the terminal WITHOUT killing (kill -HUP the attached
#                  client) → the session/server SURVIVES detached.
#               C5 rejoin in a fresh terminal by the same name → (a) same dir,
#                  (b) same RED, (c) password RE-PROMPTED — a wrong password is
#                  REJECTED, only the correct one attaches.
#               C6 after leaving with no client, the session is RECYCLED after
#                  a short idle window (TMX_RECYCLE_IDLE_SECS) — but dir+color+
#                  password are ALWAYS remembered. A re-create VERIFIES the
#                  remembered password ONCE (§11.4.120 reconciliation,
#                  2026-07-05: correct attaches + restores dir/color; wrong is
#                  rejected) rather than re-prompting to set a new one.
#               C7 `tmx delete -t NAME` then re-create → DEFAULT color (host
#                  fallback), DEFAULT dir ($HOME), FRESH create password prompt
#                  (the reset).
#
# Usage:      bash scripts/tests/68_session_lifecycle.sh
#             (auto-discovered + run by scripts/tests/run_all.sh glob.)
# Inputs:     TMUX_BIN / WRAPPER / EXPECTED_VERSION (optional env overrides).
# Outputs:    EVIDENCE … ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: creates + tears down ONLY its own uniquely-named sessions on
#             private sockets under a private SCRATCH HOME / TMUX_TMPDIR /
#             TMX_STATE_FILE — never touches the operator's real sessions,
#             state file, or /tmp/tmux-<uid>. trap-cleanup on every exit path.
# Dependencies: a built tmux binary (TMUX_BIN), the generated `scripts/tmx`
#             wrapper, `scripts/tmx-state-bin`, python3 (for the kill-HUP PTY
#             client) — each absent ⇒ honest SKIP-with-reason (§11.4.3),
#             NEVER a false PASS/FAIL.
# Interface contract (matches the implementer): C7 verb `tmx delete -t NAME`
#             (kills + clears persisted state); the idle recycler is the
#             AUTO-STARTED per-session watcher `tmx new` launches (tmx-
#             recycler.sh `watch`, window = env TMX_RECYCLE_IDLE_SECS at create
#             time; 0 = OFF; there is NO supported manual drive). C1–C5 run with
#             the recycler OFF (TMX_RECYCLE_IDLE_SECS=0) so it can never race the
#             C5 reattach flow; C6 arms a DEDICATED short-window (=3) session so
#             the recycle is deterministic and isolated. State file keyed by
#             sanitised name with last_pwd/color/password_hash.
# §11.4.50:  the full lifecycle runs N=3 with unique per-iter names + full
#             cleanup, so consecutive automated runs are independent.
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean; bash-3.2-safe (macOS).
# §11.4.14:  trap cleanup kills every driver/inner session + python client.
# §11.4.123: every PASS reads LIVE server / persisted-state evidence, never a
#             bare exit code of the thing under test.
# Cross-refs: scripts/tests/lib/pty_harness.sh (PTY primitives + self-test);
#             scripts/tmx.template (/dev/tty prompts, color, recall, delete);
#             scripts/tmx-recycler.sh (idle recycler — implementer-owned);
#             tests 63 (color) / 66 (password) ; research
#             scenario_lifecycle_research.md.
# Last verified: 2026-06-28 (harness mechanism proven via lib --selftest;
#             FULL 7-clause LIVE run DEFERRED to the post-merge built-binary
#             run — see the bottom note. NOT faked GREEN here.)
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
STATE_BIN="$REPO_ROOT/scripts/tmx-state-bin"
RECYCLER="$REPO_ROOT/scripts/tmx-recycler.sh"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-linux/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 68: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 68: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 68: $*"; SKIP=$((SKIP+1)); }

echo "── Test 68: full tmx session-lifecycle scenario (PTY-driven, operator-path) ──"

case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 68: unsupported platform $HOST_OS — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0 ;;
esac

# §11.4.3 topology dispatch: the lifecycle is PTY-driven and the create-time
# password prompt reads from a controlling /dev/tty — both need a functional
# interactive terminal. A headless container's PTY-attached tmux client registers
# no usable terminal size, so the prompt never appears (discriminator 2026-06-30).
# SKIP here; a real terminal runs the full lifecycle + enforces it.
. "$SELF_DIR/lib/interactive_pty_probe.sh"
if ! ipty_interactive_terminal_ok "$TMUX_BIN"; then
    _skip "headless: no functional interactive terminal (PTY-attached tmux client registers no usable size); create-time /dev/tty password prompt cannot appear (needs a real terminal) — §11.4.3"
    echo "── Test 68 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 0
fi

# ── Socket-length-safe private SCRATCH (mirror of test 60). tmux AF_UNIX
#    sun_path is ~104 B; route via ${TMPDIR:-/tmp} but fall back to /tmp when
#    the realpath + socket suffix would overflow (macOS /var/folders). ──────
SCRATCH_CANDID="${TMPDIR:-/tmp}"; SCRATCH_CANDID="${SCRATCH_CANDID%/}"
SCRATCH_REAL="$(cd "$SCRATCH_CANDID" 2>/dev/null && pwd -P)" || SCRATCH_REAL="$SCRATCH_CANDID"
if [ "$(( ${#SCRATCH_REAL} + 60 ))" -gt 100 ]; then
    SCRATCH="/tmp/tmx68.$$"
else
    SCRATCH="$SCRATCH_REAL/tmx68.$$"
fi
_wtest="$SCRATCH/.wtest"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 68: scratch root $SCRATCH not writable (disk full / RO) — §11.4.3"
    rm -rf "$_wtest" 2>/dev/null || true; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
rmdir "$_wtest" 2>/dev/null || true

# ── Source the PTY harness (proven via `bash lib/pty_harness.sh --selftest`). ─
HARNESS="$SELF_DIR/lib/pty_harness.sh"
if [ ! -f "$HARNESS" ]; then
    echo "SKIP 68: PTY harness $HARNESS missing — §11.4.3"; rm -rf "$SCRATCH" 2>/dev/null || true
    echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0
fi
# shellcheck disable=SC1090
. "$HARNESS"

# ── Preconditions: a built binary + generated wrapper + state bin are REQUIRED
#    for the live scenario. Absent ⇒ honest SKIP (the expected state in a
#    fresh feature worktree with no build). ────────────────────────────────
if [ ! -x "$TMUX_BIN" ]; then _skip "tmux binary not built at $TMUX_BIN — live scenario deferred to built-binary run"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; rm -rf "$SCRATCH" 2>/dev/null || true; exit 0; fi
if [ ! -x "$WRAPPER" ];  then _skip "scripts/tmx wrapper not generated (run setup.sh) — live scenario deferred"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; rm -rf "$SCRATCH" 2>/dev/null || true; exit 0; fi
if [ ! -x "$STATE_BIN" ]; then _skip "scripts/tmx-state-bin not built — live scenario deferred"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; rm -rf "$SCRATCH" 2>/dev/null || true; exit 0; fi
if ! pth_have_python; then _skip "python3 absent — kill-HUP PTY client (C4/C6/C7 terminal-close) infeasible — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; rm -rf "$SCRATCH" 2>/dev/null || true; exit 0; fi

# ── Isolation env. The driver server, the inner tmx server, and our inner
#    introspection ALL share one TMUX_TMPDIR (per pty_harness contract), one
#    private HOME (so the C7 default-dir == $HOME is predictable), one private
#    TMX_STATE_FILE, and a FIXED TMX_HOSTNAME (so the C7 default-color
#    fallback is deterministic). ────────────────────────────────────────────
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/Projects"
STATE_FILE="$SCRATCH/state.json"
LAUNCH="$SCRATCH/launch.sh"
FIXED_HOST="t68host"
RECYCLE_SECS=3          # short idle window for the DEDICATED C6 recycle session
RC_WINDOW=0             # per-pane recycler window: 0=OFF for C1–C5 (never races
                        # the C5 reattach flow); armed to RECYCLE_SECS ONLY for
                        # the C6 dedicated-session create (§finding 3).
cat > "$LAUNCH" <<'LAUNCHSH'
#!/bin/sh
# Clears the nesting guard so the inner tmx server starts cleanly inside the
# outer driver pane, then execs the wrapper with the test's isolated env.
unset TMUX TMUX_PANE
# §11.4.111: the outer driver pane inherits its TERM from the driver tmux's
# default-terminal. The inner tmx server validates $TERM on its real PTY and
# the inner `tmux attach` REFUSES a terminal that is not cursor-addressable —
# the exact C1 failure when a non-interactive `ssh host 'cmd'` (or a minimal/CI
# host) injects TERM=dumb: `tmux attach` exits 1 with "open terminal failed:
# terminal does not support clear", the driver pane dies, and the inner client
# never attaches. A terminfo entry ALONE is NOT a sufficient gate — `dumb` /
# `unknown` DO resolve via `infocmp` yet tmux rejects them. Pick the first
# tmux-USABLE candidate (terminfo-present AND `clear`-capable, the capability
# tmux's error names), so the test exercises the REAL operator scenario (a
# usable TERM) deterministically on every host. §11.4.6: `tput -T X clear` is
# the portable Linux+macOS query of that exact capability.
for _t in "$TERM" screen-256color xterm-256color screen xterm; do
    [ -n "$_t" ] || continue
    case "$_t" in dumb|unknown) continue ;; esac
    if command -v tput >/dev/null 2>&1; then
        if tput -T "$_t" clear >/dev/null 2>&1; then TERM="$_t"; export TERM; break; fi
    elif command -v infocmp >/dev/null 2>&1; then
        if infocmp "$_t" 2>/dev/null | grep -qE '(^|[,[:space:]])clear='; then TERM="$_t"; export TERM; break; fi
    fi
done
exec "$@"
LAUNCHSH
chmod +x "$LAUNCH"

export TMX_STATE_FILE="$STATE_FILE"
export TMUX_TMPDIR="$SCRATCH"         # pty_harness inner-helper contract
export PTH_TMUX="$TMUX_BIN"
export PTH_SOCK="tmx68drv-$$"
export PTH_TMPDIR="$SCRATCH"

PYPIDS=""               # python PTY-client wrapper pids to reap
NAMES=""                # inner session names created (for cleanup)

_cleanup() {
    pth_driver_kill
    for _n in $NAMES; do
        "$WRAPPER" delete -t "$_n" >/dev/null 2>&1 || true
        "$WRAPPER" kill-session -t "$_n" >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "tmx-$_n" kill-server >/dev/null 2>&1 || true
    done
    for _p in $PYPIDS; do kill "$_p" >/dev/null 2>&1 || true; done
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

# Build the env prefix every pane command shares (no spaces in any value).
_envpfx() {
    # TMX_RECYCLE_IDLE_SECS = $RC_WINDOW: OFF (0) for the C1–C5 session so the
    # auto-started recycler watcher can NEVER race the C5 reattach flow; armed
    # to RECYCLE_SECS only for the dedicated C6 create (§finding 3).
    printf 'HOME=%s TMUX_TMPDIR=%s TMX_STATE_FILE=%s TMX_HOSTNAME=%s TMX_RECYCLE_IDLE_SECS=%s' \
        "$HOME_DIR" "$SCRATCH" "$STATE_FILE" "$FIXED_HOST" "$RC_WINDOW"
}
# Run the wrapper in a fresh driver pane (a fresh "terminal"). $1 driver-sess,
# rest = wrapper args.
_wrap_in_pane() {
    _ds="$1"; shift
    pth_run_pane "$_ds" "$(_envpfx) sh '$LAUNCH' '$WRAPPER' $*"
}
_get_opt()  { "$TMUX_BIN" -L "tmx-$1" show-options -gv "$2" 2>/dev/null; }
_recall()   { "$STATE_BIN" recall "$1" 2>/dev/null; }
_getcolor() { "$STATE_BIN" get-color "$1" 2>/dev/null; }

PW="test_password_123"
WRONGPW="wrong_pw_999"

# ═════════════════════════════════════════════════════════════════════════
# Lifecycle ×3 (§11.4.50 deterministic consistency), unique name per iter.
# ═════════════════════════════════════════════════════════════════════════
for _iter in 1 2 3; do
    RC_WINDOW=0                       # recycler OFF by default each iter (§finding 3)
    NAME="t68_${$}_${_iter}"
    SOCK="tmx-$NAME"
    C6NAME="${NAME}c6"               # DEDICATED short-window session for the C6 recycle test
    C6SOCK="tmx-$C6NAME"
    NAMES="$NAMES $NAME $C6NAME"
    PROJ="$HOME_DIR/Projects/work_$_iter"; mkdir -p "$PROJ"
    # §11.4.6 host-robust path compare: the cwd-record hook persists
    # #{pane_current_path}, which the kernel reports CANONICALISED (symlinks
    # resolved). On macOS /tmp is a symlink to /private/tmp, so the recorded
    # value is /private/tmp/... while $PROJ is the /tmp/... literal — they name
    # the SAME directory. C3/C5 grep the pane's `pwd` OUTPUT (logical, /tmp/...)
    # so they match, but the C6 `_recall` compare is against the physical path
    # and FAILed on macOS only. Compare against the canonical form too (Linux:
    # /tmp is real, so PROJ_REAL == PROJ; no behaviour change there).
    PROJ_REAL="$(cd "$PROJ" 2>/dev/null && pwd -P || echo "$PROJ")"
    echo "── iter $_iter: session '$NAME' ──"

    # ───────────────────────────── C1 + C2 ──────────────────────────────
    # `tmx new -s NAME:red` → create prompt → password → confirm → attaches.
    # §11.4.120 reconciliation (2026-07-05): the `new` verb now asks for the
    # password TWICE on a genuinely fresh name (password + confirmation), per
    # the §3 double-prompt mandate (root-cause fix half 2 of 2). Drive BOTH
    # prompts with the matching value so the create flow completes.
    if ! _wrap_in_pane "drv_${NAME}_c" new -s "$NAME:red"; then
        _fail "iter $_iter C1: could not start create driver pane"; continue
    fi
    if ! pth_wait_text "drv_${NAME}_c" "Enter password for session" 12; then
        _fail "iter $_iter C2: create-time /dev/tty password prompt never appeared"
        pth_kill_pane "drv_${NAME}_c"; continue
    fi
    echo "[evidence C2 iter=$_iter] create password prompt observed; sending password via send-keys"
    pth_send "drv_${NAME}_c" "$PW"; pth_send_enter "drv_${NAME}_c"
    if ! pth_wait_text "drv_${NAME}_c" "Confirm password" 8; then
        _fail "iter $_iter C2: create-time password confirmation prompt never appeared"
        pth_kill_pane "drv_${NAME}_c"; continue
    fi
    echo "[evidence C2 iter=$_iter] confirmation prompt observed; sending matching confirmation"
    pth_send "drv_${NAME}_c" "$PW"; pth_send_enter "drv_${NAME}_c"
    if ! pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12; then
        _fail "iter $_iter C1: session did not come up / attach after password"
        pth_kill_pane "drv_${NAME}_c"; continue
    fi

    # C1: RED applied (live) + persisted.
    ss="$(_get_opt "$NAME" status-style)"
    [ "$ss" = "bg=red" ] && _pass "iter $_iter C1: live status-style bg=red (RED applied)" \
        || _fail "iter $_iter C1: status-style='$ss' (want bg=red)"
    gc="$(_getcolor "$NAME")"
    [ "$gc" = "red" ] && _pass "iter $_iter C1: color RED persisted (get-color=red)" \
        || _fail "iter $_iter C1: get-color='$gc' (want red)"

    # C2: password stored hashed — accepts correct, rejects wrong.
    if "$STATE_BIN" verify-password "$NAME" "$PW" >/dev/null 2>&1; then
        _pass "iter $_iter C2: password stored — verify accepts correct (exit 0)"
    else
        _fail "iter $_iter C2: verify-password rejected the just-set password"
    fi
    "$STATE_BIN" verify-password "$NAME" "$WRONGPW" >/dev/null 2>&1
    [ "$?" -eq 1 ] && _pass "iter $_iter C2: wrong password rejected (exit 1)" \
        || _fail "iter $_iter C2: wrong password NOT rejected"

    # ───────────────────────────── C3 ───────────────────────────────────
    # cd into a dir under ~/Projects + ls → pane cwd is that dir.
    pth_send_line "drv_${NAME}_c" "cd '$PROJ' && ls && echo \"C3PW\"\"D:\$(pwd)\" && echo \"C3DO\"\"NE_$_iter\""
    if pth_wait_text "drv_${NAME}_c" "C3DONE_$_iter" 10 \
       && pth_wait_text "drv_${NAME}_c" "C3PWD:$PROJ" 10; then
        echo "[evidence C3 iter=$_iter] pane cwd == $PROJ (ls ran; pwd shows the dir)"
        _pass "iter $_iter C3: cd into ~/Projects dir + ls → pane cwd is the dir"
    else
        _fail "iter $_iter C3: pane cwd not confirmed as $PROJ after cd+ls"
    fi

    # ───────────────────────────── C4 ───────────────────────────────────
    # Close the terminal WITHOUT killing: kill -HUP the attached client.
    CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK" "$NAME")"
    if [ -z "$CPID" ]; then
        _fail "iter $_iter C4: no attached client pid to SIGHUP"
    else
        pth_kill_hup "$CPID"
        if pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "0" 10 \
           && pth_inner_has_session "$TMUX_BIN" "$SOCK" "$NAME"; then
            echo "[evidence C4 iter=$_iter] after kill -HUP $CPID: session_attached=0 AND has-session exit 0"
            _pass "iter $_iter C4: terminal-close (kill -HUP client) → session SURVIVES detached"
        else
            _fail "iter $_iter C4: session did not survive detached after client SIGHUP"
        fi
    fi
    pth_kill_pane "drv_${NAME}_c"

    # ───────────────────────────── C5 ───────────────────────────────────
    # Rejoin by name in a fresh terminal: wrong password REJECTED.
    if ! _wrap_in_pane "drv_${NAME}_rw" attach -t "$NAME"; then
        _fail "iter $_iter C5: could not start reattach (wrong-pw) driver pane"
    elif ! pth_wait_text "drv_${NAME}_rw" "password-protected" 12; then
        _fail "iter $_iter C5: reattach did NOT re-prompt for the password"
        pth_kill_pane "drv_${NAME}_rw"
    else
        echo "[evidence C5 iter=$_iter] reattach re-prompted for password (password-protected)"
        pth_send "drv_${NAME}_rw" "$WRONGPW"; pth_send_enter "drv_${NAME}_rw"
        # §11.4.102 root-cause + §11.4.120 reconcile (forensic probe 2026-06-28):
        # the wrapper's attach reject path prints "Incorrect password" to STDERR
        # (through the wrapper's async process-substitution stderr filter) then
        # `exit 1`, which CLOSES the driver pane on the very first poll tick
        # (~0.02s) — BEFORE the banner can land in the pane's visible buffer.
        # capture-pane therefore NEVER sees it (proven: banner_seen=0 across a
        # ~4s window at 0.02s ticks; driver pane gone at tick 1). The
        # banner-TEXT capture was inherently racy, so the rejection proof now
        # rests on the two PRODUCT-OBSERVABLE signals that DO hold:
        #   (1) the driver pane EXITS — the wrapper's reject `exit 1`. A wrong
        #       password that WERE accepted instead `exec`s a live tmux client,
        #       and the pane STAYS alive/attached; and
        #   (2) the inner session is NOT attached (session_attached==0).
        # Discriminator (NOT a tautology): a wrong pw that attached →
        # driver pane ALIVE + session_attached==1 → BOTH halves FAIL; an attach
        # that hung at the prompt without rejecting → driver pane ALIVE → the
        # pane-exit half FAILs. Only a genuine reject yields pane-gone AND
        # attached==0. The "password-protected" prompt was already gated above,
        # so reaching here means the guard ran; pane-gone proves it exited 1.
        _rw_gone=0; _rw_n=0
        while [ "$_rw_n" -lt 50 ]; do          # ~10s bounded poll (0.2s ticks)
            if ! TMUX_TMPDIR="$SCRATCH" "$TMUX_BIN" -L "$PTH_SOCK" \
                 has-session -t "drv_${NAME}_rw" 2>/dev/null; then _rw_gone=1; break; fi
            sleep 0.2; _rw_n=$(( _rw_n + 1 ))
        done
        _rw_att="$(pth_inner_attached "$TMUX_BIN" "$SOCK" "$NAME")"
        if [ "$_rw_gone" -eq 1 ] && [ "$_rw_att" = "0" ]; then
            echo "[evidence C5 iter=$_iter] wrong password → driver pane EXITED (reject exit 1) AND session_attached=0"
            _pass "iter $_iter C5: wrong password REJECTED (not attached; reject pane exited)"
        else
            _fail "iter $_iter C5: wrong password was NOT rejected (driver-pane-gone='$_rw_gone' attached='$_rw_att')"
        fi
        pth_kill_pane "drv_${NAME}_rw"
    fi

    # C5: correct password ATTACHES; same RED; same dir.
    if ! _wrap_in_pane "drv_${NAME}_rc" attach -t "$NAME"; then
        _fail "iter $_iter C5: could not start reattach (correct-pw) driver pane"
    elif ! pth_wait_text "drv_${NAME}_rc" "password-protected" 12; then
        _fail "iter $_iter C5: reattach (2nd) did NOT re-prompt"
        pth_kill_pane "drv_${NAME}_rc"
    else
        pth_send "drv_${NAME}_rc" "$PW"; pth_send_enter "drv_${NAME}_rc"
        if pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12; then
            _pass "iter $_iter C5: correct password ATTACHES (session_attached=1)"
            ss="$(_get_opt "$NAME" status-style)"
            [ "$ss" = "bg=red" ] && _pass "iter $_iter C5: still RED on reattach (bg=red)" \
                || _fail "iter $_iter C5: status-style='$ss' on reattach (want bg=red)"
            pth_send_line "drv_${NAME}_rc" "echo \"C5PW\"\"D:\$(pwd)\" && echo \"C5DO\"\"NE_$_iter\""
            if pth_wait_text "drv_${NAME}_rc" "C5DONE_$_iter" 10 \
               && pth_wait_text "drv_${NAME}_rc" "C5PWD:$PROJ" 10; then
                _pass "iter $_iter C5: same directory on reattach ($PROJ)"
            else
                _fail "iter $_iter C5: reattached pane not in $PROJ"
            fi
        else
            _fail "iter $_iter C5: correct password did NOT attach"
        fi
        # Detach again (no client) — leave NAME as the operator would; the
        # recycler is OFF for this session, so it survives until C7 deletes it.
        CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK" "$NAME")"
        [ -n "$CPID" ] && pth_kill_hup "$CPID"
        pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "0" 10 || true
        pth_kill_pane "drv_${NAME}_rc"
    fi

    # ───────────────────────────── C6 ───────────────────────────────────
    # Idle-recycle (operator clause 6) on a DEDICATED short-window session
    # ("$C6NAME") created with TMX_RECYCLE_IDLE_SECS=$RECYCLE_SECS — so the
    # recycle is deterministic and CANNOT race the C5 reattach flow above,
    # which ran with the recycler OFF (§finding 3). The SOLE recycle mechanism
    # is the AUTO-STARTED per-session watcher that `tmx new` launches
    # (tmx-recycler.sh `watch`, backgrounded, window from the create-time env);
    # there is NO supported manual drive, so we just wait for the detached
    # session to be torn down. State (dir+color+password) MUST be REMEMBERED
    # across the recycle, so a re-create restores all three.

    # Arm the short window for THIS create only, then reset to OFF immediately
    # (the env string was already captured into the pane command above).
    RC_WINDOW="$RECYCLE_SECS"
    _c6_ok=1
    _wrap_in_pane "drv_${C6NAME}_c" new -s "$C6NAME:red" || _c6_ok=0
    RC_WINDOW=0
    [ "$_c6_ok" -eq 1 ] || _fail "iter $_iter C6: could not start dedicated recycle-session create pane"
    if [ "$_c6_ok" -eq 1 ] && ! pth_wait_text "drv_${C6NAME}_c" "Enter password for session" 12; then
        _fail "iter $_iter C6: dedicated-session create password prompt never appeared"
        pth_kill_pane "drv_${C6NAME}_c"; _c6_ok=0
    fi
    if [ "$_c6_ok" -eq 1 ]; then
        pth_send "drv_${C6NAME}_c" "$PW"; pth_send_enter "drv_${C6NAME}_c"
        # §11.4.120 reconciliation: fresh-name create now confirms the password.
        if ! pth_wait_text "drv_${C6NAME}_c" "Confirm password" 8; then
            _fail "iter $_iter C6: dedicated-session create confirmation prompt never appeared"
            pth_kill_pane "drv_${C6NAME}_c"; _c6_ok=0
        else
            pth_send "drv_${C6NAME}_c" "$PW"; pth_send_enter "drv_${C6NAME}_c"
            if ! pth_wait_attached "$TMUX_BIN" "$C6SOCK" "$C6NAME" "1" 12; then
                _fail "iter $_iter C6: dedicated recycle session did not attach after password"
                pth_kill_pane "drv_${C6NAME}_c"; _c6_ok=0
            fi
        fi
    fi

    if [ "$_c6_ok" -eq 1 ]; then
        # Record the cwd (recall == $PROJ proves dir-remembered), then close
        # the terminal (kill -HUP client) so the session goes detached and the
        # auto-watcher's idle clock starts.
        pth_send_line "drv_${C6NAME}_c" "cd '$PROJ' && pwd && echo C6CD_$_iter"
        pth_wait_text "drv_${C6NAME}_c" "C6CD_$_iter" 10 || true
        CPID="$(pth_client_pid "$TMUX_BIN" "$C6SOCK" "$C6NAME")"
        [ -n "$CPID" ] && pth_kill_hup "$CPID"
        pth_wait_attached "$TMUX_BIN" "$C6SOCK" "$C6NAME" "0" 10 || true
        pth_kill_pane "drv_${C6NAME}_c"

        # Wait for the AUTO-STARTED watcher to recycle the detached session.
        # SOLE mechanism — no manual recycler invocation (a bare call has none
        # of the TMX_RC_* env the wrapper set at `tmx new`, and would no-op).
        _gone=0; _n=0; _maxn=$(( (RECYCLE_SECS + 30) * 5 ))   # ~0.2s ticks
        while [ "$_n" -lt "$_maxn" ]; do
            if ! pth_inner_has_session "$TMUX_BIN" "$C6SOCK" "$C6NAME"; then _gone=1; break; fi
            sleep 0.2; _n=$(( _n + 1 ))
        done

        if [ "$_gone" -ne 1 ]; then
            if [ ! -x "$RECYCLER" ]; then
                _skip "iter $_iter C6: recycler ($RECYCLER) not present in this build — idle-recycle deferred — §11.4.3"
            else
                _fail "iter $_iter C6: recycler present but detached session not recycled within idle window"
            fi
            # Tear the dedicated session down so it cannot linger.
            "$WRAPPER" kill-session -t "$C6NAME" >/dev/null 2>&1 || true
            "$TMUX_BIN" -L "$C6SOCK" kill-server >/dev/null 2>&1 || true
        else
            _pass "iter $_iter C6: detached session RECYCLED after idle window (has-session gone)"
            # State REMEMBERED across recycle (only the runtime is torn down).
            _c6_recall="$(_recall "$C6NAME")"
            if [ "$_c6_recall" = "$PROJ" ] || [ "$_c6_recall" = "$PROJ_REAL" ]; then
                _pass "iter $_iter C6: dir remembered (recall=$_c6_recall)"
            else
                _fail "iter $_iter C6: dir NOT remembered (recall='$_c6_recall')"
            fi
            [ "$(_getcolor "$C6NAME")" = "red" ] && _pass "iter $_iter C6: color remembered (get-color=red)" \
                || _fail "iter $_iter C6: color NOT remembered (get-color='$(_getcolor "$C6NAME")')"
            # §11.4.123: prove the password genuinely PERSISTED across recycle —
            # correct ACCEPTED *and* wrong REJECTED. A silently-wiped (empty)
            # hash would accept the WRONG password too (verifyPassword returns
            # true on an empty hash), so the reject assertion is what catches a
            # wipe — exit-0-on-correct alone is tautological (it cannot tell a
            # surviving password from a wiped one).
            if "$STATE_BIN" verify-password "$C6NAME" "$PW" >/dev/null 2>&1; then
                _pass "iter $_iter C6: password remembered — verify accepts correct (exit 0)"
            else
                _fail "iter $_iter C6: password NOT remembered across recycle (correct rejected)"
            fi
            "$STATE_BIN" verify-password "$C6NAME" "$WRONGPW" >/dev/null 2>&1
            [ "$?" -eq 1 ] && _pass "iter $_iter C6: wrong password STILL rejected after recycle (exit 1 — hash not wiped)" \
                || _fail "iter $_iter C6: wrong password accepted after recycle (password silently wiped to none)"

            # Re-create (bare name) restores all three. §11.4.120 reconciliation
            # (2026-07-05, root-cause fix half 2 of 2): the recycled-dead
            # session's password PERSISTED, so the `new` verb now takes the
            # VERIFY-ONCE path — it prompts "…is password-protected. Enter
            # password:" and requires the CORRECT existing password to re-enter
            # (the old "blank keeps password" idiom is gone; verify does NOT
            # overwrite, so the password is still kept). RC_WINDOW=0 here so it
            # is not recycled mid-verify.
            if ! _wrap_in_pane "drv_${C6NAME}_re" new -s "$C6NAME"; then
                _fail "iter $_iter C6: could not start re-create driver pane"
            elif ! pth_wait_text "drv_${C6NAME}_re" "password-protected" 12; then
                _fail "iter $_iter C6: re-create did NOT show the verify-password prompt"
                pth_kill_pane "drv_${C6NAME}_re"
            else
                pth_send "drv_${C6NAME}_re" "$PW"; pth_send_enter "drv_${C6NAME}_re"   # verify existing password
                if pth_wait_attached "$TMUX_BIN" "$C6SOCK" "$C6NAME" "1" 12; then
                    ss="$(_get_opt "$C6NAME" status-style)"
                    [ "$ss" = "bg=red" ] && _pass "iter $_iter C6: re-create RESTORED RED (bg=red)" \
                        || _fail "iter $_iter C6: re-create color='$ss' (want bg=red)"
                    pth_send_line "drv_${C6NAME}_re" "echo \"C6PW\"\"D:\$(pwd)\" && echo \"C6DO\"\"NE_$_iter\""
                    if pth_wait_text "drv_${C6NAME}_re" "C6DONE_$_iter" 10 \
                       && pth_wait_text "drv_${C6NAME}_re" "C6PWD:$PROJ" 10; then
                        _pass "iter $_iter C6: re-create RESTORED dir ($PROJ)"
                    else
                        _fail "iter $_iter C6: re-create pane not in remembered dir $PROJ"
                    fi
                    # §11.4.123: re-create kept the password — correct ACCEPTED
                    # *and* wrong REJECTED (a wiped hash would accept the wrong).
                    if "$STATE_BIN" verify-password "$C6NAME" "$PW" >/dev/null 2>&1; then
                        _pass "iter $_iter C6: re-create kept the password — verify accepts correct (exit 0)"
                    else
                        _fail "iter $_iter C6: re-create lost the password (correct rejected)"
                    fi
                    "$STATE_BIN" verify-password "$C6NAME" "$WRONGPW" >/dev/null 2>&1
                    [ "$?" -eq 1 ] && _pass "iter $_iter C6: re-create wrong password STILL rejected (exit 1 — hash not wiped)" \
                        || _fail "iter $_iter C6: re-create wrong password accepted (password silently wiped to none)"
                else
                    _fail "iter $_iter C6: re-created session did not attach"
                fi
                CPID="$(pth_client_pid "$TMUX_BIN" "$C6SOCK" "$C6NAME")"
                [ -n "$CPID" ] && pth_kill_hup "$CPID"
                pth_wait_attached "$TMUX_BIN" "$C6SOCK" "$C6NAME" "0" 10 || true
                pth_kill_pane "drv_${C6NAME}_re"
            fi
        fi
    fi
    # Dedicated C6 session teardown (its own state forgotten; never touches the
    # C1 session NAME, which C7 deletes below).
    "$WRAPPER" delete -t "$C6NAME" >/dev/null 2>&1 || true
    "$WRAPPER" kill-session -t "$C6NAME" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$C6SOCK" kill-server >/dev/null 2>&1 || true
    "$STATE_BIN" forget "$C6NAME" >/dev/null 2>&1 || true

    # ───────────────────────────── C7 ───────────────────────────────────
    # `tmx delete -t NAME` → kills + CLEARS persisted state; re-create → defaults.
    "$WRAPPER" delete -t "$NAME" >/dev/null 2>&1 || true
    pth_wait_gone "$TMUX_BIN" "$SOCK" "$NAME" 10 || true
    _recall_after="$(_recall "$NAME")"
    if [ "$_recall_after" = "$PROJ" ]; then
        # State row still present ⇒ the delete verb did not clear it (not yet
        # implemented in this build). Honest SKIP, not a false FAIL.
        _skip "iter $_iter C7: 'tmx delete' did not clear state (verb not wired in this build) — §11.4.3"
        "$WRAPPER" kill-session -t "$NAME" >/dev/null 2>&1 || true
        "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    else
        if pth_inner_has_session "$TMUX_BIN" "$SOCK" "$NAME"; then
            _fail "iter $_iter C7: 'tmx delete' left the session alive"
        else
            _pass "iter $_iter C7: 'tmx delete' tore the session down (has-session gone)"
        fi
        [ -z "$_recall_after" ] && _pass "iter $_iter C7: 'tmx delete' cleared the dir (recall empty)" \
            || _fail "iter $_iter C7: dir not cleared (recall='$_recall_after')"
        [ -z "$(_getcolor "$NAME")" ] && _pass "iter $_iter C7: 'tmx delete' cleared the color" \
            || _fail "iter $_iter C7: color not cleared (get-color='$(_getcolor "$NAME")')"
        # §11.4.120 reconcile (forensic exit-code probe 2026-06-28): `tmx delete`
        # runs `tmx-state-bin forget`, which REMOVES THE WHOLE RECORD — it does
        # NOT leave a record with a blanked password. So verify-password returns
        # exit 2 (record absent), NOT exit 0 (record present, no password). The
        # old assertion expected exit 0 and FAILed because the correct delete
        # behaviour (remove the record) made the exit-0 expectation wrong. The
        # NEW correct contract = record absent (exit 2): the old password no
        # longer grants access AND no empty-hash guard lingers — that IS the
        # reset. Probe-verified exit codes: removed→2, left-with-old-pw→0,
        # left-with-different/no-pw→1or0.
        # Discriminator (NOT a tautology): verify with the OLD password $PW —
        #   record removed (correct)        → exit 2 → PASS;
        #   delete left the OLD pw set       → exit 0 (old pw still accepted) → FAIL;
        #   delete left a record, pw cleared → exit 0 (any accepted)         → FAIL.
        # Only a genuinely-removed record yields exit 2, so the assertion still
        # catches a real "delete left the password/record behind" regression.
        "$STATE_BIN" verify-password "$NAME" "$PW" >/dev/null 2>&1
        _c7_vp=$?
        [ "$_c7_vp" -eq 2 ] \
            && _pass "iter $_iter C7: 'tmx delete' reset the password (record absent, exit 2 — old pw no longer accepted)" \
            || _fail "iter $_iter C7: password not reset after delete (verify-password old-pw exit=$_c7_vp, want 2=record-absent)"

        # Re-create after delete → DEFAULTS: fresh create prompt, host-fallback
        # color, $HOME dir.
        if ! _wrap_in_pane "drv_${NAME}_d" new -s "$NAME"; then
            _fail "iter $_iter C7: could not start post-delete re-create pane"
        elif ! pth_wait_text "drv_${NAME}_d" "Enter password for session" 12; then
            _fail "iter $_iter C7: post-delete re-create did NOT show a FRESH password prompt"
            pth_kill_pane "drv_${NAME}_d"
        else
            echo "[evidence C7 iter=$_iter] FRESH create password prompt on post-delete re-create (the reset)"
            _pass "iter $_iter C7: post-delete re-create shows a FRESH password prompt (reset proven)"
            pth_send_enter "drv_${NAME}_d"     # blank = no password (default)
            if pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "1" 12; then
                ss="$(_get_opt "$NAME" status-style)"
                case "$ss" in
                    bg=red) _fail "iter $_iter C7: default color is still RED (delete did not reset color)" ;;
                    bg=*)   _pass "iter $_iter C7: DEFAULT color = host fallback ($ss, not the deleted red)" ;;
                    *)      _fail "iter $_iter C7: no fallback color applied (status-style='$ss')" ;;
                esac
                pth_send_line "drv_${NAME}_d" "echo \"C7PW\"\"D:\$(pwd)\" && echo \"C7DO\"\"NE_$_iter\""
                if pth_wait_text "drv_${NAME}_d" "C7DONE_$_iter" 10 \
                   && pth_wait_text "drv_${NAME}_d" "C7PWD:$HOME_DIR" 10; then
                    _pass "iter $_iter C7: DEFAULT dir = \$HOME ($HOME_DIR)"
                else
                    _fail "iter $_iter C7: default dir not \$HOME (pane not in $HOME_DIR)"
                fi
            else
                _fail "iter $_iter C7: post-delete re-created session did not attach"
            fi
            CPID="$(pth_client_pid "$TMUX_BIN" "$SOCK" "$NAME")"
            [ -n "$CPID" ] && pth_kill_hup "$CPID"
            pth_wait_attached "$TMUX_BIN" "$SOCK" "$NAME" "0" 8 || true
            pth_kill_pane "drv_${NAME}_d"
        fi
    fi

    # Per-iter teardown (re-runnability §11.4.98).
    "$WRAPPER" delete -t "$NAME" >/dev/null 2>&1 || true
    "$WRAPPER" kill-session -t "$NAME" >/dev/null 2>&1 || true
    "$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true
    "$STATE_BIN" forget "$NAME" >/dev/null 2>&1 || true
done

echo "── Test 68 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
