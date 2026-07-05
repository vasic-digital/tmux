#!/bin/sh
# 54_double_prompt_idempotent.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.1/§11.4.98 regression for the bash-login double
#             session-name prompt. A single shell PROCESS that sources
#             tmx-shell-init.sh twice (the real nezha topology: .bash_profile
#             carries the source line AND sources .bashrc which also carries
#             it) MUST show the interactive prompt exactly ONCE.
# Usage:      bash scripts/tests/54_double_prompt_idempotent.sh
# Inputs:     scripts/tmx-shell-init.sh (the generated, .zshrc/.bashrc-sourced
#             file). Run scripts/setup.sh first so it exists.
# Outputs:    EVIDENCE prompt_count=N ; PASS/FAIL line ; exit 0 PASS / 2 FAIL.
# Side-effects: none — uses a throwaway $HOME + private TMUX_TMPDIR sandbox
#             (trap-cleaned). Answers every prompt with a blank line so NO
#             tmx session is ever created. TMUX_TMPDIR isolation is REQUIRED
#             (2026-07-05, §4 wizard-picker redesign): blank input now queries
#             `tmx ls` and diverts into a session-picker sub-prompt whenever
#             ANY session exists on the resolved socket dir — without a
#             private, pre-created (but empty) TMUX_TMPDIR/tmux-$(id -u) dir,
#             `tmx ls` falls through to the REAL host's live sessions
#             (§11.4.111 _our_sockets() only stops at the FIRST *existing*
#             candidate dir), diverting the test into a prompt this driver
#             never answers and masking the double-source guard entirely.
# Dependencies: /bin/bash, python3 (stdlib pty only).
# Cross-refs: scripts/tmx-shell-init.sh.template ; meta-test M-DBLPROMPT ;
#             forensic anchor: user report 2026-05-29, nezha bash -l -i = 2;
#             TMUX_TMPDIR-isolation regression found 2026-07-05 via the
#             M-DBLPROMPT meta-test mutation escaping on a host with live
#             sessions (root-caused, not guessed, per §11.4.102/§11.4.120).
# Last verified: 2026-07-05
# ─────────────────────────────────────────────────────────────────────────
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/../.." && pwd)
INIT="$REPO_ROOT/scripts/tmx-shell-init.sh"

if [ ! -r "$INIT" ]; then
    echo "FAIL: 54 — $INIT missing (run scripts/setup.sh first)"
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: 54 — python3 not available (§11.4.3 topology)"
    exit 0
fi
if [ ! -x /bin/bash ]; then
    echo "SKIP: 54 — /bin/bash not available (§11.4.3 topology)"
    exit 0
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Private, pre-created-but-empty TMUX_TMPDIR socket dir. _our_sockets() (in
# scripts/tmx.template) checks "${TMUX_TMPDIR:-}/tmux-$(id -u)" FIRST and
# only falls back to the real "/tmp/tmux-$(id -u)" if that first candidate
# does NOT exist as a directory — so it must be pre-created (empty) here,
# not merely pointed at, or `tmx ls` (invoked by the wizard's blank-input
# picker) falls through to the operator's real, live sessions.
TMUX_SANDBOX_DIR="$SANDBOX/.tmux_tmpdir"
mkdir -p "$TMUX_SANDBOX_DIR/tmux-$(id -u)"

# Reproduce the nezha double-source topology in ONE process:
#   .bash_profile sources tmx-shell-init  AND  sources .bashrc
#   .bashrc       sources tmx-shell-init  (again, same process)
# Each rc puts the scripts dir on PATH BEFORE sourcing the init — exactly as
# the real deployment does (the VDIGITAL_TMUX_DIR block in the operator's
# .bashrc/.zshrc). This is mandatory because a LOGIN shell sources
# /etc/profile, which on some distros (e.g. ALT Linux on nezha) RESETS PATH
# and would otherwise drop an inherited-env scripts dir, making `tmx`
# unreachable so the init returns at its `command -v tmx` guard before the
# prompt (observed 2026-05-29). Mirroring the rc PATH-add keeps the test
# faithful + portable across macOS and Linux login-shell PATH handling.
SCRIPTS_DIR=$(CDPATH= cd -- "$(dirname -- "$INIT")" && pwd)
cat > "$SANDBOX/.bashrc" <<RC
export PATH="$SCRIPTS_DIR:\$PATH"
[ -r "$INIT" ] && . "$INIT"
RC
cat > "$SANDBOX/.bash_profile" <<RC
export PATH="$SCRIPTS_DIR:\$PATH"
[ -r "$INIT" ] && . "$INIT"
if [ -f "\$HOME/.bashrc" ]; then . "\$HOME/.bashrc"; fi
RC

# Capture python's exit WITHOUT letting `set -e` kill the script before the
# verdict prints — the meta-test greps stdout for the FAIL token, so the
# FAIL line below MUST be emitted on the failure (count!=1) path.
rc=0
python3 - "$SANDBOX" "$INIT" "$TMUX_SANDBOX_DIR" <<'PY' || rc=$?
import os, pty, select, time, sys
sandbox      = sys.argv[1]
init         = sys.argv[2]
tmux_tmpdir  = sys.argv[3]
PROMPT  = b"Enter session name"
env = dict(os.environ)
env["HOME"] = sandbox
env["TMUX_TMPDIR"] = tmux_tmpdir
env.pop("TMUX", None)
env.pop("TMX_SKIP", None)
# tmx must be reachable so the prompt path actually runs (init returns
# silently if `tmx` is not on PATH).
scripts_dir = os.path.dirname(init)
env["PATH"] = scripts_dir + os.pathsep + env.get("PATH", "")

pid, fd = pty.fork()
if pid == 0:
    os.execvpe("/bin/bash", ["/bin/bash", "-l", "-i"], env)
    os._exit(127)

buf = b""
responded = 0
MAXP = 6
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
    # Answer every prompt with a BLANK line (no session ever created).
    if cur > responded and responded < MAXP:
        time.sleep(0.3)
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

n = buf.count(PROMPT)
print("EVIDENCE prompt_count=%d" % n)
sys.exit(0 if n == 1 else 2)
PY

if [ "$rc" -eq 0 ]; then
    echo "PASS: 54 double-prompt idempotent — exactly 1 prompt per shell process"
    exit 0
else
    echo "FAIL: 54 double-prompt — expected exactly 1 prompt per process (see EVIDENCE above)"
    exit 2
fi
