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
# Side-effects: none — uses a throwaway $HOME sandbox (trap-cleaned). Answers
#             every prompt with a blank line so NO tmx session is ever created.
# Dependencies: /bin/bash, python3 (stdlib pty only).
# Cross-refs: scripts/tmx-shell-init.sh.template ; meta-test M-DBLPROMPT ;
#             forensic anchor: user report 2026-05-29, nezha bash -l -i = 2.
# Last verified: 2026-05-29
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
python3 - "$SANDBOX" "$INIT" <<'PY' || rc=$?
import os, pty, select, time, sys
sandbox = sys.argv[1]
init    = sys.argv[2]
PROMPT  = b"Enter session name"
env = dict(os.environ)
env["HOME"] = sandbox
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
