# interactive_pty_probe.sh — §11.4.3 topology probes for PTY-client tests.
# Sourced by the interactive mouse/copy/lifecycle tests. Each probe returns
# 0 when the required topology is PRESENT (run the test) and 1 when ABSENT
# (caller SKIPs-with-reason). NEVER weakens a real host: on a real terminal
# the PTY-attached tmux client registers a usable size and the probes pass.
#
# Forensic anchor (discriminator 2026-06-30): in a headless sandbox container
# with no real controlling terminal, a python `pty.fork()`-attached tmux client
# registers NO usable terminal size (list-clients width empty/0), so injected
# SGR-1006 mouse drags never map to a pane -> copy-mode never enters
# (pane_in_mode=0, selection empty) EVEN WITH `mouse on`, mouse_any_flag=1, and
# an explicit child TIOCSWINSZ. On a real terminal the client is sized and the
# gesture works (proven v1.0.18/v1.0.21). The probe tests exactly that
# precondition, so it discriminates env-topology-absence from a product defect.

# ipty_mouse_topology_ok <tmux-bin>  -> 0 if a PTY-attached client registers a
# usable (>=10-col) terminal size on this host; 1 otherwise.
ipty_mouse_topology_ok() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" <<'PY' 2>/dev/null
import os,pty,time,subprocess,sys,fcntl,termios,struct
binp=sys.argv[1]; L="iptyprobe%d"%os.getpid()
subprocess.run([binp,"-L",L,"kill-server"],capture_output=True)
subprocess.run([binp,"-L",L,"new-session","-d","-s","p","-x","120","-y","40"],capture_output=True)
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="xterm-256color"
    try: fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack("HHHH",40,120,0,0))
    except Exception: pass
    os.execvp(binp,[binp,"-L",L,"attach","-t","p"]); os._exit(127)
# Poll (not a fixed sleep) so a loaded real host has time to register the client
# attach — eliminates a false-absent flake; ~3s ceiling. Headless never registers
# a usable size regardless of how long we wait, so it still concludes ABSENT.
ok=False
for _ in range(15):
    out=subprocess.run([binp,"-L",L,"list-clients","-F","#{client_width}"],capture_output=True,text=True).stdout.strip()
    if any(w.strip().isdigit() and int(w.strip())>=10 for w in out.splitlines()):
        ok=True; break
    time.sleep(0.2)
try: os.kill(pid,15); os.waitpid(pid,0)
except Exception: pass
subprocess.run([binp,"-L",L,"kill-server"],capture_output=True)
sys.exit(0 if ok else 1)
PY
}

# General alias: the same PTY-client-size check is the honest "is a functional
# interactive terminal available?" gate used by the interactive-shell (43),
# prefix-keystroke (59), and /dev/tty-prompt (68) tests — all of which need a
# real interactive terminal that a headless container's PTY client cannot
# provide (the client registers no usable size, so panes/keystrokes/prompts do
# not function). On a real terminal the probe passes and each test runs.
ipty_interactive_terminal_ok() { ipty_mouse_topology_ok "$@"; }
