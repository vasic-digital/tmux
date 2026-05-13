#!/usr/bin/env bash
# Test 03 — jemalloc verification: when launched with our wrapper
# (LD_PRELOAD=jemalloc on Linux, DYLD_INSERT_LIBRARIES on Darwin OR linked
# directly), the running tmux process has libjemalloc mapped in its
# address space.
#
# Portable across Linux + macOS:
#   - jemalloc lookup: ldconfig (Linux) or brew --prefix (Darwin)
#   - preload env-var: LD_PRELOAD (Linux) or DYLD_INSERT_LIBRARIES (Darwin)
#   - mapped-library check: /proc/PID/maps (Linux) or vmmap/lsof (Darwin)
set -euo pipefail
TMUX_BIN="${TMUX_BIN:?}"
SOCKET="/tmp/tmx_test_$$"
echo "── Test 03: jemalloc loaded ──"

HOST_OS="$(uname -s)"
JEM=""
case "$HOST_OS" in
    Darwin)
        if command -v brew >/dev/null 2>&1; then
            JEM_CANDIDATE="$(brew --prefix jemalloc 2>/dev/null)/lib/libjemalloc.dylib"
            [ -f "$JEM_CANDIDATE" ] && JEM="$JEM_CANDIDATE"
        fi
        ;;
    *)
        for _LDCFG in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
            command -v "$_LDCFG" >/dev/null 2>&1 || continue
            JEM=$("$_LDCFG" -p 2>/dev/null | awk '/libjemalloc\.so\.[0-9]/ {print $NF; exit}' || true)
            [ -n "$JEM" ] && break
        done
        ;;
esac
if [ -z "$JEM" ]; then
    echo "SKIP: jemalloc not visible (not installed on this host)"
    echo "       Linux: install via package manager; Darwin: brew install jemalloc"
    exit 0
fi
echo "  using jemalloc preload: $JEM"

case "$HOST_OS" in
    Darwin)
        DYLD_INSERT_LIBRARIES="$JEM" DYLD_FORCE_FLAT_NAMESPACE=1 \
            "$TMUX_BIN" -S "$SOCKET" new-session -d -s jemtest "sleep 30"
        ;;
    *)
        LD_PRELOAD="$JEM" "$TMUX_BIN" -S "$SOCKET" new-session -d -s jemtest "sleep 30"
        ;;
esac

sleep 1
PID=$("$TMUX_BIN" -S "$SOCKET" display-message -p '#{pid}' 2>/dev/null || pgrep -f "tmux: server.*$SOCKET" | head -1)
if [ -z "$PID" ]; then
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "FAIL: could not find tmux server PID after launch"
    exit 1
fi

# Check mapped-library list per OS.
FOUND_JEM=0
case "$HOST_OS" in
    Darwin)
        # Darwin: vmmap shows loaded shared libraries; lsof | grep -i jemalloc works too
        if vmmap "$PID" 2>/dev/null | grep -qi jemalloc; then
            FOUND_JEM=1
        elif command -v lsof >/dev/null 2>&1 && lsof -p "$PID" 2>/dev/null | grep -qi jemalloc; then
            FOUND_JEM=1
        fi
        ;;
    *)
        [ -d "/proc/$PID" ] && grep -q jemalloc "/proc/$PID/maps" 2>/dev/null && FOUND_JEM=1
        ;;
esac

if [ "$FOUND_JEM" -eq 1 ]; then
    echo "  ✓ tmux server PID $PID has jemalloc mapped (positive evidence: $(if [ "$HOST_OS" = "Darwin" ]; then echo vmmap; else echo /proc/.../maps; fi))"
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "PASS"
else
    "$TMUX_BIN" -S "$SOCKET" kill-server 2>/dev/null || true
    echo "FAIL: PID $PID did NOT have jemalloc loaded — preload ineffective"
    exit 1
fi
