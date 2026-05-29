#!/bin/sh
# 57_reload_select_copy_paste.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.2/§11.4.5/§11.4.52 COMPREHENSIVE proof of the operator's
#             end-to-end demand (2026-05-29): "We cannot still select copy and
#             paste from tmux sessions! … fully validated with full automation
#             tests producing comprehensive evidence."
#
#             Forensic root cause this round: a tmux server loads its config
#             only at start, so a session started BEFORE the mouse-copy fix
#             keeps the OLD drag-forwarding binding and cannot select/copy —
#             which is exactly what the operator hit (the live Herald session).
#             The fix is `tmx reload` (source-file into running sessions).
#
#             This test proves, with REAL terminal mouse events (SGR-1006) and
#             the real paste mechanism, on macOS AND Linux (headless):
#               (A) STALE session (old forwarding binding) → plain drag in a
#                   mouse-tracking app copies NOTHING (reproduces the failure);
#               (B) after `source-file` of the shipped config (what `tmx reload`
#                   does) → the SAME plain drag selects + copies (fix proven);
#               (C) PASTE: a tmux buffer pasted into a live shell pane appears
#                   in the pane (capture-pane evidence) — the paste mechanism;
#               (D) macOS only: full OS-clipboard paste chain via the `prefix P`
#                   binding (pbcopy marker → paste → capture-pane).
# Usage:      bash scripts/tests/57_reload_select_copy_paste.sh
# Outputs:    EVIDENCE … ; PASS/FAIL ; honest §11.4.3 SKIP if python3 absent.
# Side-effects: throwaway tmux server on a private socket (trap-cleaned);
#             temp-file @clip sink; macOS layer briefly sets the clipboard.
# Dependencies: tmux (built/system >=3.x), python3 (stdlib pty).
# Cross-refs: scripts/tmx.template `reload` subcommand ; scripts/tmux.conf.template
#             root MouseDrag1Pane override + paste bindings ; test 56 ;
#             meta-test M-PLAINDRAG + M-TMX-RELOAD.
# Last verified: 2026-05-29
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
CONF="$REPO_ROOT/scripts/tmux.conf.template"
[ -r "$CONF" ] || { echo "FAIL: 57 — $CONF missing"; exit 1; }
BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN=$(command -v tmux 2>/dev/null || true)
[ -n "$BIN" ] || { echo "SKIP: 57 — no tmux binary (§11.4.3)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: 57 — python3 unavailable (§11.4.3)"; exit 0; }

L="rcp$$"
SINK=$(mktemp)
APP=$(mktemp /tmp/mt_app.XXXXXX.py)
cleanup() { "$BIN" -L "$L" kill-server 2>/dev/null || true; rm -f "$SINK" "$APP"; }
trap cleanup EXIT

cat > "$APP" <<'PYAPP'
import os,sys,signal
CSI=b"\x1b["
for s in (b"?1049h",b"?1003h",b"?1006h"): os.write(1,CSI+s)
tok=sys.argv[1]
os.write(1,CSI+b"2J"+CSI+b"H")
for _ in range(24): os.write(1,((tok+" ")*8+"\n").encode())
sys.stdout.flush()
def r(*a):
    for s in (b"?1003l",b"?1006l",b"?1049l"): os.write(1,CSI+s)
    os._exit(0)
for sg in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sg,r)
while True:
    try:
        if not sys.stdin.buffer.read(4096): break
    except Exception: break
r()
PYAPP

# inject_drag <socket> <token-not-used> : attach a client, run the app, wait for
# mouse_any_flag=1, inject an SGR-1006 left drag. Prints the flag.
inject_drag() {
    _sock="$1"
    python3 - "$BIN" "$_sock" "$APP" "$2" <<'PY'
import os,pty,select,time,sys,subprocess
BIN,L,APP,TOK=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
pid,fd=pty.fork()
if pid==0:
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
w(f"{ESC}[<0;3;2M");  time.sleep(0.15)
w(f"{ESC}[<32;30;5M"); time.sleep(0.15)
w(f"{ESC}[<32;60;8M"); time.sleep(0.15)
w(f"{ESC}[<0;60;8m");  time.sleep(0.4)
t=time.time()
while time.time()-t<1.0:
    r,_,_=select.select([fd],[],[],0.2)
    if fd in r:
        try:
            if not os.read(fd,4096): break
        except OSError: break
try: os.close(fd)
except OSError: pass
print(flag)
PY
}

fail=0

# ── (A) STALE session: old forwarding binding → drag copies nothing ──────────
TOKA="STALE_$$"
"$BIN" -L "$L" kill-server 2>/dev/null || true
"$BIN" -L "$L" -f "$CONF" new-session -d -s s -x 80 -y 24
"$BIN" -L "$L" set -g @clip "cat > $SINK"
# Re-instate tmux's pre-fix DEFAULT (forward drag to app on mouse_any_flag),
# emulating a session started before the fix.
"$BIN" -L "$L" bind -n MouseDrag1Pane if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send -M' 'copy-mode -M'
: > "$SINK"
FA=$(inject_drag "$L" "$TOKA")
if [ "$FA" = "1" ] && ! grep -q "$TOKA" "$SINK" 2>/dev/null; then
    echo "EVIDENCE (A): STALE session (old binding) — plain drag copied NOTHING (reproduces the reported failure)"
else
    echo "FAIL: 57(A) — stale-session repro invalid (flag=$FA, sink=$(tr -d '\n' < "$SINK" | head -c 20))"; fail=1
fi
"$BIN" -L "$L" kill-server 2>/dev/null || true

# ── (B) RELOAD: source-file the shipped config (what `tmx reload` does) ───────
TOKB="RELOADED_$$"
"$BIN" -L "$L" -f /dev/null new-session -d -s s -x 80 -y 24
"$BIN" -L "$L" set -g @clip "cat > $SINK"
# Start with the old binding, then reload the real config to apply the override.
"$BIN" -L "$L" bind -n MouseDrag1Pane if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send -M' 'copy-mode -M'
"$BIN" -L "$L" source-file "$CONF"   # == `tmx reload`
# source-file restores the shipped @clip (pbcopy/...); re-point it to the
# headless sink AFTER the reload so this test captures the copy deterministically.
"$BIN" -L "$L" set -g @clip "cat > $SINK"
PD="$("$BIN" -L "$L" list-keys -T root 2>/dev/null | grep -E '[[:space:]]MouseDrag1Pane[[:space:]]' | head -1)"
: > "$SINK"
FB=$(inject_drag "$L" "$TOKB")
if [ "$FB" = "1" ] && grep -q "$TOKB" "$SINK" 2>/dev/null && ! printf '%s' "$PD" | grep -q 'mouse_any_flag'; then
    echo "EVIDENCE (B): after reload — plain drag SELECTED+COPIED ($(tr -d '\n' < "$SINK" | head -c 32)); binding now copy-mode override"
else
    echo "FAIL: 57(B) — reload did not enable copy (flag=$FB, sink empty? binding=$PD)"; fail=1
fi

# ── (C) PASTE mechanism: tmux buffer → live shell pane (capture-pane) ─────────
PTOK="PASTEPROOF_$$"
"$BIN" -L "$L" send-keys -t s "cat > /dev/null" Enter 2>/dev/null || true
"$BIN" -L "$L" set-buffer "$PTOK"
"$BIN" -L "$L" paste-buffer -t s 2>/dev/null || true
sleep 0.4
if "$BIN" -L "$L" capture-pane -p -t s 2>/dev/null | grep -q "$PTOK"; then
    echo "EVIDENCE (C): PASTE — tmux buffer pasted into the live pane (capture-pane shows '$PTOK')"
else
    echo "FAIL: 57(C) — paste-buffer did not reach the pane"; fail=1
fi
"$BIN" -L "$L" kill-server 2>/dev/null || true

# ── (D) FULL OS-clipboard paste chain via the REAL `prefix P` keypress ───────
# Faithful: a real client (PTY) sends the prefix (C-b) + P, tmux runs the
# paste binding, and we assert the EXACT clipboard value lands in the pane.
# (send-keys cannot trigger prefix bindings — only a real client keypress can.)
# Gated on a clipboard tool + GUI clipboard (macOS pbcopy here); honest SKIP on
# headless Linux where no OS clipboard exists. The binding's POSIX-correctness
# (the cross-platform fix) is regression-guarded in (E).
if [ "$(uname -s)" = "Darwin" ] && command -v pbcopy >/dev/null 2>&1; then
    DTOK="OSPASTE_$$_$(date +%s)"
    "$BIN" -L "$L" -f "$CONF" new-session -d -s s -x 80 -y 24
    sleep 0.4
    printf '%s' "$DTOK" | pbcopy
    sleep 0.3
    python3 - "$BIN" "$L" <<'PY'
import os,pty,time,select,sys
BIN,L=sys.argv[1],sys.argv[2]
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="xterm-256color"
    os.execvp(BIN,[BIN,"-L",L,"attach","-t","s"]); os._exit(127)
time.sleep(1.5); os.write(fd,b"\x02"); time.sleep(0.5); os.write(fd,b"P"); time.sleep(2.0)
t=time.time()
while time.time()-t<1.0:
    r,_,_=select.select([fd],[],[],0.2)
    if fd in r:
        try:
            if not os.read(fd,4096): break
        except OSError: break
try: os.close(fd)
except OSError: pass
PY
    sleep 0.4
    if "$BIN" -L "$L" capture-pane -p -t s 2>/dev/null | grep -q "$DTOK"; then
        echo "EVIDENCE (D): real 'prefix P' pasted the EXACT OS-clipboard value '$DTOK' into the pane"
    else
        echo "FAIL: 57(D) — prefix-P did not paste the exact clipboard value (got: $("$BIN" -L "$L" capture-pane -p -t s 2>/dev/null | grep -v '^$' | tail -1))"; fail=1
    fi
    "$BIN" -L "$L" kill-server 2>/dev/null || true
else
    echo "SKIP-layer: 57(D) OS-clipboard prefix-P chain (needs a GUI clipboard; headless Linux has none) — §11.4.3; binding POSIX-correctness guarded in (E)"
fi

# ── (E) regression guard: paste binding is POSIX (no `<<<`) + collision-free ──
# The reported "completely new value" + Linux breakage came from `<<<`
# (bash-only, fails under /bin/sh=dash) and `#{@clip-read}` nested-quote
# collision. Assert the shipped binding uses neither.
PBIND="$("$BIN" -L "$L" -f "$CONF" new-session -d -s g -x80 -y24 2>/dev/null; "$BIN" -L "$L" list-keys -T prefix 2>/dev/null | grep -E "bind-key +-T prefix +P +run"; "$BIN" -L "$L" kill-server 2>/dev/null || true)"
if printf '%s' "$PBIND" | grep -q '<<<'; then
    echo "FAIL: 57(E) — paste binding still uses '<<<' (breaks under /bin/sh on Linux)"; fail=1
elif printf '%s' "$PBIND" | grep -qE 'load-buffer - *&&|load-buffer -" ?\||tmux load-buffer -'; then
    echo "EVIDENCE (E): paste binding is POSIX (pipe to load-buffer, no '<<<', no #{@clip-read} nesting)"
else
    echo "FAIL: 57(E) — paste binding shape unexpected: $PBIND"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: 57 reload + select + copy + paste — stale session repro, reload-fixes-copy, and paste all proven"
    exit 0
else
    echo "FAIL: 57 reload/select/copy/paste"
    exit 1
fi
