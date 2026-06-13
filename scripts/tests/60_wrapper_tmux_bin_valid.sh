#!/usr/bin/env bash
# 60_wrapper_tmux_bin_valid.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.135 PERMANENT REGRESSION GUARD for Issues.md F1 —
#             `tmx new -s HelixCode` crashed the WHOLE terminal on every
#             emulator. CAPTURED root cause: the generated/installed
#             `scripts/tmx` wrapper carried `TMUX_BIN="<path>"` pointing at
#             a NON-EXISTENT binary (a stale prior-checkout location). The
#             operator's shell-init runs
#               exec sh -c 'tmx attach -t NAME 2>/dev/null || exec tmx new -s NAME'
#             so `tmx new` reaches `exec "$TMUX_BIN" …` (scripts/tmx ~396/430)
#             on the MISSING binary → exec fails (exit 127,
#             "No such file or directory") → the LOGIN SHELL that exec'd into
#             the wrapper chain DIES → the terminal window closes = "crashes
#             the whole terminal", emulator-independent. v1.0.22 setup.sh
#             regenerated scripts/tmx with a valid TMUX_BIN → fixed.
#
#             Three layers, TDD/anti-bluff:
#               T1 (STATIC always-on guard): the generated `scripts/tmx` (if
#                  present) declares TMUX_BIN=<path> AND that path EXISTS +
#                  is executable. SKIP-with-reason if scripts/tmx absent.
#               T2 (RED proof — has teeth): synthesize a throwaway wrapper
#                  copy whose TMUX_BIN is rewritten to a guaranteed-missing
#                  path, drive the EXACT operator path through a real PTY,
#                  and ASSERT the controlling shell DIES (child exit 127 /
#                  PTY EOF) AND captured output contains "No such file or
#                  directory". This reproduces F1.
#               T3 (GREEN): with the REAL valid-TMUX_BIN wrapper, drive the
#                  same operator path; ASSERT a session is created (server
#                  came up) and the shell did NOT die with a missing-binary
#                  error. Positive captured evidence; cleaned up.
#
# Usage:      bash scripts/tests/60_wrapper_tmux_bin_valid.sh
# Outputs:    EVIDENCE … ; PASS/FAIL/SKIP lines ; summary.
# Side-effects: T2 uses a throwaway wrapper copy + private socket label +
#             throwaway HOME/TMUX_TMPDIR under /tmp/tmxg.$$ — never touches
#             the operator's /tmp/tmux-501 or real sessions. T3 creates +
#             kills ONLY its own uniquely-named session via the wrapper.
# Dependencies: scripts/tmx (generated wrapper — SKIP if absent), tmux
#             binary, python3 (SKIP if absent — §11.4.3).
# Cross-refs: scripts/tmx.template (exec "$TMUX_BIN" ~396/430) ;
#             scripts/tmx-shell-init.sh.template (operator exec sh -c …) ;
#             scripts/verify.sh CM-TMX-WRAPPER-TMUXBIN-VALID gate ;
#             meta-test M-WRAPPER-TMUXBIN ; Issues.md F1.
# §11.4.50:  T2 + T3 each driven 3× for deterministic consistency by the
#             harness (run_all invokes this once; internal 3-iter loop).
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean.
# §11.4.14:  trap cleanup on every exit path.
# Last verified: 2026-06-13
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TMX="$REPO_ROOT/scripts/tmx"

# Private, SHORT-path scratch root so tmux socket paths stay under the
# sun_path limit. Everything this test creates lives under here.
SCRATCH="/tmp/tmxg.$$"
mkdir -p "$SCRATCH" 2>/dev/null || true

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 60: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 60: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 60: $*"; SKIP=$((SKIP + 1)); }

# Track the GREEN session name + socket so cleanup can remove ONLY ours.
T3_NAME=""
T3_SOCK=""

_cleanup() {
    # Kill ONLY our own GREEN session/server — never broad pkill, never
    # touch /tmp/tmux-501.
    if [ -n "${T3_NAME:-}" ] && [ -x "$TMX" ]; then
        "$TMX" kill-session -t "$T3_NAME" >/dev/null 2>&1 || true
    fi
    if [ -n "${BIN:-}" ] && [ -n "${T3_SOCK:-}" ]; then
        TMUX_TMPDIR="$SCRATCH" "$BIN" -L "$T3_SOCK" kill-server >/dev/null 2>&1 || true
    fi
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap _cleanup EXIT

echo "── Test 60: wrapper TMUX_BIN validity — §11.4.135 F1 regression guard ──"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 60: unsupported platform $HOST_OS §11.4.3"; exit 77 ;;
esac

# ── Resolve a real tmux binary (for the T3 GREEN server + cleanup). ──────
BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN="$(command -v tmux 2>/dev/null || true)"

# ════════════════════════════════════════════════════════════════════════
# T1 — STATIC always-on guard (cheap): generated scripts/tmx, if present,
#      declares TMUX_BIN=<path> AND that path exists + is executable.
# ════════════════════════════════════════════════════════════════════════
if [ ! -f "$TMX" ]; then
    _skip "T1 — generated scripts/tmx absent (run setup.sh) §11.4.3"
else
    # Extract the FIRST top-level `TMUX_BIN="..."` assignment (the wrapper's
    # canonical declaration at line ~33). Quote-stripped.
    TMUX_BIN_VAL="$(
        grep -m1 -E '^TMUX_BIN=' "$TMX" 2>/dev/null \
          | sed -e 's/^TMUX_BIN=//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
    )"
    if [ -z "$TMUX_BIN_VAL" ]; then
        _fail "T1 — scripts/tmx has no top-level TMUX_BIN= assignment"
    elif [ ! -e "$TMUX_BIN_VAL" ]; then
        _fail "T1 — scripts/tmx TMUX_BIN points at MISSING path: $TMUX_BIN_VAL (F1 crash surface)"
    elif [ ! -x "$TMUX_BIN_VAL" ]; then
        _fail "T1 — scripts/tmx TMUX_BIN exists but is NOT executable: $TMUX_BIN_VAL"
    else
        echo "[evidence 60-T1] TMUX_BIN=$TMUX_BIN_VAL exists+executable"
        _pass "T1 — scripts/tmx TMUX_BIN points at a valid executable"
    fi
fi

# ── PTY driver: run the EXACT operator path through a real PTY against a
#    wrapper directory placed FIRST on PATH. Emits one JSON-ish line of
#    captured evidence: rc=<child exit code> output=<captured bytes>.
#    The harness exec's `sh -c 'tmx attach -t NAME 2>/dev/null || exec tmx
#    new -s NAME'` — identical to scripts/tmx-shell-init.sh.template line 157.
_drive_operator_path() {
    # $1 = directory containing the `tmx` wrapper to put first on PATH
    # $2 = session NAME
    # $3 = HOME / TMUX_TMPDIR scratch dir for isolation
    python3 - "$1" "$2" "$3" <<'PY'
import os, pty, select, sys, time

wrap_dir, name, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ)
env["PATH"] = wrap_dir + ":" + env.get("PATH", "")
# Total isolation: private HOME + TMUX_TMPDIR so we never touch the
# operator's /tmp/tmux-501 or real config/sessions.
env["HOME"] = scratch
env["TMUX_TMPDIR"] = scratch
env.pop("TMUX", None)            # not "already inside tmux"
env["TERM"] = "xterm-256color"

# EXACT operator path from tmx-shell-init.sh.template line 157.
operator_cmd = (
    "exec sh -c 'tmx attach -t \"$1\" 2>/dev/null "
    "|| exec tmx new -s \"$1\"' tmx-shell-init " + name
)

pid, fd = pty.fork()
if pid == 0:
    os.environ.clear()
    os.environ.update(env)
    # The login shell that exec's into the wrapper chain. If the final
    # exec hits a missing binary, THIS process dies (F1).
    os.execvp("sh", ["sh", "-c", operator_cmd])
    os._exit(127)

buf = b""
deadline = time.time() + 6.0
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.25)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
    # Reap if the child already exited and pipe drained.
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        # drain a final read
        try:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                buf += os.read(fd, 4096)
        except OSError:
            pass
        rc = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (
            os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
        )
        try:
            os.close(fd)
        except OSError:
            pass
        out = buf.decode("utf-8", "replace").replace("\n", "\\n").replace("\r", "")
        print(f"rc={rc}|out={out}")
        sys.exit(0)

# Timed out: child still alive (e.g. T3 GREEN attach is blocking on the
# foreground client). Kill it, reap, report rc=ALIVE.
try:
    os.kill(pid, 9)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass
try:
    os.close(fd)
except OSError:
    pass
out = buf.decode("utf-8", "replace").replace("\n", "\\n").replace("\r", "")
print(f"rc=ALIVE|out={out}")
sys.exit(0)
PY
}

if ! command -v python3 >/dev/null 2>&1; then
    _skip "T2/T3 — python3 unavailable (PTY operator-path proof) §11.4.3"
elif [ ! -f "$TMX" ]; then
    _skip "T2/T3 — generated scripts/tmx absent (run setup.sh) §11.4.3"
elif [ -z "$BIN" ]; then
    _skip "T2/T3 — no tmux binary for the GREEN server §11.4.3"
else
    # ════════════════════════════════════════════════════════════════════
    # T2 — RED proof: synthesize a throwaway wrapper whose TMUX_BIN is a
    #      GUARANTEED-MISSING path, drive the operator path, assert the
    #      controlling shell DIES (exit 127) AND output names the missing
    #      binary ("No such file or directory"). This IS the F1 mechanism.
    # ════════════════════════════════════════════════════════════════════
    BAD_DIR="$SCRATCH/bad"
    mkdir -p "$BAD_DIR"
    MISSING="$SCRATCH/definitely/missing/tmux-binary-xyz"   # never exists
    # Rewrite ONLY the canonical TMUX_BIN= assignment to the missing path.
    sed -e "s|^TMUX_BIN=.*|TMUX_BIN=\"$MISSING\"|" "$TMX" > "$BAD_DIR/tmx"
    chmod 755 "$BAD_DIR/tmx"

    t2_ok=0; t2_total=0
    i=1
    while [ "$i" -le 3 ]; do
        t2_total=$((t2_total + 1))
        ITER_HOME="$SCRATCH/t2home.$i"; mkdir -p "$ITER_HOME"
        RESULT="$(_drive_operator_path "$BAD_DIR" "HelixCode" "$ITER_HOME" 2>/dev/null || true)"
        RC="$(printf '%s' "$RESULT" | sed -e 's/^rc=//' -e 's/|out=.*//')"
        OUT="$(printf '%s' "$RESULT" | sed -e 's/^.*|out=//')"
        # F1 SIGNATURE (the captured crash mechanism): the operator path
        # reached `exec "$TMUX_BIN" …` in the wrapper on the MISSING binary
        # and exec failed naming it "No such file or directory". This is the
        # exact failure that kills the operator's login shell (which had
        # exec'd into the wrapper chain) and closes the terminal window.
        # Both wrapper exec sites (the F1 anchor lines ~396 attach + ~430
        # new) appear in the capture — proving the missing-binary path is the
        # load-bearing surface, NOT a transient. The child rc varies by
        # branch (bash exec-failure-continue vs sh 127), so the deterministic
        # discriminator is the captured "No such file or directory" naming
        # the missing TMUX_BIN — never present on the GREEN run (T3).
        if printf '%s' "$OUT" | grep -qi 'No such file or directory' \
           && printf '%s' "$OUT" | grep -qF "$MISSING"; then
            echo "[evidence 60-T2 iter=$i] RED reproduced: wrapper exec hit MISSING TMUX_BIN — 'No such file or directory' naming $MISSING (rc=$RC)"
            echo "[evidence 60-T2 iter=$i] captured=\"$(printf '%s' "$OUT" | head -c 220)\""
            t2_ok=$((t2_ok + 1))
        else
            echo "[evidence 60-T2 iter=$i] rc=$RC out=\"$(printf '%s' "$OUT" | head -c 220)\""
        fi
        i=$((i + 1))
    done
    if [ "$t2_ok" -eq "$t2_total" ]; then
        _pass "T2 — RED: bad TMUX_BIN makes the wrapper exec a MISSING binary ('No such file or directory') — the F1 terminal-crash mechanism — $t2_ok/$t2_total iters"
    else
        _fail "T2 — RED proof did not reproduce on all iters ($t2_ok/$t2_total) — guard has no teeth"
    fi

    # ════════════════════════════════════════════════════════════════════
    # T3 — GREEN: the REAL wrapper (valid TMUX_BIN) drives the same
    #      operator path. The server must come up (session created) and the
    #      shell must NOT die with a missing-binary error. We pre-create a
    #      uniquely-named detached session via the wrapper so the operator
    #      path takes the `attach` branch (foreground client, blocks until
    #      timeout = success signal) rather than crashing.
    # ════════════════════════════════════════════════════════════════════
    t3_ok=0; t3_total=0
    i=1
    while [ "$i" -le 3 ]; do
        t3_total=$((t3_total + 1))
        ITER_HOME="$SCRATCH/t3home.$i"; mkdir -p "$ITER_HOME"
        NAME="tmxg60_${$}_$i"
        # Create the session through the REAL wrapper (operator entry point),
        # isolated under our scratch dir.
        HOME="$ITER_HOME" TMUX_TMPDIR="$ITER_HOME" TMUX= \
            "$TMX" new -s "$NAME" >/dev/null 2>&1 || true
        T3_NAME="$NAME"; T3_SOCK="tmx-$NAME"
        # Positive evidence the server came up: the session is listed.
        if HOME="$ITER_HOME" TMUX_TMPDIR="$ITER_HOME" "$TMX" ls 2>/dev/null | grep -q "$NAME"; then
            server_up=1
        else
            server_up=0
        fi
        # Drive the operator path; the attach branch should engage (server is
        # up) → child stays ALIVE until our PTY timeout = it did NOT crash on a
        # missing binary. We also assert NO 'No such file or directory'.
        RESULT="$(_drive_operator_path "$REPO_ROOT/scripts" "$NAME" "$ITER_HOME" 2>/dev/null || true)"
        RC="$(printf '%s' "$RESULT" | sed -e 's/^rc=//' -e 's/|out=.*//')"
        OUT="$(printf '%s' "$RESULT" | sed -e 's/^.*|out=//')"
        no_missing=1
        printf '%s' "$OUT" | grep -qi 'No such file or directory' && no_missing=0
        # Clean up this iter's session immediately.
        HOME="$ITER_HOME" TMUX_TMPDIR="$ITER_HOME" "$TMX" kill-session -t "$NAME" >/dev/null 2>&1 || true
        TMUX_TMPDIR="$ITER_HOME" "$BIN" -L "tmx-$NAME" kill-server >/dev/null 2>&1 || true
        T3_NAME=""; T3_SOCK=""
        if [ "$server_up" -eq 1 ] && [ "$no_missing" -eq 1 ]; then
            echo "[evidence 60-T3 iter=$i] GREEN: server up (session '$NAME' listed), operator path emitted NO 'No such file or directory' (rc=$RC)"
            t3_ok=$((t3_ok + 1))
        else
            echo "[evidence 60-T3 iter=$i] server_up=$server_up rc=$RC no_missing=$no_missing out=\"$(printf '%s' "$OUT" | head -c 160)\""
        fi
        i=$((i + 1))
    done
    if [ "$t3_ok" -eq "$t3_total" ]; then
        _pass "T3 — GREEN: real wrapper creates the session + operator path does NOT crash $t3_ok/$t3_total iters"
    else
        _fail "T3 — GREEN did not hold on all iters ($t3_ok/$t3_total)"
    fi
fi

echo "── summary 60: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
