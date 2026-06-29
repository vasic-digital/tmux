#!/usr/bin/env bash
# build_oom_set.sh — compile oom_set.c and install it with CAP_SYS_RESOURCE,
# enabling the tmx wrapper to set oom_score_adj=-500 without
# requiring the operator to run tmux as root.
#
# This is Option B from docs/guides/TMUX_OPTIMIZED_BUILD.md §8.
#
# Usage:
#   bash scripts/build_oom_set.sh           — build only (no root needed)
#   (as root) bash scripts/build_oom_set.sh --install  — build + install + setcap
#
# Output:
#   <project>/scripts/oom_set       (binary, no special perms)
#   /usr/local/bin/tmx-oom-set    (with --install: setcap'd binary)

set -euo pipefail

# OS gate: oom_set.c uses Linux-only headers (sys/capability.h) and writes
# to /proc/<pid>/oom_score_adj — a Linux-specific procfs interface.
# On Darwin there's no procfs, no cap_sys_resource. SKIP cleanly.
HOST_OS="$(uname -s)"
if [ "$HOST_OS" != "Linux" ]; then
    echo "[build_oom_set] SKIP: $HOST_OS doesn't have /proc/<pid>/oom_score_adj"
    echo "                this helper is Linux-specific. On macOS, sessions"
    echo "                use POSIX RLIMIT_CPU + RLIMIT_NPROC instead."
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/oom_set.c"
OUT="$REPO_ROOT/scripts/oom_set"
INSTALL_PATH="/usr/local/bin/tmx-oom-set"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
    esac
done

# Compile (no root needed)
echo "[build_oom_set] compiling $SRC..."
gcc -O2 -Wall -Wextra -Werror -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 \
    -o "$OUT" "$SRC"
chmod 755 "$OUT"
echo "  ✓ wrote $OUT ($(stat -c %s "$OUT") bytes)"
echo ""
echo "  smoke-test (should print usage, exit 1):"
"$OUT" 2>&1 | sed 's/^/    /' || true
echo ""

if [ "$INSTALL" -eq 1 ]; then
    if [ "$(id -u)" != "0" ]; then
        echo "ERROR: --install requires root (it copies to /usr/local/bin and runs setcap)."
        echo "  Re-run as root: bash $0 --install"
        exit 2
    fi
    echo "[build_oom_set] installing as $INSTALL_PATH with cap_sys_resource+ep..."
    install -m 755 "$OUT" "$INSTALL_PATH"
    setcap cap_sys_resource+ep "$INSTALL_PATH"
    echo "  ✓ installed: $INSTALL_PATH"
    echo "  ✓ getcap shows: $(getcap "$INSTALL_PATH")"
    echo ""
    echo "Now re-run: bash scripts/setup.sh"
    echo "  (setup will detect the helper and Test 08 will PASS)"
else
    echo "[build_oom_set] build complete (no install)."
    echo "  To install with setcap (one-time, requires root):"
    echo "    (as root) bash $0 --install"
fi
