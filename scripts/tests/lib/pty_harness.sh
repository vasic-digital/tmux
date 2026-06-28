#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# pty_harness.sh — reusable PTY-driving primitives for tmx session-lifecycle
#                  full-automation tests (test 68 + future lifecycle tests).
#
# Purpose:    The tmx wrapper reads the per-session password from /dev/tty
#             (scripts/tmx.template:499 create, :551 attach), NOT stdin —
#             precisely so a redirected `printf pw | tmx new` / heredoc
#             CANNOT drive it (the program checks "is a human present" via
#             the controlling terminal). The ONLY portable way to drive such
#             a prompt fully-autonomously is to give the wrapper a REAL
#             controlling PTY. This library does that two ways:
#               (1) `tmux send-keys` into a throwaway DRIVER pane that runs
#                   the wrapper — the pane IS a PTY, so the wrapper's
#                   /dev/tty read succeeds. Wait-for-prompt-TEXT via
#                   `capture-pane` polling (NEVER a blind sleep — §11.4.50:
#                   the prompt text is the gate, the 0.2s tick is only poll
#                   granularity, matching the established pattern in
#                   tests 44/45/46/17).
#               (2) a real foreground PTY client spawned via python3
#                   `pty.fork()` so the test can `kill -HUP <client-pid>`
#                   to simulate the operator CLOSING THE TERMINAL while the
#                   detached session/server SURVIVES (research §2.3 +
#                   tmux issue #1174).
#
# Usage:      Source it from a test, set the three required vars, call:
#               PTH_TMUX=<tmux binary to drive the OUTER driver server>
#               PTH_SOCK=<unique driver socket label, e.g. tmxlife-driver-$$>
#               PTH_TMPDIR=<writable scratch dir (TMUX_TMPDIR for the driver)>
#             then use pth_run_pane / pth_wait_text / pth_send / pth_send_enter
#             / pth_client_pid / pth_spawn_pty_client / pth_kill_hup /
#             pth_kill_pane / pth_driver_kill.
#             Standalone self-test:  bash lib/pty_harness.sh --selftest
#
# Inputs:     PTH_TMUX, PTH_SOCK, PTH_TMPDIR (env/caller vars). Each function
#             takes explicit positional args (no hidden globals beyond these).
# Outputs:    Functions return shell exit codes; the self-test prints
#             PASS/FAIL/SKIP lines + an EVIDENCE trail.
# Side-effects: creates/kills DRIVER tmux sessions on PTH_SOCK only; writes a
#             tiny pty_client.py helper into PTH_TMPDIR; spawns/reaps python3
#             PTY children. NEVER touches the operator's default tmux socket.
# Dependencies: a tmux binary (PTH_TMUX), python3 (for pth_spawn_pty_client /
#             kill-HUP only — wait/send/has-session work without it).
# Cross-refs: scripts/tests/68_session_lifecycle.sh (sole consumer today);
#             scripts/tmx.template (/dev/tty password prompts);
#             scratchpad scenario_lifecycle_research.md ANGLE 2 / §2.3 / §2.5.
# §11.4.50:  every wait is a bounded poll on a real CONDITION (prompt text /
#             attached-count / has-session), never a fixed sleep substituting
#             for the event. §11.4.67: POSIX `sh -n` clean AND `bash -n`
#             clean (no process-substitution, no arrays, no `${x^^}`,
#             bash-3.2-safe for macOS). §11.4.14: callers trap-cleanup.
# Last verified: 2026-06-28
# ─────────────────────────────────────────────────────────────────────────

# Poll granularity (seconds) — the inter-poll tick, NOT the wait itself. The
# CONDITION each poller checks (prompt text present / client attached / session
# gone) is the actual gate; the tick only bounds CPU spin. Matches the 0.2-0.3s
# ticks already used in tests 44/45/46/17.
PTH_TICK="${PTH_TICK:-0.2}"

# pth_require — verify the three required caller vars are set + the driver
# binary is executable. Returns 0 if usable, 1 otherwise (caller SKIPs).
pth_require() {
    if [ -z "${PTH_TMUX:-}" ] || [ ! -x "${PTH_TMUX:-/nonexistent}" ]; then
        echo "pth: PTH_TMUX unset or not executable" >&2; return 1
    fi
    if [ -z "${PTH_SOCK:-}" ]; then echo "pth: PTH_SOCK unset" >&2; return 1; fi
    if [ -z "${PTH_TMPDIR:-}" ] || [ ! -d "${PTH_TMPDIR:-/nonexistent}" ]; then
        echo "pth: PTH_TMPDIR unset or not a directory" >&2; return 1
    fi
    return 0
}

# pth_run_pane SESS CMD
#   Create a DETACHED driver session SESS (on PTH_SOCK) whose single pane runs
#   CMD. The pane is a real PTY, so a child inside CMD that reads /dev/tty (the
#   tmx password prompt) works. CMD is a shell command STRING evaluated by the
#   pane's shell. Returns the new-session exit code.
pth_run_pane() {
    _pth_sess="$1"; shift
    _pth_cmd="$*"
    # §11.4.111: drive the throwaway DRIVER server under a TERM that HAS a
    # terminfo entry on THIS host. tmux sets each pane's TERM from the server's
    # `default-terminal`; the compiled default may be ABSENT on minimal hosts
    # (e.g. tmux-256color with no such terminfo entry), which would make any
    # child that validates $TERM on its own PTY — precisely the tmx-managed
    # inner tmux — refuse to start ("missing or unsuitable terminal"). Pin the
    # first terminfo-PRESENT candidate as the driver's default-terminal via a
    # one-shot conf loaded at server start. `-f` only takes effect when the
    # server FIRST boots, so the first pth_run_pane sets it for every later
    # driver pane on the same socket; the conf is written once. bash-3.2-safe.
    _pth_dconf="$PTH_TMPDIR/pth_driver.conf"
    if [ ! -f "$_pth_dconf" ]; then
        _pth_dterm=""
        if command -v infocmp >/dev/null 2>&1; then
            for _pth_t in "${TERM:-}" screen-256color xterm-256color screen xterm; do
                [ -n "$_pth_t" ] || continue
                if infocmp "$_pth_t" >/dev/null 2>&1; then _pth_dterm="$_pth_t"; break; fi
            done
        fi
        [ -n "$_pth_dterm" ] || _pth_dterm="screen-256color"
        printf 'set -g default-terminal "%s"\n' "$_pth_dterm" > "$_pth_dconf" 2>/dev/null || _pth_dconf=""
    fi
    if [ -n "$_pth_dconf" ] && [ -f "$_pth_dconf" ]; then
        TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -f "$_pth_dconf" -L "$PTH_SOCK" \
            new-session -d -s "$_pth_sess" -x 200 -y 50 "$_pth_cmd"
    else
        TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
            new-session -d -s "$_pth_sess" -x 200 -y 50 "$_pth_cmd"
    fi
}

# pth_capture SESS  — print the driver pane's visible text (best-effort).
pth_capture() {
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        capture-pane -p -t "$1" 2>/dev/null || true
}

# pth_wait_text SESS NEEDLE TIMEOUT_SECS
#   Bounded poll of capture-pane until NEEDLE (fixed string) appears on the
#   driver pane. 0 = seen, 1 = timed out. The NEEDLE is the gate (§11.4.50).
pth_wait_text() {
    _pth_sess="$1"; _pth_needle="$2"; _pth_to="${3:-10}"
    _pth_ticks=$(awk "BEGIN{printf \"%d\", ($_pth_to/$PTH_TICK)+1}" 2>/dev/null || echo 50)
    _pth_n=0
    while [ "$_pth_n" -lt "$_pth_ticks" ]; do
        if pth_capture "$_pth_sess" | grep -qF "$_pth_needle"; then
            return 0
        fi
        sleep "$PTH_TICK"
        _pth_n=$(( _pth_n + 1 ))
    done
    return 1
}

# pth_send SESS WORD...  — send literal key WORDs into SESS's pane (one
#   send-keys per call; words are passed verbatim, e.g. a password string).
pth_send() {
    _pth_sess="$1"; shift
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        send-keys -t "$_pth_sess" "$@" 2>/dev/null
}

# pth_send_enter SESS  — send a carriage return (submits the prompt / shell line).
pth_send_enter() {
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        send-keys -t "$1" Enter 2>/dev/null
}

# pth_send_line SESS TEXT  — type TEXT then Enter (a full shell line).
pth_send_line() {
    _pth_sess="$1"; _pth_text="$2"
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        send-keys -t "$_pth_sess" "$_pth_text" Enter 2>/dev/null
}

# pth_kill_pane SESS  — kill a driver session (one pane).
pth_kill_pane() {
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        kill-session -t "$1" 2>/dev/null || true
}

# pth_driver_kill  — kill the whole driver server (all driver panes + socket).
pth_driver_kill() {
    TMUX_TMPDIR="$PTH_TMPDIR" "$PTH_TMUX" -L "$PTH_SOCK" \
        kill-server 2>/dev/null || true
}

# ── Inner-session (the tmx-managed server under test) introspection ──────
# These target a SEPARATE socket (the inner per-session socket the wrapper
# creates, e.g. tmx-<NAME>) using the INNER tmux binary (caller supplies it
# as $1). They are how the test asserts survival across a client kill.
# CONTRACT: these helpers INHERIT TMUX_TMPDIR from the environment — the
# caller MUST `export TMUX_TMPDIR` to the SAME value the inner tmx server runs
# under (the wrapper inherits the test's TMUX_TMPDIR at create time), so the
# socket path resolves identically on both sides. Mismatched TMUX_TMPDIR makes
# every inner call look on the wrong socket dir and falsely report "gone".

# pth_inner_has_session INNER_TMUX INNER_SOCK NAME  — exit 0 iff alive.
pth_inner_has_session() {
    "$1" -L "$2" has-session -t "$3" 2>/dev/null
}

# pth_inner_attached INNER_TMUX INNER_SOCK NAME  — print #{session_attached}
#   (client count; 0 = detached). Empty if the session/server is gone.
pth_inner_attached() {
    "$1" -L "$2" display-message -p -t "$3" '#{session_attached}' 2>/dev/null
}

# pth_client_pid INNER_TMUX INNER_SOCK NAME  — print the FIRST attached
#   client's pid (the `tmux attach` process to SIGHUP for a terminal-close
#   sim). Empty if no client. (research §2.3 + arkku `lsc -F '#{client_pid}'`)
pth_client_pid() {
    "$1" -L "$2" list-clients -t "$3" -F '#{client_pid}' 2>/dev/null | head -n1
}

# pth_wait_attached INNER_TMUX INNER_SOCK NAME WANT TIMEOUT
#   Poll until #{session_attached} == WANT (e.g. 1 after a client attaches,
#   0 after kill-HUP). 0 = reached, 1 = timeout. The count is the gate.
pth_wait_attached() {
    _pi_tmux="$1"; _pi_sock="$2"; _pi_name="$3"; _pi_want="$4"; _pi_to="${5:-10}"
    _pi_ticks=$(awk "BEGIN{printf \"%d\", ($_pi_to/$PTH_TICK)+1}" 2>/dev/null || echo 50)
    _pi_n=0
    while [ "$_pi_n" -lt "$_pi_ticks" ]; do
        _pi_cur="$(pth_inner_attached "$_pi_tmux" "$_pi_sock" "$_pi_name")"
        if [ "$_pi_cur" = "$_pi_want" ]; then return 0; fi
        sleep "$PTH_TICK"
        _pi_n=$(( _pi_n + 1 ))
    done
    return 1
}

# pth_wait_gone INNER_TMUX INNER_SOCK NAME TIMEOUT
#   Poll until has-session reports the session is GONE (recycled/deleted).
#   0 = gone within TIMEOUT, 1 = still alive at timeout. (clause 6/7 gate.)
pth_wait_gone() {
    _pg_tmux="$1"; _pg_sock="$2"; _pg_name="$3"; _pg_to="${4:-30}"
    _pg_ticks=$(awk "BEGIN{printf \"%d\", ($_pg_to/$PTH_TICK)+1}" 2>/dev/null || echo 150)
    _pg_n=0
    while [ "$_pg_n" -lt "$_pg_ticks" ]; do
        if ! pth_inner_has_session "$_pg_tmux" "$_pg_sock" "$_pg_name"; then
            return 0
        fi
        sleep "$PTH_TICK"
        _pg_n=$(( _pg_n + 1 ))
    done
    return 1
}

# ── Real foreground PTY client (for the kill-HUP terminal-close sim) ──────
# pth_spawn_pty_client OUTVAR CMD...
#   Spawn CMD under a REAL controlling PTY (python3 pty.fork), backgrounded.
#   Sets the named OUTVAR to the python WRAPPER pid (for cleanup). The actual
#   client process the test SIGHUPs is the tmux client, obtained separately
#   via pth_client_pid (more robust than guessing the child pid). When the
#   client dies the wrapper EOFs and exits on its own. Requires python3.
pth_have_python() { command -v python3 >/dev/null 2>&1; }

pth_spawn_pty_client() {
    _pc_out="$1"; shift
    _pc_py="$PTH_TMPDIR/pth_pty_client.py"
    if [ ! -f "$_pc_py" ]; then
        cat > "$_pc_py" <<'PY'
import os, pty, select, sys
argv = sys.argv[1:]
if not argv:
    sys.exit(2)
pid, fd = pty.fork()
if pid == 0:
    # Child: gets a controlling PTY, becomes the foreground client.
    try:
        os.execvp(argv[0], argv)
    except Exception:
        os._exit(127)
# Parent: drain the master until the child (client) exits / the PTY EOFs.
# When the test kill-HUPs the tmux client, the client dies -> EOF here -> exit.
while True:
    try:
        r, _, _ = select.select([fd], [], [], 0.5)
    except Exception:
        break
    if fd in r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
    wpid, _ = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        break
try:
    os.close(fd)
except OSError:
    pass
PY
    fi
    python3 "$_pc_py" "$@" >/dev/null 2>&1 &
    eval "$_pc_out=$!"
}

# pth_kill_hup PID  — SIGHUP a pid (the terminal-close signal). Best-effort.
pth_kill_hup() {
    [ -n "${1:-}" ] && kill -HUP "$1" 2>/dev/null || true
}

# ═════════════════════════════════════════════════════════════════════════
# SELF-TEST — proves the harness MECHANISM in isolation WITHOUT the project
# binary: uses the SYSTEM (or any) tmux + a trivial `read </dev/tty` probe
# that mimics the wrapper's password read. Demonstrates send-keys drives a
# /dev/tty prompt through a pane PTY, wait-for-prompt-text works, and
# kill-HUP detaches a real PTY client while has-session SURVIVES. Run:
#   bash scripts/tests/lib/pty_harness.sh --selftest
# ═════════════════════════════════════════════════════════════════════════
_pth_selftest() {
    set -uo pipefail
    PASS=0; FAIL=0; SKIP=0
    _p() { echo "PASS: $*"; PASS=$((PASS+1)); }
    _f() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
    _s() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

    echo "── pty_harness self-test (mechanism proof, system tmux + /dev/tty probe) ──"

    _bin="$(command -v tmux 2>/dev/null || true)"
    if [ -z "$_bin" ]; then _s "no tmux on PATH — mechanism unprovable here §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; return 0; fi

    SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}/pth_selftest.$$"
    if ! mkdir -p "$SCRATCH" 2>/dev/null || [ ! -w "$SCRATCH" ]; then
        _s "scratch $SCRATCH not writable §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; return 0
    fi

    export PTH_TMUX="$_bin"
    export PTH_SOCK="pthself-$$"
    export PTH_TMPDIR="$SCRATCH"
    # Single source of truth for the tmux runtime dir so the un-prefixed inner
    # introspection helpers resolve the SAME socket dir as the driver calls.
    export TMUX_TMPDIR="$SCRATCH"
    # Inner probe server uses its OWN socket so kill-HUP of its client cannot
    # affect the driver, exactly like the real tmx per-session socket model.
    INNER_SOCK="pthself-inner-$$"
    PYPID=""

    _cleanup() {
        pth_driver_kill
        TMUX_TMPDIR="$SCRATCH" "$_bin" -L "$INNER_SOCK" kill-server >/dev/null 2>&1 || true
        [ -n "$PYPID" ] && kill "$PYPID" >/dev/null 2>&1 || true
        rm -rf "$SCRATCH" 2>/dev/null || true
    }
    trap _cleanup EXIT

    # ── M1: send-keys drives a /dev/tty prompt through a pane PTY ──────────
    # A probe that mimics the wrapper: print a prompt to /dev/tty, read the
    # reply from /dev/tty, write it to a result file. If pipes/heredocs could
    # drive it we would not need a PTY — this proves the PTY path. Written to
    # a FILE (not an inline -c string) so deep quote-nesting cannot corrupt it.
    RESULT="$SCRATCH/probe_result"
    rm -f "$RESULT"
    cat > "$SCRATCH/probe.sh" <<'PROBESH'
#!/bin/sh
printf '[probe] Enter password: ' >/dev/tty
IFS= read -r p </dev/tty
printf '%s' "$p" > "$RESULT_FILE"
printf '[probe] done\n' >/dev/tty
sleep 5
PROBESH
    if ! pth_run_pane "m1" "RESULT_FILE='$RESULT' sh '$SCRATCH/probe.sh'"; then
        _f "M1 could not create driver pane"
    elif ! pth_wait_text "m1" "Enter password:" 8; then
        _f "M1 prompt text never appeared in pane (wait-for-prompt broken)"
    else
        echo "[evidence M1] prompt text observed via capture-pane; sending password via send-keys"
        pth_send "m1" "harness_secret_42"
        pth_send_enter "m1"
        # Gate: the result file carries EXACTLY what we sent → send-keys drove
        # the /dev/tty read. Bounded poll on the file (the condition).
        _ok=0; _n=0
        while [ "$_n" -lt 40 ]; do
            if [ -s "$RESULT" ]; then _ok=1; break; fi
            sleep 0.2; _n=$((_n+1))
        done
        if [ "$_ok" -eq 1 ] && [ "$(cat "$RESULT" 2>/dev/null)" = "harness_secret_42" ]; then
            echo "[evidence M1] /dev/tty captured exactly 'harness_secret_42' (file=$RESULT)"
            _p "M1 send-keys drove a /dev/tty prompt through a pane PTY (the tmx password mechanism)"
        else
            _f "M1 /dev/tty read did not capture the sent password (got: '$(cat "$RESULT" 2>/dev/null)')"
        fi
    fi
    pth_kill_pane "m1"

    # ── M2: kill-HUP a real PTY client → session SURVIVES detached ────────
    if ! pth_have_python; then
        _s "M2 python3 absent — kill-HUP PTY client mechanism unprovable §11.4.3"
    else
        TMUX_TMPDIR="$SCRATCH" "$_bin" -L "$INNER_SOCK" new-session -d -s probe -x 200 -y 50 2>/dev/null || true
        if ! pth_inner_has_session "$_bin" "$INNER_SOCK" "probe"; then
            _f "M2 could not create inner probe session"
        else
            pth_spawn_pty_client PYPID "$_bin" "-L" "$INNER_SOCK" "attach" "-t" "probe"
            if ! pth_wait_attached "$_bin" "$INNER_SOCK" "probe" "1" 8; then
                _f "M2 PTY client never attached (session_attached stayed 0)"
            else
                CPID="$(pth_client_pid "$_bin" "$INNER_SOCK" "probe")"
                echo "[evidence M2] client attached (session_attached=1); client_pid=$CPID"
                pth_kill_hup "$CPID"
                if pth_wait_attached "$_bin" "$INNER_SOCK" "probe" "0" 8 \
                   && pth_inner_has_session "$_bin" "$INNER_SOCK" "probe"; then
                    echo "[evidence M2] after kill -HUP $CPID: session_attached=0 AND has-session exit 0 (server SURVIVES)"
                    _p "M2 kill-HUP <client-pid> detached the client; session/server SURVIVED (terminal-close sim)"
                else
                    _f "M2 after kill-HUP: session did not become detached-but-alive (attached='$(pth_inner_attached "$_bin" "$INNER_SOCK" "probe")')"
                fi
            fi
        fi
    fi

    echo "── pty_harness self-test: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    [ "$FAIL" -eq 0 ]
}

# Run the self-test only when executed directly with --selftest (never when
# sourced by a test). bash-3.2 provides BASH_SOURCE.
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
    case "${1:-}" in
        --selftest) _pth_selftest; exit $? ;;
        *) echo "pty_harness.sh is a library; run with --selftest to prove the mechanism." >&2; exit 0 ;;
    esac
fi
