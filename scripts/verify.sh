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

# ── Layer-1 static source gate (Constitution §103) ──────────────────────
# Catch tmux.conf.template regressions at SOURCE, before the runtime
# suite. A binary can build and link cleanly while the config template
# silently loses a setting — this gate refuses to proceed in that case.
# Paired runtime evidence for each line below lives in test 17 (scroll
# settings) and test 16 (.exe strip); grep here is the source-layer
# half of §102's "static check in addition to runtime readback".
echo ""
echo "  Layer-1 static gate — scripts/tmux.conf.template..."
CONF_TPL="$REPO_ROOT/scripts/tmux.conf.template"
if [ ! -f "$CONF_TPL" ]; then
    echo "RED: $CONF_TPL is missing."
    exit 1
fi
L1_FAIL=0
_l1() {
    if grep -Eq "$2" "$CONF_TPL"; then
        echo "    ✓ $1"
    else
        echo "    ✗ MISSING: $1  (pattern: $2)"
        L1_FAIL=1
    fi
}
_l1 "history-limit 50000"          '^set +-g +history-limit +50000'
_l1 "mode-keys vi"                 '^setw? +-g +mode-keys +vi'
_l1 "WheelUpPane copy-mode bind"   '^bind +-n +WheelUpPane'
_l1 "WheelDownPane bind"           '^bind +-n +WheelDownPane'
_l1 "allow-passthrough on"         '^set +-g +allow-passthrough +on'
_l1 "extended-keys on"             '^set +-s +extended-keys +on'
_l1 "automatic-rename .exe strip"  'automatic-rename-format'
if [ "$L1_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: tmux.conf.template failed the Layer-1 static gate."
    echo "     A required scrollback / copy-mode / passthrough setting is"
    echo "     missing from the config template — the operator would not"
    echo "     get working scrolling. setup.sh will REFUSE to install."
    exit 1
fi
echo "  ✓ Layer-1 static gate GREEN"

# ── Layer-1 static gate — verbatim anti-bluff covenant propagation ──────
# Per the 2026-05-21 mandate: the verbatim user-mandate (2026-04-28)
# MUST be literally present in every consumer governance file, so any
# tool that does not expand @imports still reads the covenant. The
# pointer-block alone is insufficient. Pre-flight refusal here is the
# source-layer half; test 19 is the runtime layer.
echo ""
echo "  Layer-1 static gate — anti-bluff covenant in governance files..."
COVENANT_ANCHOR='We had been in position that all tests do execute with success'
L1B_FAIL=0
_l1b() {
    if grep -qF "$COVENANT_ANCHOR" "$REPO_ROOT/$1"; then
        echo "    ✓ verbatim covenant present in $1"
    else
        echo "    ✗ MISSING: verbatim covenant in $1"
        L1B_FAIL=1
    fi
}
_l1b "Constitution.md"
_l1b "CLAUDE.md"
_l1b "AGENTS.md"
_l1b "QWEN.md"
if [ "$L1B_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: one or more governance files lack the verbatim anti-bluff"
    echo "     covenant block. The mandate (user, 2026-05-21) requires"
    echo "     literal presence in every consumer file, not just the"
    echo "     @import pointer. setup.sh will REFUSE to install."
    exit 1
fi
echo "  ✓ Layer-1 covenant-propagation gate GREEN"

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
