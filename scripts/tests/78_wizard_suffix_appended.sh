#!/usr/bin/env bash
# Test 78 — wizard-created sessions always get a random 4-digit suffix;
# TMX_EXACT_NAME=1 opts out.
#
# Purpose:    §1 mandate (2026-07-05): typing "my-session" at the wizard
#             creates a REAL session named "my-session-NNNN" (4 random
#             digits), never the literal typed name — unless
#             TMX_EXACT_NAME=1 is set (for scripts/automation).
# Usage:      bash scripts/tests/78_wizard_suffix_appended.sh
# Outputs:    EVIDENCE lines; PASS/FAIL/SKIP; exit 0 PASS / non-0 FAIL.
# Side-effects: private HOME/TMUX_TMPDIR sandbox, trap-cleaned; creates + tears
#             down its own uniquely-named ($$-scoped) tmx sessions ONLY.
# Dependencies: built tmux binary, scripts/tmx wrapper,
#             scripts/tmx-shell-init.sh (generated), python3.
# Cross-refs: scripts/tmx-shell-init.sh.template; §1 forensic anchor
#             2026-07-05; test 54 (same shell-init file, different concern).
# Design note (2026-07-05, task 6 live-run root-cause): the wizard's typed-name
#             path execs `tmx new -s <base>-NNNN`, and the LANDED `new` verb
#             (tasks 1-5) prompts "Enter password for session ... (blank = none)"
#             for a genuinely-fresh name BEFORE it creates anything. The PTY
#             driver therefore answers that prompt with a blank line (exactly
#             what an operator does to skip a password), so `tmx new` proceeds
#             to actually create the session. The created server persists in its
#             own tmux socket at $TMUX_TMPDIR/tmux-$(id -u)/tmx-<name>; the
#             verification reads it back WITH the sandbox TMUX_TMPDIR set (a
#             plain `tmux -L LABEL ls` in the parent shell would look in the
#             DEFAULT /tmp socket dir and never see the sandbox session).
# Last verified: 2026-07-05 (live on Linux, systemd-run --user scope isolation).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
INIT="$REPO_ROOT/scripts/tmx-shell-init.sh"
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin) TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-darwin/bin/tmux" ;;
    *)      TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build/bin/tmux" ;;
esac
[ -x "$TMUX_BIN_DEFAULT" ] || TMUX_BIN_DEFAULT="$REPO_ROOT/tmux/build-linux/bin/tmux"
TMUX_BIN="${TMUX_BIN:-$TMUX_BIN_DEFAULT}"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 78: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL 78: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP 78: $*"; SKIP=$((SKIP+1)); }

echo "── Test 78: wizard-created session gets a random 4-digit suffix ──"

if [ ! -r "$INIT" ]; then echo "SKIP 78: $INIT missing (run scripts/setup.sh)"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if ! command -v python3 >/dev/null 2>&1; then echo "SKIP 78: python3 not available — §11.4.3"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$TMUX_BIN" ]; then echo "SKIP 78: tmux binary not built"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi
if [ ! -x "$WRAPPER" ]; then echo "SKIP 78: scripts/tmx wrapper not generated"; echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 0; fi

SCRATCH="$(mktemp -d)"
SOCKDIR="$SCRATCH/tmux-$(id -u)"
SCRIPTS_DIR=$(CDPATH= cd -- "$(dirname -- "$INIT")" && pwd)

# Kill + scope-stop every session this run created (mine only, keyed off the
# unique $$-scoped base names — NEVER touches the operator's other sessions,
# per §11.4.174 shared-host process-ownership).
_reap() {
    _rbase="$1"
    for _lbl in $(ls "$SOCKDIR" 2>/dev/null | grep -E "^tmx-${_rbase}" 2>/dev/null); do
        TMUX_TMPDIR="$SCRATCH" "$TMUX_BIN" -L "$_lbl" kill-server >/dev/null 2>&1 || true
    done
    if command -v systemctl >/dev/null 2>&1; then
        for _u in $(systemctl --user list-units --no-legend "tmx-${_rbase}*.scope" 2>/dev/null | awk '{print $1}'); do
            systemctl --user stop "$_u" >/dev/null 2>&1 || true
        done
        systemctl --user reset-failed "tmx-${_rbase}*.scope" >/dev/null 2>&1 || true
    fi
}
trap '_reap "wiztest78"; rm -rf "$SCRATCH"' EXIT

# Drive tmx-shell-init.sh's prompt via a real PTY (python pty.fork): type a
# base name, then answer the "Enter password (blank = none)" prompt with a
# blank line so the fresh session is actually created with no password.
# Returns nothing; the created session is read back afterwards from $SOCKDIR.
_drive_wizard() {
    _dw_base="$1"; _dw_exact="${2:-}"
    python3 - "$SCRATCH" "$INIT" "$SCRIPTS_DIR" "$_dw_base" "$_dw_exact" <<'PY'
import os, pty, select, time, sys
sandbox, init, scripts_dir, base, exact = sys.argv[1:6]
env = dict(os.environ)
env["HOME"] = sandbox
env["TMUX_TMPDIR"] = sandbox
env.pop("TMUX", None)
env.pop("TMX_SKIP", None)
if exact:
    env["TMX_EXACT_NAME"] = "1"
else:
    env.pop("TMX_EXACT_NAME", None)
env["PATH"] = scripts_dir + os.pathsep + env.get("PATH", "")
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("/bin/sh", ["/bin/sh", "-c", f". '{init}'; exit 0"], env)
    os._exit(127)
buf = b""
sent_name = False
sent_pw = False
detached = False
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
    if not sent_name and b"Enter session name" in buf:
        time.sleep(0.2)
        os.write(fd, (base + "\n").encode())
        sent_name = True
        last = time.time()
    # Answer the create-verb's optional-password prompt with a blank line.
    if sent_name and not sent_pw and b"Enter password" in buf:
        time.sleep(0.3)
        os.write(fd, b"\n")
        sent_pw = True
        last = time.time()
    # Once the session is up (status bar shows), cleanly detach so the
    # detached server persists for the post-run read-back.
    if sent_pw and not detached and time.time() - last > 2.5:
        os.write(fd, b"\x02d")  # Ctrl-b d
        detached = True
        last = time.time()
    if detached and time.time() - last > 1.5:
        break
    if time.time() - last > 8:
        break
try:
    os.close(fd)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except OSError:
    pass
sys.stdout.write(buf.decode(errors="replace"))
PY
}

# Read back the ONE session name created under a socket label starting with
# "tmx-<base>" (prints empty if none). Uses the sandbox TMUX_TMPDIR so the
# per-session socket in $SOCKDIR is actually reachable.
_created_name_for() {
    _cn_base="$1"
    for _lbl in $(ls "$SOCKDIR" 2>/dev/null | grep -E "^tmx-${_cn_base}" 2>/dev/null); do
        _cn="$(TMUX_TMPDIR="$SCRATCH" "$TMUX_BIN" -L "$_lbl" ls -F '#{session_name}' 2>/dev/null | head -1)"
        if [ -n "$_cn" ]; then printf '%s\n' "$_cn"; return 0; fi
    done
    return 0
}

# ── Case 1: typed name → base + random 4-digit suffix ───────────────────
BASE="wiztest78"
_out="$(_drive_wizard "$BASE")"
echo "[evidence] wizard transcript captured (${#_out} bytes)"
sleep 1
_created="$(_created_name_for "$BASE")"
if [ -z "$_created" ]; then
    _fail "no session matching '${BASE}-NNNN' was found after driving the wizard (transcript: $(printf '%s' "$_out" | tr '\n' '|' | cut -c1-160))"
else
    case "$_created" in
        "${BASE}"-[0-9][0-9][0-9][0-9])
            _pass "wizard-created session name is '$_created' (base + 4-digit suffix)"
            ;;
        "$BASE")
            _fail "wizard created the LITERAL typed name '$_created' — no suffix appended"
            ;;
        *)
            _fail "wizard-created session name '$_created' does not match '${BASE}-NNNN'"
            ;;
    esac
fi
_reap "$BASE"

# ── Case 2: TMX_EXACT_NAME=1 opt-out → literal name, no suffix ───────────
BASE2="wiztest78exact"
_out2="$(_drive_wizard "$BASE2" "1")"
echo "[evidence] TMX_EXACT_NAME wizard transcript captured (${#_out2} bytes)"
sleep 1
_created2="$(_created_name_for "$BASE2")"
if [ "$_created2" = "$BASE2" ]; then
    _pass "TMX_EXACT_NAME=1 → wizard created the literal name '$_created2', no suffix"
else
    _fail "TMX_EXACT_NAME=1 did not yield the literal name (created='$_created2', want '$BASE2')"
fi
_reap "$BASE2"

echo "── Test 78 summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
[ "$FAIL" -eq 0 ]
