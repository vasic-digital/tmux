#!/bin/sh
# 56_real_mouse_drag_copy.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.2/§11.4.5/§11.4.52 PHYSICAL proof that a PLAIN left mouse
#             drag selects + copies text to the clipboard pipe EVEN inside a
#             mouse-tracking application (the Claude Code scenario:
#             `#{mouse_any_flag}`=1). This is the end-user gesture the operator
#             reported broken on 2026-05-29 ("we still cannot select and copy
#             anything in Claude Code … on both platforms Linux and macOS").
#
#             Cross-platform + headless: drives REAL SGR-1006 mouse drag
#             sequences into an attached tmux client (the exact terminal
#             mouse-event path), with a real mouse-tracking app holding the
#             pane (alt-screen + ?1003h + ?1006h, same modes Claude Code
#             requests). Asserts `mouse_any_flag`=1 at drag time (so the proof
#             is meaningful — at flag=0 even the old forwarding binding copies)
#             AND that the dragged token reached the @clip sink.
#
#             Optional GUI layer (macOS, opt-in TMX_GUI_TESTS=1 + cliclick):
#             a genuine cursor drag over a real iTerm2 window → pbpaste.
# Usage:      bash scripts/tests/56_real_mouse_drag_copy.sh
# Outputs:    EVIDENCE … ; PASS/FAIL ; honest SKIP (§11.4.3) when python3/pty
#             unavailable.
# Side-effects: throwaway tmux server on a private socket label (trap-cleaned).
#             Uses a temp-file @clip sink — never touches the real clipboard
#             in the headless path.
# Dependencies: tmux (built or system >=3.x), python3 (stdlib pty).
# Cross-refs: scripts/tmux.conf.template root `MouseDrag1Pane` override ;
#             meta-test M-PLAINDRAG ; test 55 (toggle + binding presence) ;
#             forensic anchor user report 2026-05-29.
# Last verified: 2026-05-29
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
CONF="$REPO_ROOT/scripts/tmux.conf.template"
[ -r "$CONF" ] || { echo "FAIL: 56 — $CONF missing"; exit 1; }

BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN=$(command -v tmux 2>/dev/null || true)
[ -n "$BIN" ] || { echo "SKIP: 56 — no tmux binary (§11.4.3 topology)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: 56 — python3 unavailable (§11.4.3 topology)"; exit 0; }
# §11.4.3 topology dispatch: a PTY-attached tmux client must register a usable
# terminal size for injected SGR mouse drags to map to a pane. In a headless
# container with no real controlling terminal the client registers no size, so
# copy-mode never enters (discriminator 2026-06-30). SKIP-with-reason here; on a
# real terminal the probe passes and the full proof runs + enforces.
. "$SELF_DIR/lib/interactive_pty_probe.sh"
ipty_mouse_topology_ok "$BIN" || { echo "SKIP: 56 — headless: PTY-attached tmux client registers no usable terminal size; injected SGR mouse drags cannot map to a pane (needs a real interactive terminal) — §11.4.3"; exit 0; }

L="dragproof$$"
SINK=$(mktemp)
# X's MUST be at the END of the mktemp template: BSD mktemp (macOS) does NOT
# expand `mt_app.XXXXXX.py` (X's not trailing) and creates the LITERAL shared
# filename, colliding across tests 56+57 and reruns (self-perpetuating under
# `set -eu`). `.py.XXXXXX` is portable BSD+GNU and the app is invoked by path.
APP=$(mktemp "${TMPDIR:-/tmp}/mt_app.py.XXXXXX")
TOK="DRAGPROOF_${$}_$(date +%s)"
cleanup() { "$BIN" -L "$L" kill-server 2>/dev/null || true; "$BIN" -L "${L}gui" kill-server 2>/dev/null || true; rm -f "$SINK" "$APP"; }
trap cleanup EXIT

# Mouse-tracking app: alt-screen + any-event tracking + SGR encoding (the exact
# surface Claude Code presents), fills the pane with the unique token, blocks.
cat > "$APP" <<'PYAPP'
import os,sys,signal
CSI=b"\x1b["
for s in (b"?1049h",b"?1003h",b"?1006h"): os.write(1,CSI+s)
tok=sys.argv[1]
os.write(1,CSI+b"2J"+CSI+b"H")
line=((tok+" ")*8+"\n").encode()
for _ in range(24): os.write(1,line)
sys.stdout.flush()
def restore(*a):
    for s in (b"?1003l",b"?1006l",b"?1049l"): os.write(1,CSI+s)
    os._exit(0)
for sg in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sg,restore)
while True:
    try:
        d=sys.stdin.buffer.read(4096)
        if not d: break
    except Exception: break
restore()
PYAPP

"$BIN" -L "$L" kill-server 2>/dev/null || true
"$BIN" -L "$L" -f "$CONF" new-session -d -s s -x 80 -y 24
# Headless capture sink instead of the real OS clipboard.
"$BIN" -L "$L" set -g @clip "cat > $SINK"
# The shipped config defaults `mouse off` (the terminal owns the mouse by
# default; tmux's own mouse drag-select + wheel-scrollback are available
# ON DEMAND via `prefix m`). This test exercises that tmux-mouse-ON path —
# the exact state `prefix m` produces — so enable it before injecting the
# real SGR-1006 drag events, otherwise tmux does not parse incoming mouse
# sequences at all and the drag is a no-op.
"$BIN" -L "$L" set -g mouse on

# Drive the real mouse-event path: attach a client on a PTY, run the
# mouse-tracking app in it, confirm mouse_any_flag=1, inject an SGR-1006
# left-button drag (press → motion → motion → release), drain.
FLAG=$(python3 - "$BIN" "$L" "$APP" "$TOK" <<'PY'
import os,pty,select,time,sys,subprocess
BIN,L,APP,TOK=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
pid,fd=pty.fork()
if pid==0:
    # A mouse-capable TERM is REQUIRED on the attach client: tmux does not
    # parse incoming mouse (SGR) sequences for a "dumb" terminal, and over
    # `ssh host 'bash -s'` the inherited TERM is "dumb" — which silently made
    # this proof fail on Linux until set explicitly (forensic anchor: nezha
    # 2026-05-29). Real desktop terminals set xterm-256color, so end users are
    # unaffected; the test just must not inherit "dumb".
    os.environ["TERM"]="xterm-256color"
    os.execvp(BIN,[BIN,"-L",L,"attach","-t","s"]); os._exit(127)
time.sleep(1.0)
subprocess.run([BIN,"-L",L,"send-keys","-t","s","python3 "+APP+" "+TOK,"Enter"])
flag="0"
for _ in range(40):
    flag=subprocess.run([BIN,"-L",L,"display-message","-p","-t","s","#{mouse_any_flag}"],
                        capture_output=True,text=True).stdout.strip()
    if flag=="1": break
    time.sleep(0.2)
ESC="\x1b"
def w(s): os.write(fd,s.encode())
w(f"{ESC}[<0;3;2M");  time.sleep(0.15)   # press   (left button, col3 row2)
w(f"{ESC}[<32;30;5M"); time.sleep(0.15)  # motion  (button held)
w(f"{ESC}[<32;60;8M"); time.sleep(0.15)  # motion
w(f"{ESC}[<0;60;8m");  time.sleep(0.4)    # release
t=time.time()
while time.time()-t<1.0:
    r,_,_=select.select([fd],[],[],0.2)
    if fd in r:
        try:
            if not os.read(fd,4096): break
        except OSError: break
try: os.close(fd)
except OSError: pass
# Deterministically reap the PTY-attach client BEFORE any later kill-server, so
# an orphaned attached client never prints the benign CLIENT_EXIT_LOST_SERVER
# ("server exited unexpectedly") console notice.
try: os.kill(pid, 15)
except (ProcessLookupError, OSError): pass
try: os.waitpid(pid, 0)
except (ChildProcessError, OSError): pass
print(flag)
PY
)
sleep 0.4

fail=0
if [ "$FLAG" = "1" ]; then
    echo "EVIDENCE: mouse_any_flag=1 at drag time (mouse-tracking app active — Claude Code scenario)"
else
    echo "FAIL: 56 — mouse_any_flag was '$FLAG' at drag (could not establish the mouse-tracking scenario)"; fail=1
fi
if grep -q "$TOK" "$SINK" 2>/dev/null; then
    echo "EVIDENCE: plain drag copied the token to @clip sink ($(tr -d '\n' < "$SINK" | head -c 48))"
else
    echo "FAIL: 56 — plain drag did NOT copy in a mouse-tracking app (sink empty: regression)"; fail=1
fi

# ── Optional macOS GUI layer: a genuine cursor drag over real iTerm2 ──
if [ "${TMX_GUI_TESTS:-0}" = "1" ] && [ "$(uname -s)" = "Darwin" ] && command -v cliclick >/dev/null 2>&1 && command -v osascript >/dev/null 2>&1; then
    GTOK="GUIDRAG_$$_$(date +%s)"
    printf 'GUI_SENTINEL' | pbcopy 2>/dev/null || true
    osascript >/dev/null 2>&1 <<OSA || true
tell application "iTerm2"
  activate
  set w to (create window with default profile)
  set bounds of w to {60, 80, 940, 640}
  tell current session of w
    write text ""
    delay 0.8
    write text "export TMX_SKIP=1; cd $REPO_ROOT && clear && $BIN -L ${L}gui -f scripts/tmux.conf.template new -A -s g"
    delay 1.8
    write text "python3 $APP $GTOK"
    delay 1.8
  end tell
end tell
OSA
    sleep 1
    cliclick m:200,250 >/dev/null 2>&1; sleep 0.2
    cliclick dd:200,250 >/dev/null 2>&1; sleep 0.25
    cliclick dm:500,380 >/dev/null 2>&1; sleep 0.2
    cliclick dm:820,520 >/dev/null 2>&1; sleep 0.25
    cliclick du:820,520 >/dev/null 2>&1; sleep 0.6
    GUIGOT="$(pbpaste 2>/dev/null || true)"
    osascript -e 'tell application "iTerm2" to close (current window)' >/dev/null 2>&1 || true
    case "$GUIGOT" in
        *"$GTOK"*) echo "EVIDENCE: macOS GUI layer — REAL cliclick cursor drag over iTerm2 copied the token to pbpaste" ;;
        *) echo "WARN: 56 GUI layer inconclusive (window geometry/focus); headless SGR proof above is authoritative" ;;
    esac
else
    echo "SKIP-layer: 56 GUI cliclick proof not run (opt-in TMX_GUI_TESTS=1 on macOS w/ cliclick); headless SGR proof is the cross-platform authority (§11.4.3)"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: 56 plain mouse-drag selects+copies inside a mouse-tracking app (Claude Code scenario), cross-platform"
    exit 0
else
    echo "FAIL: 56 plain mouse-drag copy in mouse-tracking app"
    exit 1
fi
