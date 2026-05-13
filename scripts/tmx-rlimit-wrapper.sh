#!/usr/bin/env bash
# tmx-rlimit-wrapper.sh — wrap the operator's shell with kernel-enforced
# POSIX resource limits before exec'ing it inside a tmux pane. This is
# the macOS analogue of Linux's `systemd-run --user --scope` — RLIMIT_AS,
# RLIMIT_CPU, RLIMIT_NPROC are per-process limits enforced by the Darwin
# kernel; children inherit them.
#
# Per-session containment is per-process in the limit hierarchy. The
# strength gap vs. Linux cgroup is documented in docs/GUIDE.md §5.6.
#
# Usage (invoked by scripts/tmx as the session's default command):
#   tmx-rlimit-wrapper.sh <mem-kbytes> <cpu-seconds> <max-procs> <shell> [args…]
#
# Example:
#   tmx-rlimit-wrapper.sh 8388608 86400 4096 /bin/zsh -l
#
# Notes on Darwin `ulimit`:
#   -v  RLIMIT_AS   (virtual memory in kilobytes; KB not bytes!)
#   -t  RLIMIT_CPU  (CPU-seconds; SIGKILL on hard exhaust)
#   -u  RLIMIT_NPROC (max user processes — counts across user not session)
#
# We deliberately do NOT set RLIMIT_RSS (`-m`) because Darwin treats it
# as advisory-only; setting it gives a false sense of containment.

set -u

if [ $# -lt 4 ]; then
    echo "tmx-rlimit-wrapper: usage: $0 <mem-kb> <cpu-sec> <max-procs> <shell> [args…]" >&2
    exit 2
fi

MEM_KB="$1"; shift
CPU_SEC="$1"; shift
PROC_MAX="$1"; shift

# Apply the limits BEFORE exec. Each `ulimit` call sets the limit on the
# current shell; the subsequent `exec` replaces this shell with $SHELL,
# which inherits the limits via the process credentials.
#
# Per-OS enforcement reality (verified 2026-05-13):
#   Linux : RLIMIT_AS / CPU / NPROC all kernel-enforced.
#   Darwin: RLIMIT_AS / DATA / RSS return EINVAL — XNU kernel does NOT
#           enforce memory rlimits for unprivileged processes. Real memory
#           containment requires launchd jobs with HardResourceLimits
#           plist keys (root). RLIMIT_CPU and RLIMIT_NPROC ARE enforced.
#
# We apply -t and -u on both OSes (they work); we try -v silently —
# Linux applies it, Darwin returns EINVAL which we swallow without
# spam. Operator can verify what's enforced via `ulimit -a` in-session.
HOST_OS="$(uname -s)"
case "$HOST_OS" in
    Darwin)
        # Memory rlimit ignored by XNU; do not pretend to apply it.
        # Operator informed via setup.sh + docs/GUIDE.md §5.6.
        :
        ;;
    *)
        ulimit -v "$MEM_KB" 2>/dev/null || true   # RLIMIT_AS (Linux)
        ;;
esac
ulimit -t "$CPU_SEC"  2>/dev/null || true   # RLIMIT_CPU  — both OSes
ulimit -u "$PROC_MAX" 2>/dev/null || true   # RLIMIT_NPROC — both OSes

# Replace this wrapper with the operator's shell. The shell sees the
# full host environment (PATH includes /opt/homebrew/bin, /usr/local/bin,
# system tools; HOME is the operator's home; full filesystem access).
# This is the "plain vanilla tmux UX with containers as safeguards"
# experience the operator mandated.
exec "$@"
