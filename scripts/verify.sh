#!/usr/bin/env bash
# verify.sh — gate that decides whether the built tmux binary is
# production-ready. Runs the full test suite and reports a single verdict:
#   exit 0 → green: safe to PATH-export and use (setup.sh will proceed)
#   exit 1 → red:   one or more tests failed; PATH export is REFUSED
#                   (this implements the §11.4 anti-bluff requirement —
#                    we never expose unverified tooling to the operator)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_BIN="${TMUX_BIN:-$REPO_ROOT/tmux/build/bin/tmux}"
WRAPPER="${WRAPPER:-$REPO_ROOT/scripts/tmx}"
export TMUX_BIN WRAPPER

echo "════════════════════════════════════════════════════════════════"
echo "  tmux verification gate (per §11.4 anti-bluff covenant)"
echo "════════════════════════════════════════════════════════════════"

# Pre-check: binary must exist and be executable
if [ ! -x "$TMUX_BIN" ]; then
    echo ""
    echo "RED: $TMUX_BIN is not executable."
    echo "     Did the containerized build complete successfully?"
    echo "     Run: bash scripts/build_containerized.sh"
    exit 1
fi

# Pre-check: dynamic deps must resolve. Use ldd on Linux, otool on Darwin.
HOST_OS_VERIFY="$(uname -s)"
case "$HOST_OS_VERIFY" in
    Darwin)
        # otool -L lists Mach-O LC_LOAD_DYLIB entries. Failure modes:
        # missing dylib produces "image not found"; codesign issues
        # produce "killed" — actually exec the binary briefly to confirm.
        if ! "$TMUX_BIN" -V >/dev/null 2>&1; then
            echo ""
            echo "RED: $TMUX_BIN failed to execute (dylib resolution or codesign):"
            "$TMUX_BIN" -V 2>&1 | head -5
            otool -L "$TMUX_BIN" | sed 's/^/  /'
            exit 1
        fi
        ;;
    Linux)
        if ! ldd "$TMUX_BIN" >/dev/null 2>&1 || ldd "$TMUX_BIN" 2>&1 | grep -q 'not found'; then
            echo ""
            echo "RED: $TMUX_BIN has unresolved dynamic dependencies:"
            ldd "$TMUX_BIN" | grep -E 'not found|error'
            exit 1
        fi
        ;;
esac
echo ""
echo "  ✓ binary exists, dynamic deps resolved ($HOST_OS_VERIFY)"

# Run the full test suite
echo ""
echo "  running test suite..."
if bash "$REPO_ROOT/scripts/tests/run_all.sh"; then
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  GREEN: tmux binary verified — safe to PATH-export."
    echo "════════════════════════════════════════════════════════════════"
    exit 0
else
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  RED: one or more tests failed."
    echo "  setup.sh will REFUSE to PATH-export the binary."
    echo "  Investigate test output above; the binary is NOT operator-safe."
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
