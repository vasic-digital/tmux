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
_l1 "@clip user option"            '^set +-g +@clip '
_l1 "copy-mode-vi y -> @clip"      '^bind +-T +copy-mode-vi +y .*copy-pipe-and-cancel.*@clip'
_l1 "copy-mode-vi Enter -> @clip"  '^bind +-T +copy-mode-vi +Enter .*copy-pipe-and-cancel.*@clip'
_l1 "MouseDragEnd1Pane -> @clip"   '^bind +-T +copy-mode-vi +MouseDragEnd1Pane .*copy-pipe-and-cancel.*@clip'
# v1.0.15 additions — multi-line drag override + paste-IN. Forensic
# anchor: operator mandate 2026-05-28 (copy/paste in Claude Code).
# Paired runtime evidence: tests 45 / 46 / 47 / 48.
_l1 "@clip-read user option"        '^set +-g +@clip-read '
# prefix+P paste binding: POSIX inline OS-adaptive probe piped to load-buffer
# (the 2026-05-29 fix) OR a legacy @clip-read reference. Must paste via buffer.
_l1 "prefix+P paste binding"        '^bind +P +run.*paste-buffer'
# v1.0.18: plain-drag ALWAYS enters copy-mode (select+copy in mouse-tracking
# apps like Claude Code). Forensic anchor: user report 2026-05-29.
_l1 "plain-drag copy-mode override" '^bind +-n +MouseDrag1Pane +if.*copy-mode'
# v1.0.17: prefix+m mouse toggle (native-terminal selection escape hatch).
_l1 "prefix+m mouse toggle"         '^bind +m +set +-g +mouse'
_l1 "M-MouseDrag1Pane override"     '^bind +-n +M-MouseDrag1Pane +.*copy-mode'
_l1 "S-MouseDrag1Pane override"     '^bind +-n +S-MouseDrag1Pane +.*copy-mode'
_l1 "M-MouseDragEnd1Pane -> @clip"  '^bind +-T +copy-mode-vi +M-MouseDragEnd1Pane +.*copy-pipe-and-cancel.*@clip'
_l1 "S-MouseDragEnd1Pane -> @clip"  '^bind +-T +copy-mode-vi +S-MouseDragEnd1Pane +.*copy-pipe-and-cancel.*@clip'
# Synthetic alt-screen TUI helper for tests 47 / 48.
if [ -f "$REPO_ROOT/scripts/tests/helpers/synthetic_alt_screen_app.py" ]; then
    echo "    ✓ helper synthetic_alt_screen_app.py present"
else
    echo "    ✗ MISSING: scripts/tests/helpers/synthetic_alt_screen_app.py"
    L1_FAIL=1
fi
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

# ── Layer-1 — §11.4.87..98 anchor propagation (constitution 6828ff2) ────
# Each anchor heading MUST appear (as a literal `11.4.NN` token) in
# every consumer governance file. PWU-B v1.0.15 propagated all 12;
# this gate refuses to install if any consumer drifts.
echo ""
echo "  Layer-1 static gate — §11.4.87..98 propagation across governance..."
L1C_FAIL=0
_l1c() {
    local anchor="$1"
    local f
    for f in Constitution.md CLAUDE.md AGENTS.md QWEN.md; do
        if ! grep -q "$anchor" "$REPO_ROOT/$f"; then
            echo "    ✗ CM-COVENANT-114-${anchor#11.4.}-PROPAGATION missing in $f"
            L1C_FAIL=1
        fi
    done
}
for n in 87 88 89 90 91 92 93 94 95 96 97 98 99; do
    _l1c "11.4.$n"
done
if [ "$L1C_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: one or more §11.4.87..98 anchor literals missing from"
    echo "     a governance consumer file. Run PWU-B propagation again."
    exit 1
fi
echo "  ✓ Layer-1 §11.4.87..98 propagation gates (12) GREEN"

# ── Layer-1 — §11.4.93/95 workable-items DB present + tracked ──────────
# DB MUST exist at docs/workable_items.db AND be tracked in git
# (§11.4.95 explicit carve-out from §11.4.30).
echo ""
echo "  Layer-1 static gate — §11.4.93/95 workable-items DB..."
L1D_FAIL=0
if [ -f "$REPO_ROOT/docs/workable_items.db" ]; then
    echo "    ✓ docs/workable_items.db present"
else
    echo "    ✗ MISSING: docs/workable_items.db"
    L1D_FAIL=1
fi
if git -C "$REPO_ROOT" ls-files --error-unmatch docs/workable_items.db >/dev/null 2>&1; then
    echo "    ✓ docs/workable_items.db tracked in git (§11.4.95 carve-out honoured)"
else
    echo "    ✗ docs/workable_items.db NOT tracked in git (§11.4.95 violation)"
    L1D_FAIL=1
fi
if [ -f "$REPO_ROOT/cmd/workable-items/main.go" ] && [ -f "$REPO_ROOT/cmd/workable-items/schema.sql" ]; then
    echo "    ✓ cmd/workable-items/ scaffold present (project-local Phase 3+)"
else
    echo "    ✗ MISSING: cmd/workable-items/{main.go,schema.sql}"
    L1D_FAIL=1
fi
if [ "$L1D_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: workable-items DB / scaffold incomplete. Build via:"
    echo "       cd cmd/workable-items && go build && ./workable-items sync md-to-db ..."
    exit 1
fi
echo "  ✓ Layer-1 workable-items DB gate GREEN"

# ── Layer-1 — §11.4.65 DOCX export sibling presence ────────────────────
# Every .md in the export allowlist MUST have a .docx sibling whose
# mtime is ≥ source .md mtime. Sample-check (full check is in the
# export script's exit code; this is a regression guard).
echo ""
echo "  Layer-1 static gate — §11.4.65 DOCX export siblings..."
L1E_FAIL=0
L1E_MISS=0
for md in \
    "$REPO_ROOT/README.md" \
    "$REPO_ROOT/CLAUDE.md" \
    "$REPO_ROOT/AGENTS.md" \
    "$REPO_ROOT/QWEN.md" \
    "$REPO_ROOT/Constitution.md" \
    "$REPO_ROOT/docs/Issues.md" \
    "$REPO_ROOT/docs/Fixed.md" \
    "$REPO_ROOT/docs/CONTINUATION.md" \
  ; do
    [ -f "$md" ] || continue
    docx="${md%.md}.docx"
    if [ ! -f "$docx" ]; then
        echo "    ✗ CM-DOCX-EXPORT-SYNC missing sibling: $docx"
        L1E_FAIL=1
        L1E_MISS=$((L1E_MISS + 1))
    fi
done
if [ "$L1E_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: $L1E_MISS canonical doc(s) missing a .docx sibling. Run:"
    echo "       bash scripts/sync_all_markdown_exports.sh"
    exit 1
fi
echo "  ✓ Layer-1 DOCX export-sibling gate GREEN"

# ── Layer-1 static gates for v1.0.9 shell-session-resume PWUs (P5) ──────
# Spec: docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md §7.
# Each gate is fail-fast: prints [PASS]/[FAIL]/[WARN], returns 0 on PASS,
# non-0 on FAIL. Function names follow the _check_CM_<gate-id> convention.
# Constitution: §11.4.67 (POSIX target-shell parseability), §11.4.18
# (script-companion docs), §11.4.44 (revision header), §11.4.4 (four-layer
# coverage — these are layer 1).

echo ""
echo "  Layer-1 static gates — v1.0.9 shell-session-resume PWUs..."

# CM-TMX-STATE-GO-MOD-EXISTS — Go module declaration intact.
_check_CM_TMX_STATE_GO_MOD_EXISTS() {
    local f="$REPO_ROOT/scripts/tmx-state/go.mod"
    if [ ! -f "$f" ]; then
        printf '[FAIL] %s missing scripts/tmx-state/go.mod\n' "CM-TMX-STATE-GO-MOD-EXISTS"
        return 1
    fi
    local first_line
    first_line=$(head -1 "$f")
    case "$first_line" in
        "module digital.vasic.tmx-state")
            printf '[PASS] %s\n' "CM-TMX-STATE-GO-MOD-EXISTS"
            return 0
            ;;
        *)
            printf '[FAIL] %s first line is "%s" — expected "module digital.vasic.tmx-state"\n' \
                "CM-TMX-STATE-GO-MOD-EXISTS" "$first_line"
            return 1
            ;;
    esac
}

# CM-TMX-STATE-GO-PRESENT — Go toolchain >= 1.21 available on PATH.
_check_CM_TMX_STATE_GO_PRESENT() {
    if ! command -v go >/dev/null 2>&1; then
        printf '[FAIL] %s `go` not on PATH (install: https://go.dev/dl/ or `brew install go`)\n' \
            "CM-TMX-STATE-GO-PRESENT"
        return 1
    fi
    # Parse `go version go1.X.Y …` — take the third token, strip the leading "go".
    local raw ver major minor
    raw=$(go version 2>/dev/null)
    ver=$(printf '%s\n' "$raw" | awk '{print $3}' | sed 's/^go//')
    major=$(printf '%s\n' "$ver" | awk -F. '{print $1}')
    minor=$(printf '%s\n' "$ver" | awk -F. '{print $2}')
    if [ -z "$major" ] || [ -z "$minor" ]; then
        printf '[FAIL] %s could not parse `go version` output: %s\n' \
            "CM-TMX-STATE-GO-PRESENT" "$raw"
        return 1
    fi
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 21 ]; }; then
        printf '[FAIL] %s go %s is too old (require >= 1.21)\n' \
            "CM-TMX-STATE-GO-PRESENT" "$ver"
        return 1
    fi
    printf '[PASS] %s (go %s)\n' "CM-TMX-STATE-GO-PRESENT" "$ver"
    return 0
}

# CM-TMX-SHELL-INIT-POSIX — §11.4.67 target-shell parseability for the
# shell-init template (sh -n clean after placeholder substitution).
_check_CM_TMX_SHELL_INIT_POSIX() {
    local f="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
    if [ ! -f "$f" ]; then
        printf '[FAIL] %s missing %s\n' "CM-TMX-SHELL-INIT-POSIX" "$f"
        return 1
    fi
    local tmp
    tmp=$(mktemp 2>/dev/null) || { printf '[FAIL] %s mktemp failed\n' "CM-TMX-SHELL-INIT-POSIX"; return 1; }
    # Substitute __PROJECT__ + __DATE__ with safe defaults that produce
    # a syntactically-clean POSIX script — same shape setup.sh emits.
    sed -e "s|__PROJECT__|/tmp/tmx-verify-stub|g" \
        -e "s|__DATE__|1970-01-01|g" "$f" > "$tmp"
    local parse_out
    parse_out=$(sh -n "$tmp" 2>&1) || {
        printf '[FAIL] %s sh -n FAILED: %s\n' "CM-TMX-SHELL-INIT-POSIX" "$parse_out"
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    printf '[PASS] %s\n' "CM-TMX-SHELL-INIT-POSIX"
    return 0
}

# CM-TMX-SSH-DISPATCH-POSIX — §11.4.67 target-shell parseability for the
# SSH dispatcher template (sh -n clean after placeholder substitution).
_check_CM_TMX_SSH_DISPATCH_POSIX() {
    local f="$REPO_ROOT/scripts/tmx-ssh-dispatch.sh.template"
    if [ ! -f "$f" ]; then
        printf '[FAIL] %s missing %s\n' "CM-TMX-SSH-DISPATCH-POSIX" "$f"
        return 1
    fi
    local tmp
    tmp=$(mktemp 2>/dev/null) || { printf '[FAIL] %s mktemp failed\n' "CM-TMX-SSH-DISPATCH-POSIX"; return 1; }
    sed -e "s|__PROJECT__|/tmp/tmx-verify-stub|g" \
        -e "s|__DATE__|1970-01-01|g" "$f" > "$tmp"
    local parse_out
    parse_out=$(sh -n "$tmp" 2>&1) || {
        printf '[FAIL] %s sh -n FAILED: %s\n' "CM-TMX-SSH-DISPATCH-POSIX" "$parse_out"
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    printf '[PASS] %s\n' "CM-TMX-SSH-DISPATCH-POSIX"
    return 0
}

# CM-TMX-DOCS-GUIDES-EXIST — §11.4.18 script-companion docs each carry
# the §11.4.44 revision header (Revision + Last modified) in the first
# 10 lines. User-guide docs under docs/guides/ are PERMISSIVE for this
# pre-P8 phase: WARN only.
# TODO: After P8 lands (docs/guides/tmx-*.md authored), promote the
# four `docs/guides/tmx-*.md` paths from WARN to strict-FAIL.
_check_CM_TMX_DOCS_GUIDES_EXIST() {
    local rc=0
    local d
    # Strict: §11.4.18 script-companion docs (P1-P4 deliverables).
    for d in \
        docs/scripts/tmx-state.md \
        docs/scripts/tmx-shell-init.md \
        docs/scripts/tmx-ssh-install.md \
        docs/scripts/tmx-ssh-dispatch.md ; do
        local p="$REPO_ROOT/$d"
        if [ ! -f "$p" ]; then
            printf '[FAIL] %s missing %s\n' "CM-TMX-DOCS-GUIDES-EXIST" "$d"
            rc=1
            continue
        fi
        local head10
        head10=$(head -10 "$p")
        if ! printf '%s\n' "$head10" | grep -q '\*\*Revision:\*\*' \
            || ! printf '%s\n' "$head10" | grep -q '\*\*Last modified:\*\*'; then
            printf '[FAIL] %s %s lacks Revision/Last-modified header in first 10 lines (§11.4.44)\n' \
                "CM-TMX-DOCS-GUIDES-EXIST" "$d"
            rc=1
        fi
    done
    # Permissive: docs/guides/* are the P8 deliverables. WARN only,
    # promotes to strict-FAIL after P8 lands.
    for d in \
        docs/guides/tmx-shell-integration.md \
        docs/guides/tmx-state.md \
        docs/guides/tmx-ssh-dispatch.md ; do
        local p="$REPO_ROOT/$d"
        if [ ! -f "$p" ]; then
            printf '[WARN] %s %s not yet present (P8 deliverable — strict after P8 lands)\n' \
                "CM-TMX-DOCS-GUIDES-EXIST" "$d"
            continue
        fi
        local head10
        head10=$(head -10 "$p")
        if ! printf '%s\n' "$head10" | grep -q '\*\*Revision:\*\*' \
            || ! printf '%s\n' "$head10" | grep -q '\*\*Last modified:\*\*'; then
            printf '[WARN] %s %s exists but lacks Revision/Last-modified header (§11.4.44)\n' \
                "CM-TMX-DOCS-GUIDES-EXIST" "$d"
        fi
    done
    if [ "$rc" -eq 0 ]; then
        printf '[PASS] %s (script-companion docs strict; user-guides WARN until P8)\n' \
            "CM-TMX-DOCS-GUIDES-EXIST"
    fi
    return "$rc"
}

# Run the five new gates. Aggregate failure into V109_FAIL — Layer 1 must
# stay fail-fast, so any FAIL aborts before the runtime suite (binary is
# NOT operator-safe with broken P1-P4 artefacts).
V109_FAIL=0
_check_CM_TMX_STATE_GO_MOD_EXISTS || V109_FAIL=1
_check_CM_TMX_STATE_GO_PRESENT    || V109_FAIL=1
_check_CM_TMX_SHELL_INIT_POSIX    || V109_FAIL=1
_check_CM_TMX_SSH_DISPATCH_POSIX  || V109_FAIL=1
_check_CM_TMX_DOCS_GUIDES_EXIST   || V109_FAIL=1
if [ "$V109_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: one or more v1.0.9 PWU pre-build gates FAILed. Investigate"
    echo "     individual [FAIL] lines above. setup.sh will REFUSE."
    exit 1
fi
echo "  ✓ Layer-1 v1.0.9 PWU gates GREEN"

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
