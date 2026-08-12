#!/bin/sh
# 58_operator_path_select_copy_ls.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §102 OPERATOR-PATH + §11.4.2/§11.4.52 proof of the operator's
#             EXACT reproduction (2026-05-29):
#               "Open new terminal -> Session name: Test -> Execute ls ->
#                Try to select something and copy".
#             Uses the REAL `scripts/tmx` wrapper to create the session (the
#             same entry point the shell-init prompt invokes), runs `ls` to
#             produce plain-shell content (mouse_any_flag=0 — NOT a
#             mouse-tracking app), injects a REAL SGR-1006 left mouse drag
#             over the ls output through an attached client, and asserts the
#             dragged text reached the clipboard pipe. Then proves the
#             attach-reload fix: a session created with a STALE (pre-fix)
#             binding gets the current binding after `tmx attach` (so
#             re-opening an old session via the prompt is not stuck broken).
# Usage:      bash scripts/tests/58_operator_path_select_copy_ls.sh
# Outputs:    EVIDENCE … ; PASS/FAIL ; honest §11.4.3 SKIP if python3 absent.
# Side-effects: creates + kills its own `tmxcp58` session via the wrapper
#             (operator-path); temp @clip sink. No socket-file pruning.
# Dependencies: scripts/tmx (generated wrapper), tmux binary, python3.
# Cross-refs: scripts/tmx.template attach-reload + reload subcommand ;
#             scripts/tmux.conf.template plain-drag override ; tests 56/57 ;
#             meta-test M-PLAINDRAG / M-TMX-ATTACH-RELOAD.
# Last verified: 2026-05-29
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
TMX="$REPO_ROOT/scripts/tmx"
[ -x "$TMX" ] || { echo "SKIP: 58 — generated scripts/tmx absent (run setup.sh) §11.4.3"; exit 0; }
BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN=$(command -v tmux 2>/dev/null || true)
[ -n "$BIN" ] || { echo "SKIP: 58 — no tmux binary §11.4.3"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: 58 — python3 unavailable §11.4.3"; exit 0; }
# §11.4.3 topology dispatch: PTY-attached tmux client needs a usable terminal
# size for injected SGR mouse drags (discriminator 2026-06-30); headless ⇒ SKIP,
# real terminal ⇒ probe passes and the full proof runs + enforces.
. "$SELF_DIR/lib/interactive_pty_probe.sh"
ipty_mouse_topology_ok "$BIN" || { echo "SKIP: 58 — headless: PTY-attached tmux client registers no usable terminal size; injected SGR mouse drags cannot map to a pane (needs a real interactive terminal) — §11.4.3"; exit 0; }

NAME="tmxcp58_$$"
SOCK="tmx-${NAME}"
SINK=$(mktemp)
cleanup() { "$TMX" kill-session -t "$NAME" 2>/dev/null || true; "$BIN" -L "$SOCK" kill-server 2>/dev/null || true; rm -f "$SINK"; }
trap cleanup EXIT

# inject_drag <socket> <session> : attach a client (mouse-capable TERM) and
# inject a real SGR-1006 left drag over the top rows. Echoes pane_in_mode? no —
# returns nothing; caller checks the @clip sink.
inject_drag() {
    python3 - "$BIN" "$1" "$2" <<'PY'
import os,pty,time,select,sys
BIN,SOCK,SESS=sys.argv[1],sys.argv[2],sys.argv[3]
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="xterm-256color"
    os.execvp(BIN,[BIN,"-L",SOCK,"attach","-t",SESS]); os._exit(127)
time.sleep(1.2)
ESC="\x1b"
def w(s): os.write(fd,s.encode())
w(f"{ESC}[<0;2;1M");  time.sleep(0.15)   # press  (row1)
w(f"{ESC}[<32;40;2M"); time.sleep(0.15)  # drag
w(f"{ESC}[<32;70;3M"); time.sleep(0.15)
w(f"{ESC}[<0;70;3m");  time.sleep(0.4)    # release
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
}

fail=0

# ── (1) OPERATOR PATH: real `tmx new -s NAME` → ls → drag → copy ─────────────
"$TMX" kill-session -t "$NAME" 2>/dev/null || true
"$TMX" new -s "$NAME" -d >/dev/null 2>&1
sleep 1
"$BIN" -L "$SOCK" has-session -t "$NAME" 2>/dev/null || { echo "FAIL: 58(1) — wrapper did not create session"; exit 1; }
# headless capture sink (the copy mechanism is identical to @clip->pbcopy)
"$BIN" -L "$SOCK" set -g @clip "cat > $SINK"
# Shipped config defaults `mouse off` (terminal owns the mouse; tmux's own
# drag-select is ON DEMAND via `prefix m`). This test drives the tmux-mouse-ON
# path the operator reaches with `prefix m`, so enable mouse before injecting
# the real SGR-1006 drag — without it tmux ignores incoming mouse sequences.
"$BIN" -L "$SOCK" set -g mouse on
MAF=$("$BIN" -L "$SOCK" display-message -p -t "$NAME" '#{mouse_any_flag}')
# Run `ls` (the operator's scenario) then print a deterministic, OS-INDEPENDENT
# token at the TOP of the screen via `clear` + a POSIX loop, so the drag has a
# guaranteed target regardless of shell-startup banners (oh-my-bash on Linux
# prints a banner at the top) or `ls` output differences (macOS /etc symlink vs
# a Linux dir). The token-fill is plain-shell output (mouse_any_flag=0) — the
# operator's exact case. Forensic: nezha 2026-05-29 — the macOS-specific
# `grep /etc` matched the symlink target on Darwin but not Linux ls rows, and
# the drag hit the oh-my-bash banner.
LSTOK="LSCOPY58_$$"
"$BIN" -L "$SOCK" send-keys -t "$NAME" "ls -la / >/dev/null 2>&1; clear; for i in 1 2 3 4 5 6 7 8; do echo ${LSTOK}; done" Enter
# CONDITION-BASED WAIT, not a fixed sleep. Forensic (FACT, 2026-08-12): with a
# flat `sleep 1.0` the drag fired while the pane still showed the shell's
# startup banner — the clipboard captured "h-my-bash/check_for_upgrade", and
# since the command above itself runs `clear`, the banner's PRESENCE is
# positive proof the command had not executed yet. oh-my-bash's upgrade check
# pushes the first prompt past 1s on this host, so any fixed timeout is a coin
# flip (§11.4.50 determinism). Poll the LIVE pane until the token is actually
# on screen, then drag against a target we have OBSERVED, never assumed.
_tok_deadline=$(( $(date +%s) + 20 ))
_tok_seen=0
while [ "$(date +%s)" -lt "$_tok_deadline" ]; do
    if "$BIN" -L "$SOCK" capture-pane -p -t "$NAME" 2>/dev/null | grep -q "$LSTOK"; then
        _tok_seen=1; break
    fi
    sleep 0.2
done
if [ "$_tok_seen" -ne 1 ]; then
    # The drag target never rendered, so the copy path was never exercised.
    # PASS would be a §11.4 bluff; FAIL would be a §11.4.1 FAIL-bluff (the copy
    # mechanism is not implicated at all) — SKIP with the real reason (§11.4.3).
    echo "SKIP: 58 — drag-target token never rendered within 20s (shell startup did not reach a deterministic screen); copy path not exercised — §11.4.3"
    exit 0
fi
sleep 0.3   # let the remaining token rows finish painting after the first hit
: > "$SINK"
inject_drag "$SOCK" "$NAME"
sleep 0.3
if [ "$MAF" = "0" ] && grep -q "$LSTOK" "$SINK" 2>/dev/null; then
    echo "EVIDENCE (1): operator-path 'tmx new -s $NAME' PLAIN shell (mouse_any_flag=0) — real mouse drag over shell output SELECTED+COPIED ($(tr -d '\n' < "$SINK" | head -c 40))"
else
    echo "FAIL: 58(1) — plain-shell ls drag did not copy (mouse_any_flag=$MAF, sink=$(tr -d '\n' < "$SINK" | head -c 30))"; fail=1
fi

# ── (2) ATTACH-RELOAD: a STALE-binding session gets current binding on attach ─
"$BIN" -L "$SOCK" bind -n MouseDrag1Pane if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send -M' 'copy-mode -M'
STALE="$("$BIN" -L "$SOCK" list-keys -T root 2>/dev/null | grep -E '[[:space:]]MouseDrag1Pane[[:space:]]' | head -1)"
# `tmx attach` reloads config before attaching; drive it through a PTY client
# (which also detaches when we close the fd) so the source-file runs.
python3 - "$TMX" "$NAME" <<'PY'
import os,pty,time,select,sys
TMX,SESS=sys.argv[1],sys.argv[2]
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="xterm-256color"
    os.execvp(TMX,[TMX,"attach","-t",SESS]); os._exit(127)
time.sleep(1.5)
os.write(fd,b"\x02"); time.sleep(0.2); os.write(fd,b"d")  # prefix d = detach
time.sleep(0.8)
try: os.close(fd)
except OSError: pass
PY
sleep 0.4
NOWB="$("$BIN" -L "$SOCK" list-keys -T root 2>/dev/null | grep -E '[[:space:]]MouseDrag1Pane[[:space:]]' | head -1)"
if printf '%s' "$STALE" | grep -q 'mouse_any_flag' && printf '%s' "$NOWB" | grep -q 'pane_in_mode' && ! printf '%s' "$NOWB" | grep -q 'mouse_any_flag'; then
    echo "EVIDENCE (2): 'tmx attach' reloaded config — stale forwarding binding -> current copy-mode override (re-opening an old session is no longer stuck broken)"
else
    echo "FAIL: 58(2) — tmx attach did not refresh stale binding (was: $STALE / now: $NOWB)"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: 58 operator-path select+copy in a plain ls session + attach-reload of stale sessions"
    exit 0
else
    echo "FAIL: 58 operator-path select/copy"
    exit 1
fi
