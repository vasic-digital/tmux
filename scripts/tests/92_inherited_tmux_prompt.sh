#!/usr/bin/env bash
# Test 92 — inherited $TMUX must NOT suppress the new-terminal session-name prompt.
#
# §11.4.1 / §11.4.4 / §11.4.115 FORENSIC ANCHOR:
#   Operator report (2026-10-11): after `bash scripts/setup.sh`, opening a new
#   terminal did not ask for a tmx session name. Root cause: the shell-init
#   treated any shell with $TMUX set as "already inside tmux" and returned
#   silently. A terminal emulator launched from within a tmux client inherits
#   $TMUX (the socket path) but has its OWN pty/tty and is NOT a tmux pane.
#
#   This test reproduces that exact false positive: it starts a live tmux
#   server on a private socket, then spawns a brand-new pty login shell with
#   $TMUX set to that socket (simulating a new terminal window opened from
#   tmux) and asserts the interactive prompt STILL APPEARS. It also asserts
#   the inside-tmux pane-tty probe fires (anti-bluff: a prompt that appeared
#   for any other reason would not emit the distinctive debug marker).
#
#   A paired meta-test can strip the `_tmx_inside_pane()` guard and revert to
#   `[ -n "$TMUX" ]`; this test then FAILs because the prompt never appears.
#
# §11.4.2 captured evidence: pty buffer contains prompt string + debug marker.
# §11.4.50 reliability: 3 iterations, identical prompt count.
# §11.4.81 cross-platform: POSIX sh guard + Linux/Darwin pty driver.
# §11.4.14 cleanup: trap kills the test server and removes the sandbox.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
GENERATED="$REPO_ROOT/scripts/tmx-shell-init.sh"
TMUX_BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$TMUX_BIN" ] || TMUX_BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 92: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 92: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 92: $*"; SKIP=$((SKIP + 1)); }

_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 92: scratch root $SCRATCH not writable — §11.4.3"
    exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin|Linux) ;;
    *) echo "SKIP 92: unsupported platform $HOST_OS"; exit 77 ;;
esac

if [ ! -x "$TMUX_BIN" ]; then
    echo "SKIP 92: project tmux binary not built at $TMUX_BIN"
    exit 77
fi
if [ ! -f "$TEMPLATE" ] || [ ! -f "$GENERATED" ]; then
    echo "SKIP 92: tmx-shell-init template/generated file missing"
    exit 77
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP 92: python3 not available (§11.4.3 topology)"
    exit 77
fi
if [ ! -x /bin/bash ]; then
    echo "SKIP 92: /bin/bash not available (§11.4.3 topology)"
    exit 77
fi

SANDBOX=$(mktemp -d "$SCRATCH/tmx-test92-XXXXXX")
SERVER_SOCK="$SCRATCH/tmx-test92-server-$$.sock"
TMUX_TMPDIR_PRIVATE="$SANDBOX/.tmux_tmpdir"
TMUX_STATE_FILE="$SANDBOX/tmx-state-$$.json"
PROMPT_REGEX='Enter session name'
MARKER_REGEX='TMUX set but tty .* is not a tmux pane; prompting anyway'

cleanup() {
    [ -S "$SERVER_SOCK" ] && "$TMUX_BIN" -S "$SERVER_SOCK" kill-server 2>/dev/null || true
    rm -rf "$SANDBOX" "$SERVER_SOCK" 2>/dev/null || true
}
trap cleanup EXIT

# Private, pre-created-but-empty TMUX_TMPDIR socket dir. Keeps `tmx ls`
# (invoked by the blank-input picker) from seeing the operator's real live
# sessions, which would turn a single prompt into a multi-line picker and
# break the count assertion. See test 54 for the same isolation rationale.
mkdir -p "$TMUX_TMPDIR_PRIVATE/tmux-$(id -u)"

SCRIPTS_DIR="$REPO_ROOT/scripts"
cat > "$SANDBOX/.bashrc" <<RC
export PATH="$SCRIPTS_DIR:\$PATH"
export VDIGITAL_TMUX_DIR="$SCRIPTS_DIR"
[ -r "$GENERATED" ] && . "$GENERATED"
RC
cat > "$SANDBOX/.bash_profile" <<RC
export PATH="$SCRIPTS_DIR:\$PATH"
export VDIGITAL_TMUX_DIR="$SCRIPTS_DIR"
[ -r "$GENERATED" ] && . "$GENERATED"
if [ -f "\$HOME/.bashrc" ]; then . "\$HOME/.bashrc"; fi
RC

echo "── Test 92: inherited \$TMUX must not suppress the session-name prompt ──"

# ── T0: STRUCTURAL — template carries the pane-tty probe guard. A revert to
#     plain `[ -n "$TMUX" ]` removes these symbols.
if ! grep -qF '_tmx_inside_pane()' "$TEMPLATE"; then
    _fail "T0 template missing _tmx_inside_pane() guard"
elif ! grep -qF "list-panes -a -F '#{pane_tty}'" "$TEMPLATE"; then
    _fail "T0 template missing pane-tty probe"
else
    _pass "T0 pane-tty inside-tmux guard present in template"
fi

# ── T1: RUNTIME — start a live tmux server, spawn a NEW pty shell with
#     $TMUX inherited from it, and assert the prompt appears exactly once.
run_iteration() {
    local iter="$1"
    # Ensure no stale server.
    [ -S "$SERVER_SOCK" ] && "$TMUX_BIN" -S "$SERVER_SOCK" kill-server 2>/dev/null || true
    rm -f "$SERVER_SOCK"

    # Live tmux server on a socket OUTSIDE the private TMUX_TMPDIR, so the
    # wrapper's `tmx ls` (blank-input picker) sees zero sessions and the
    # prompt path returns cleanly after one question.
    "$TMUX_BIN" -S "$SERVER_SOCK" new-session -d -s test92_server || {
        _fail "T1 iter=$iter: could not start test tmux server"
        return 1
    }
    # Positive evidence that the server is alive and has a pane.
    local pane_tty
    pane_tty=$("$TMUX_BIN" -S "$SERVER_SOCK" display-message -p '#{pane_tty}' 2>/dev/null) || pane_tty=""
    if [ -z "$pane_tty" ]; then
        _fail "T1 iter=$iter: server has no reachable pane"
        return 1
    fi

    local pty_out
    pty_out="$SCRATCH/tmx-test92-pty-$$-$iter.log"
    rc=0
    python3 - "$SANDBOX" "$SERVER_SOCK" "$TMUX_TMPDIR_PRIVATE" "$pty_out" "$iter" "$SCRIPTS_DIR" <<'PY' || rc=$?
import os, pty, select, time, sys
sandbox      = sys.argv[1]
server_sock  = sys.argv[2]
tmux_tmpdir  = sys.argv[3]
out_path     = sys.argv[4]
iter_n       = sys.argv[5]
scripts_dir  = sys.argv[6]

PROMPT  = b"Enter session name"
MARKER  = b"TMUX set but tty"
env = dict(os.environ)
env["HOME"] = sandbox
env["TMUX"] = server_sock
env["TMUX_TMPDIR"] = tmux_tmpdir
env["TMX_INIT_DEBUG"] = "1"
env.pop("TMX_SKIP", None)
env["PATH"] = scripts_dir + os.pathsep + env.get("PATH", "")
# Ensure tmx-state writes into the sandbox, not the operator's home.
env["TMX_STATE_FILE"] = os.path.join(sandbox, "tmx-state.json")

pid, fd = pty.fork()
if pid == 0:
    os.execvpe("/bin/bash", ["/bin/bash", "-l", "-i"], env)
    os._exit(127)

buf = b""
responded = 0
exited = False
last = time.time()
while True:
    r, _, _ = select.select([fd], [], [], 0.3)
    if fd in r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        buf += d
        last = time.time()
    cur = buf.count(PROMPT)
    # Answer the ONE expected prompt with a blank line so the blank-input
    # picker path runs and then returns to a bare shell.
    if cur > responded and responded < 1:
        time.sleep(0.2)
        os.write(fd, b"\n")
        responded += 1
        last = time.time()
        continue
    if time.time() - last > 4:
        if not exited:
            os.write(fd, b"exit\n")
            exited = True
            last = time.time()
        else:
            break

try:
    os.close(fd)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass

with open(out_path, "wb") as f:
    f.write(buf)

n_prompt  = buf.count(PROMPT)
n_marker  = buf.count(MARKER)
print("EVIDENCE iter=%s prompt_count=%d marker_count=%d" % (iter_n, n_prompt, n_marker))
# Require exactly one prompt AND the distinctive debug marker that proves
# the hardened guard fired (not some unrelated code path).
sys.exit(0 if n_prompt == 1 and n_marker >= 1 else 2)
PY
    rc=$rc

    if [ "$rc" -ne 0 ]; then
        _fail "T1 iter=$iter: prompt did not appear exactly once with guard marker (rc=$rc)"
        echo "  pty output:" >&2
        cat "$pty_out" >&2 || true
        rm -f "$pty_out"
        return 1
    fi
    _pass "T1 iter=$iter: inherited \$TMUX shell prompted exactly once, guard marker present"
    rm -f "$pty_out"
    return 0
}

_iter_failed=0
for i in 1 2 3; do
    if ! run_iteration "$i"; then _iter_failed=1; break; fi
done

if [ "$_iter_failed" -eq 1 ]; then
    echo "── summary 92: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi

_pass "T1 + T2 deterministic on 3/3 iterations"

echo "── summary 92: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
