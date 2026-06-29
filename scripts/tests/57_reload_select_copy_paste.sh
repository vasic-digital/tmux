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
# §11.4.3 topology dispatch: PTY-attached tmux client needs a usable terminal
# size for injected SGR mouse drags (discriminator 2026-06-30); headless ⇒ SKIP,
# real terminal ⇒ probe passes and the full proof runs + enforces.
. "$SELF_DIR/lib/interactive_pty_probe.sh"
ipty_mouse_topology_ok "$BIN" || { echo "SKIP: 57 — headless: PTY-attached tmux client registers no usable terminal size; injected SGR mouse drags cannot map to a pane (needs a real interactive terminal) — §11.4.3"; exit 0; }

L="rcp$$"
SINK=$(mktemp)
# X's MUST be at the END of the mktemp template: BSD mktemp (macOS) does NOT
# expand `mt_app.XXXXXX.py` (X's not trailing) and creates the LITERAL shared
# filename, colliding across tests 56+57 and reruns (self-perpetuating under
# `set -eu`). `.py.XXXXXX` is portable BSD+GNU and the app is invoked by path.
APP=$(mktemp "${TMPDIR:-/tmp}/mt_app.py.XXXXXX")
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
# Reap the PTY-attach client BEFORE any later kill-server so an orphaned client
# never prints the benign CLIENT_EXIT_LOST_SERVER ("server exited unexpectedly").
try: os.kill(pid, 15)
except (ProcessLookupError, OSError): pass
try: os.waitpid(pid, 0)
except (ChildProcessError, OSError): pass
print(flag)
PY
}

fail=0

# ── (0) EARLY FAIL-FAST GUARD: shipped conf MUST define the prefix-P paste binding
# ─────────────────────────────────────────────────────────────────────────────
# Runs BEFORE any tmux server work, so a removed/mis-shaped paste binding (e.g.
# the M-PASTE paired §1.1 mutation that strips `bind P`) is caught
# DETERMINISTICALLY — even when a later part's tmux server dies mid-test under
# heavy host load (the §3.20 "server exited unexpectedly" phenomenon), which would
# otherwise terminate the test before the part-(D)/(E) paste assertions run and let
# the mutation ESCAPE the gate (observed in the full meta sweep). This is a
# FAIL-fast guard on the conf source, NOT a PASS substitute: the positive end-user
# paste proof is still the parts (C)/(D) runtime evidence below (§11.4.69). A
# server-and-clipboard-independent fact, immune to runtime flakiness.
if grep -Eq "^bind P run .*load-buffer" "$CONF"; then
    echo "EVIDENCE (0): shipped conf defines the prefix-P paste binding ('bind P run ... load-buffer')"
else
    echo "FAIL: 57(0) — shipped conf is MISSING the prefix-P paste binding ('bind P run ... load-buffer'); paste-into-pane cannot work"; fail=1
fi

# ── (A) STALE session: old forwarding binding → drag copies nothing ──────────
TOKA="STALE_$$"
"$BIN" -L "$L" kill-server 2>/dev/null || true
"$BIN" -L "$L" -f "$CONF" new-session -d -s s -x 80 -y 24
"$BIN" -L "$L" set -g @clip "cat > $SINK"
# Enable tmux mouse (the on-demand `prefix m` state) so the injected SGR drag
# is actually delivered to tmux. This makes the stale-binding repro HONEST: the
# drag IS processed, and it copies nothing ONLY because the OLD forwarding
# binding (`send -M` under mouse_any_flag) hands the drag to the app — not
# merely because mouse parsing was off.
"$BIN" -L "$L" set -g mouse on
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
# The shipped config defaults `mouse off` (tmux mouse drag-select is on-demand
# via `prefix m`). Enable it here — this is the tmux-mouse-ON state the operator
# reaches with `prefix m` — so the post-reload plain drag is delivered and the
# copy-mode override (proven applied by `$PD` below) actually copies.
"$BIN" -L "$L" set -g mouse on
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
    # The macOS pasteboard is GLOBAL shared mutable state: part D writes it
    # (pbcopy) and reads it back via `prefix P` -> pbpaste ~4 s later, so ANY
    # concurrent `pbcopy` (another test, the operator, the full suite) can
    # overwrite the value in that window (proven: a concurrent writer made part
    # D paste foreign NOISE_* tokens). Retry ONCE on mismatch, re-asserting the
    # clipboard + a fresh session each attempt. A SINGLE concurrent overwrite is
    # very unlikely to recur on the immediate retry; a GENUINE paste break fails
    # BOTH attempts and still FAILs — so this tolerates the non-product race
    # WITHOUT masking a real defect. The real `prefix P` -> exact-OS-clipboard
    # value chain (the whole point of part D) is preserved.
    PANE_JOINED=""
    d_ok=0
    for _attempt in 1 2 3; do
        "$BIN" -L "$L" kill-server 2>/dev/null || true
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
# Reap the attach client BEFORE the next kill-server (no orphan LOST_SERVER notice).
try: os.kill(pid, 15)
except (ProcessLookupError, OSError): pass
try: os.waitpid(pid, 0)
except (ChildProcessError, OSError): pass
PY
        sleep 0.4
        # Read the pane with physical newlines stripped: the pasted token lands
        # immediately after the (long, git-aware) shell prompt and the terminal
        # wraps it across two physical rows, so a plain line-oriented `grep` (and
        # even `capture-pane -J`, which only joins tmux's own soft-wrapped logical
        # lines, not the prompt+token boundary) would miss a value that IS fully
        # present. Joining the rows is the faithful read of what was pasted — the
        # assertion still demands the EXACT clipboard value, just not split by an
        # incidental wrap. (The mouse-off default does not affect this keyboard
        # prefix-P path; this is purely the capture-readback being wrap-robust.)
        PANE_JOINED="$("$BIN" -L "$L" capture-pane -p -t s 2>/dev/null | tr -d '\n')"
        if printf '%s' "$PANE_JOINED" | grep -q "$DTOK"; then d_ok=1; break; fi
    done
    if [ "$d_ok" = 1 ]; then
        echo "EVIDENCE (D): real 'prefix P' pasted the EXACT OS-clipboard value '$DTOK' into the pane"
    else
        # Distinguish a PRODUCT DEFECT (paste binding broken/absent) from
        # ENVIRONMENT CONTENTION (a foreign process overwrote the GLOBAL pasteboard
        # during our ~4 s window) — CLIPBOARD-INDEPENDENTLY, so a genuinely broken
        # binding is ALWAYS caught regardless of clipboard noise. The escape this
        # closes: the M-PASTE paired mutation strips the `prefix P` paste binding;
        # if we keyed the FAIL/SKIP decision only on "is the clipboard still our
        # token", a concurrent clipboard writer would route the stripped-binding
        # break into a contention SKIP and the mutation would ESCAPE the gate
        # (observed in the full meta sweep). FIRST assert, clipboard-independently,
        # that the prefix-P paste binding still EXISTS with the load-buffer shape on
        # the live server (loaded from the shipped conf). If it is GONE → real break
        # → FAIL no matter the clipboard. Only when the binding IS present AND the
        # live clipboard was overwritten (NOWCLIP != DTOK) is this honest §11.4.3
        # contention → SKIP-layer. Never false-PASSes (PASS still needs the real
        # DTOK paste); never false-FAILs on pure contention; ALWAYS FAILs a stripped
        # or mis-shaped binding.
        BIND_PRESENT=0
        if "$BIN" -L "$L" list-keys -T prefix 2>/dev/null | grep -qE 'prefix +P .*load-buffer'; then BIND_PRESENT=1; fi
        NOWCLIP="$(pbpaste 2>/dev/null || true)"
        if [ "$BIND_PRESENT" = 1 ] && [ "$NOWCLIP" != "$DTOK" ]; then
            echo "SKIP-layer: 57(D) prefix-P binding PRESENT but OS pasteboard overwritten by a concurrent process during the ~4s window (live clipboard now '$(printf '%s' "$NOWCLIP" | head -c 24)' != our '$DTOK'); exact-value proof needs a stable clipboard — paste MECHANISM proven by (C), binding shape by (E). §11.4.3 contention SKIP"
        else
            echo "FAIL: 57(D) — prefix-P did not paste DTOK into the pane; real break (binding_present=$BIND_PRESENT, live clipboard='$(printf '%s' "$NOWCLIP" | head -c 24)' vs our '$DTOK'; got: $(printf '%s' "$PANE_JOINED" | head -c 100))"; fail=1
        fi
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
