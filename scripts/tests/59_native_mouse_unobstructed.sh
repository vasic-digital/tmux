#!/bin/sh
# 59_native_mouse_unobstructed.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.2/§11.4.5/§11.4.52/§11.4.69 WIRE-LEVEL proof that, by
#             DEFAULT, tmux does NOT capture the mouse — so the OUTER terminal
#             keeps full native control: drag-select (multi-line), right-click
#             -> Copy, and native scroll all work on EVERY emulator + OS.
#
#             Root cause of the long copy/paste saga (operator reports
#             2026-05-28 .. 2026-06-13, across iTerm2 / Terminal.app / Linux /
#             WezTerm): with `set -g mouse on`, tmux emits mouse-tracking
#             DECSET enables (CSI ?1000h / ?1002h / ?1006h) to the emulator on
#             attach, putting it into mouse-reporting mode, which SUPPRESSES the
#             terminal's own native selection and right-click->Copy. No tmux
#             binding can intercept a terminal's right-click->Copy menu; the
#             only way it ALWAYS works is to let the terminal own the mouse.
#
#             New architecture (operator decision 2026-06-13): default
#             `mouse off` (terminal owns the mouse). tmux mouse scrollback +
#             tmux drag-select-to-clipboard remain available ON DEMAND via the
#             `prefix m` toggle (which flips `mouse on`, at which point tmux
#             DOES emit the enables — proven in phase 2 below).
#
# Contract asserted (all three):
#   1. The shipped conf default is `set -g mouse off`.
#   2. On attach with the default conf, tmux emits ZERO mouse-enable DECSET
#      (?1000h / ?1002h / ?1003h / ?1006h) — native mouse unobstructed.
#   3. After `prefix m`, tmux emits a mouse-enable DECSET — tmux mouse on demand.
#
# Usage:      sh scripts/tests/59_native_mouse_unobstructed.sh
# Outputs:    EVIDENCE … ; PASS/FAIL ; honest SKIP (§11.4.3) when python3/tmux
#             is unavailable (the wire capture needs a real PTY).
# Side-effects: throwaway tmux server on a private socket label (trap-cleaned).
# Dependencies: tmux (built or system >=3.x), python3 (stdlib pty).
# Cross-refs: scripts/tmux.conf.template `set -g mouse off` + `bind m` toggle ;
#             verify.sh L1 "mouse off default" gate ; meta-test M-MOUSEDEFAULT ;
#             test 55 (toggle binding presence) ; test 56 (tmux drag copy when
#             mouse toggled on) ; forensic anchor operator report 2026-06-13.
# Last verified: 2026-06-13
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
CONF="$REPO_ROOT/scripts/tmux.conf.template"
[ -r "$CONF" ] || { echo "FAIL: 59 — $CONF missing"; exit 1; }

BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN=$(command -v tmux 2>/dev/null || true)
[ -n "$BIN" ] || { echo "SKIP: 59 — no tmux binary (§11.4.3 topology)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: 59 — python3 unavailable (§11.4.3 topology)"; exit 0; }
# §11.4.3 topology dispatch: the substantive contracts drive `prefix m` over a
# PTY-attached tmux client, which a headless container cannot provide (the client
# registers no usable terminal size, so keystrokes/mouse toggles do not function
# — discriminator 2026-06-30). The static `mouse off` default is independently
# guarded by verify.sh Layer-1. SKIP here; a real terminal runs the full proof.
. "$SELF_DIR/lib/interactive_pty_probe.sh"
ipty_interactive_terminal_ok "$BIN" || { echo "SKIP: 59 — headless: no functional interactive terminal (PTY-attached tmux client registers no usable size); 'prefix m' toggle cannot be driven (needs a real terminal) — §11.4.3"; exit 0; }

fail=0

# ── Contract 1: default is `mouse off` (static conf assertion) ──────────────
if grep -Eq '^set -g +mouse +off\b' "$CONF"; then
    echo "EVIDENCE: shipped conf default is 'set -g mouse off' (terminal owns the mouse)"
else
    echo "FAIL: 59 — conf default is NOT 'set -g mouse off' (tmux still captures the mouse, suppressing native select + right-click->Copy)"
    fail=1
fi

# ── Contracts 2 + 3: wire-level capture over a real PTY ─────────────────────
L="nativemouse$$"
"$BIN" -L "$L" kill-server 2>/dev/null || true
"$BIN" -L "$L" -f "$CONF" new-session -d -s s -x 80 -y 24 'sh'
cleanup() { "$BIN" -L "$L" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# Phase 1: attach with the DEFAULT config, capture the byte stream tmux sends to
#          the emulator. Phase 2: send `prefix m` (C-b m) to toggle mouse on,
#          capture again. Count mouse-ENABLE DECSET (CSI ?100{0,2,3,6} h) in each.
RES=$(python3 - "$BIN" "$L" <<'PY'
import os,sys,pty,select,time,re
BIN,L=sys.argv[1],sys.argv[2]
pid,fd=pty.fork()
if pid==0:
    # Real desktop terminals advertise a mouse-capable TERM; "dumb" makes tmux
    # skip mouse handling and would mask the proof (forensic anchor nezha
    # 2026-05-29). End users are unaffected.
    os.environ["TERM"]="xterm-256color"
    os.execv(BIN,[BIN,"-L",L,"attach","-t","s"]); os._exit(127)

def drain(seconds):
    buf=b""; t0=time.time()
    while time.time()-t0<seconds:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try: d=os.read(fd,65536)
            except OSError: break
            if not d: break
            buf+=d
    return buf

ENABLE=re.compile(rb'\x1b\[\?(?:1000|1002|1003|1006)h')
phase1=drain(2.0)                       # DEFAULT state (expect mouse off)
os.write(fd,b'\x02m'); time.sleep(0.2)  # prefix C-b + m  -> toggle mouse on
# Nudge a redraw so the new mouse state is flushed to the client.
os.write(fd,b'\x02r')
phase2=drain(2.0)                        # after toggle (expect mouse on)
os.write(fd,b'\x02d'); time.sleep(0.3)  # detach
try: os.waitpid(pid,os.WNOHANG)
except Exception: pass
print("P1_ENABLE=%d P2_ENABLE=%d" % (len(ENABLE.findall(phase1)),
                                     len(ENABLE.findall(phase2))))
PY
)
P1=$(printf '%s' "$RES" | sed -n 's/.*P1_ENABLE=\([0-9]*\).*/\1/p')
P2=$(printf '%s' "$RES" | sed -n 's/.*P2_ENABLE=\([0-9]*\).*/\1/p')
[ -n "$P1" ] || P1=-1
[ -n "$P2" ] || P2=-1

# Contract 2: default attach must NOT enable terminal mouse reporting.
if [ "$P1" = "0" ]; then
    echo "EVIDENCE: default attach emitted 0 mouse-enable DECSET (?1000h/?1002h/?1006h) — native selection + right-click->Copy + native scroll UNOBSTRUCTED"
else
    echo "FAIL: 59 — default attach emitted $P1 mouse-enable DECSET; tmux is capturing the mouse and suppressing native selection/right-click->Copy"
    fail=1
fi

# Contract 3: `prefix m` must make tmux mouse available on demand.
if [ "$P2" -ge 1 ] 2>/dev/null; then
    echo "EVIDENCE: after 'prefix m' tmux emitted $P2 mouse-enable DECSET — tmux scrollback + drag-copy available on demand"
else
    echo "FAIL: 59 — 'prefix m' did NOT enable tmux mouse (phase-2 enables=$P2); the on-demand tmux-mouse path is broken"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: 59 native terminal mouse is unobstructed by default (select + right-click->Copy + scroll), tmux mouse on demand via prefix m"
    exit 0
else
    echo "FAIL: 59 native-mouse-unobstructed contract"
    exit 1
fi
