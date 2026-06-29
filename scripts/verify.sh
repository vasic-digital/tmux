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

# ── resolve obtained jemalloc for the RAW $TMUX_BIN — NO patchelf required ──
# The ldd pre-check below + the whole test suite (run_all.sh, which this gate
# invokes) exercise the RAW binary directly, NOT via the `tmx` wrapper. On a
# host with NO system jemalloc AND no patchelf (amber: no sudo), the binary's
# DT_NEEDED libjemalloc.so.2 resolves ONLY if its libdir is on the loader's
# search path — rpath needs patchelf (absent), and the wrapper's LD_PRELOAD
# never touches the raw binary. obtain_local_deps.sh wrote the resolved
# ABSOLUTE libdir into .local-deps/<plat>/resolved.env; export it as
# LD_LIBRARY_PATH (Linux) / DYLD_LIBRARY_PATH (Darwin) so BOTH the ldd gate
# AND every raw-$TMUX_BIN test (run_all.sh children inherit this exported env)
# find jemalloc with NO patchelf. jemalloc STAYS DYNAMIC — this only adds a
# search dir, never a static link (§11.4.111 + research Angle 2,
# docs/research/local_deps_20260628). Harmless when the resolved libdir is
# already a default system path (e.g. /lib64). Guarded on resolved.env
# existing, so on a host that never ran obtain it is a no-op.
_LD_RESOLVED_ENV="$REPO_ROOT/.local-deps/$(uname -s)_$(uname -m)/resolved.env"
if [ -f "$_LD_RESOLVED_ENV" ]; then
    # shellcheck disable=SC1090
    . "$_LD_RESOLVED_ENV"
    if [ -n "${JEMALLOC_LIBDIR:-}" ]; then
        case "$(uname -s)" in
            Darwin) export DYLD_LIBRARY_PATH="${JEMALLOC_LIBDIR}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
            *)      export LD_LIBRARY_PATH="${JEMALLOC_LIBDIR}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
        esac
    fi
fi

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
# v1.0.21 (operator decision 2026-06-13): the shipped DEFAULT is `mouse off` —
# the terminal owns the mouse so native drag-select, right-click->Copy, and
# native scroll work everywhere (Linux + macOS). tmux mouse is on demand via
# `prefix m`. Wire-level runtime proof: test 59. This Layer-1 static gate is the
# source-side guard (§103) that the default is NOT flipped back to `on` (which
# emitted mouse-tracking DECSETs that suppressed native selection/right-click).
_l1 "mouse off (terminal default)" '^set +-g +mouse +off\b'
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

# CM-TMX-WRAPPER-TMUXBIN-VALID — §11.4.135 F1 regression guard at the
# SOURCE layer. The generated `scripts/tmx` wrapper, when present, MUST
# declare `TMUX_BIN=<path>` pointing at an EXISTING, EXECUTABLE binary.
# Forensic anchor (Issues.md F1): a stale `scripts/tmx` carried a TMUX_BIN
# pointing at a non-existent prior-checkout path; the operator shell-init
# `exec sh -c 'tmx attach … || exec tmx new …'` reached `exec "$TMUX_BIN"`
# on the MISSING binary → exec failed (127, "No such file or directory") →
# the operator's login shell DIED → the terminal window closed = "crashes
# the whole terminal". This gate makes setup.sh/verify REFUSE to bless a
# wrapper that points at a missing binary. ABSENT scripts/tmx is NOT a FAIL
# (wrapper not yet generated) — only PRESENT-but-broken is.
_check_CM_TMX_WRAPPER_TMUXBIN_VALID() {
    local w="$REPO_ROOT/scripts/tmx"
    if [ ! -f "$w" ]; then
        printf '[PASS] %s (scripts/tmx not yet generated — nothing to bless)\n' \
            "CM-TMX-WRAPPER-TMUXBIN-VALID"
        return 0
    fi
    local val
    val=$(grep -m1 -E '^TMUX_BIN=' "$w" 2>/dev/null \
        | sed -e 's/^TMUX_BIN=//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
    if [ -z "$val" ]; then
        printf '[FAIL] %s scripts/tmx has no top-level TMUX_BIN= assignment\n' \
            "CM-TMX-WRAPPER-TMUXBIN-VALID"
        return 1
    fi
    if [ ! -e "$val" ]; then
        printf '[FAIL] %s scripts/tmx TMUX_BIN points at MISSING path: %s (F1 terminal-crash surface)\n' \
            "CM-TMX-WRAPPER-TMUXBIN-VALID" "$val"
        return 1
    fi
    if [ ! -x "$val" ]; then
        printf '[FAIL] %s scripts/tmx TMUX_BIN exists but is NOT executable: %s\n' \
            "CM-TMX-WRAPPER-TMUXBIN-VALID" "$val"
        return 1
    fi
    printf '[PASS] %s (TMUX_BIN=%s exists+executable)\n' \
        "CM-TMX-WRAPPER-TMUXBIN-VALID" "$val"
    return 0
}

# CM-NO-DYNAMIC-LIBTINFO — cross-distro portability guard (§11.4.81). The
# containerized Linux build links terminfo STATICALLY
# (docker/build_inside_container.sh: LIBTINFO_LIBS="-l:libtinfo.a") so the ELF
# carries NO libtinfo.so DT_NEEDED entry and therefore cannot emit the
# `/lib64/libtinfo.so.6: no version information available` warning on hosts
# (e.g. ALT Linux on nezha) whose libtinfo lacks the Ubuntu NCURSES6_TINFO
# version nodes. Linux-only invariant: Mach-O has no ELF symbol-versioning, so
# Darwin PASSes by non-applicability. Runtime companion: scripts/tests/61_*.sh.
_check_CM_NO_DYNAMIC_LIBTINFO() {
    if [ "$(uname -s)" != "Linux" ]; then
        printf '[PASS] %s (non-Linux: libtinfo/ELF symbol-versioning N/A)\n' \
            "CM-NO-DYNAMIC-LIBTINFO"
        return 0
    fi
    if [ ! -x "$TMUX_BIN" ]; then
        printf '[PASS] %s (binary not built yet — nothing to inspect)\n' \
            "CM-NO-DYNAMIC-LIBTINFO"
        return 0
    fi
    if ! command -v ldd >/dev/null 2>&1; then
        printf '[PASS] %s (ldd unavailable — deferred to runtime test 61)\n' \
            "CM-NO-DYNAMIC-LIBTINFO"
        return 0
    fi
    local n
    n=$(ldd "$TMUX_BIN" 2>/dev/null | grep -c 'libtinfo' || true)
    if [ "$n" -ne 0 ]; then
        printf '[FAIL] %s tmux dynamically links libtinfo.so (%s dep(s)) — cross-distro version-warning surface; build must static-link tinfo\n' \
            "CM-NO-DYNAMIC-LIBTINFO" "$n"
        return 1
    fi
    printf '[PASS] %s (0 dynamic libtinfo deps — tinfo statically linked)\n' \
        "CM-NO-DYNAMIC-LIBTINFO"
    return 0
}

# CM-RUNALL-OS-AWARE — A2 RUNALL-NATIVE-RESOLVE-001 (§11.4.3/§11.4.81). The
# standalone test runner MUST resolve the OS-appropriate build dir: prefer
# tmux/build-darwin (macOS Mach-O) then fall back to tmux/build (Linux ELF), so
# `bash scripts/tests/run_all.sh` works on BOTH OSes (was: hardcoded tmux/build
# → Exec-format / not-executable on native macOS).
_check_CM_RUNALL_OS_AWARE() {
    local ra="$REPO_ROOT/scripts/tests/run_all.sh"
    if [ ! -f "$ra" ]; then
        printf '[FAIL] %s run_all.sh missing\n' "CM-RUNALL-OS-AWARE"; return 1
    fi
    if grep -q 'tmux/build-darwin/bin/tmux' "$ra" \
       && grep -qE 'TMUX_BIN_DEFAULT=.*build/bin/tmux' "$ra"; then
        printf '[PASS] %s (run_all resolves build-darwin then build)\n' \
            "CM-RUNALL-OS-AWARE"
        return 0
    fi
    printf '[FAIL] %s run_all.sh not OS-aware (missing build-darwin->build fallback)\n' \
        "CM-RUNALL-OS-AWARE"
    return 1
}

# CM-NO-HARDCODED-TMP-SCRATCH — D2 TMPDIR-HARDCODE-001 (§11.4.3/§11.4.50). The
# cwd/state/dispatch tests MUST route scratch through ${TMPDIR:-/tmp} (a SCRATCH
# var) so they SKIP-with-reason on an unwritable scratch root instead of
# false-FAILing under host disk-pressure. Guards against a future test
# re-introducing a hardcoded /tmp scratch ASSIGNMENT. (The SCRATCH fallback
# `="${TMPDIR:-/tmp}"` ends in /tmp} not /tmp/ so it does NOT match; recorded
# VALUE strings like `record k "/tmp/p"` are not assignments and do not match.)
_check_CM_NO_HARDCODED_TMP_SCRATCH() {
    local d="$REPO_ROOT/scripts/tests" bad="" t
    for t in 27_state_persistence 33_state_concurrency 38_stale_pwd_fallback \
             43_e2e_cwd_persist_real_shell 50_cwd_hook_autoinstall \
             28_default_skip 29_default_skip_blank 30_non_tty_skip \
             31_ssh_dispatch_local 34_ssh_install_idempotent \
             35_session_name_validation 36_dispatcher_rejects_multiword \
             37_nested_tmux_skip 40_macos_linux_parity \
             49_tmx_shell_init_guard_specific 51_workable_items_db_integrity; do
        [ -f "$d/$t.sh" ] || continue
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="?/tmp/' "$d/$t.sh"; then
            bad="$bad $t"
        fi
    done
    if [ -n "$bad" ]; then
        printf '[FAIL] %s hardcoded /tmp scratch assignment in:%s — route through ${TMPDIR:-/tmp}\n' \
            "CM-NO-HARDCODED-TMP-SCRATCH" "$bad"
        return 1
    fi
    printf '[PASS] %s (16 cwd/state/dispatch tests route scratch through ${TMPDIR:-/tmp})\n' \
        "CM-NO-HARDCODED-TMP-SCRATCH"
    return 0
}

# CM-LOCAL-DEPS-MECHANISM — §11.4.77 + §11.4.81 + §11.4.111 per-host
# local-dependency obtaining mechanism. The build links jemalloc DYNAMIC
# (DT_NEEDED libjemalloc.so.2 preserved); on a host that lacks a system
# jemalloc AND has no sudo (amber) the container-built ELF cannot start
# ("libjemalloc.so.2: cannot open shared object file"), and on a host whose
# Homebrew is off the non-interactive SSH PATH (mistborn — the `command -v
# brew` exit-3 root cause) setup never resolves it. scripts/obtain_local_deps.sh
# RESOLVES a present dependency by ABSOLUTE path (§11.4.111 — never ambient
# PATH) and OBTAINS it git-ignored into .local-deps/ when genuinely missing,
# so setup's patchelf rpath + the wrapper's absolute LD_PRELOAD find a
# host-runnable libjemalloc.so.2. This SOURCE-layer gate asserts the
# mechanism is wired end-to-end; the runtime/anti-bluff half lives in
# scripts/tests/67_local_deps.sh + its paired meta-test mutation (which
# REMOVES the setup.sh invocation — assertion (iv) — to force this gate FAIL).
# NOTE: assertions (ii)-(v) depend on artefacts produced by the concurrent
# setup.sh / tmx.template / .gitignore / .gitignore-meta streams; this gate
# may report FAIL until those land — that is expected, and the conductor runs
# verify.sh only after all streams merge.
_check_CM_LOCAL_DEPS_MECHANISM() {
    local g="CM-LOCAL-DEPS-MECHANISM"
    local rc=0
    local s="$REPO_ROOT/scripts/obtain_local_deps.sh"

    # (i) obtaining script present + executable + `bash -n` parseable (§11.4.67).
    if [ ! -f "$s" ]; then
        printf '[FAIL] %s (i) missing scripts/obtain_local_deps.sh\n' "$g"; rc=1
    elif [ ! -x "$s" ]; then
        printf '[FAIL] %s (i) scripts/obtain_local_deps.sh is not executable\n' "$g"; rc=1
    elif ! bash -n "$s" >/dev/null 2>&1; then
        printf '[FAIL] %s (i) scripts/obtain_local_deps.sh fails `bash -n` (§11.4.67)\n' "$g"; rc=1
    fi

    # (ii) .gitignore ignores the obtained-deps tree (§11.4.30 + §11.4.77).
    if ! grep -qE '(^|/)\.local-deps(/|$)' "$REPO_ROOT/.gitignore" 2>/dev/null; then
        printf '[FAIL] %s (ii) .gitignore has no .local-deps/ ignore entry\n' "$g"; rc=1
    fi

    # (iii) §11.4.77 regen manifest present for the git-ignored .local-deps/ tree.
    if [ ! -f "$REPO_ROOT/.gitignore-meta/local_deps.yaml" ]; then
        printf '[FAIL] %s (iii) missing .gitignore-meta/local_deps.yaml (§11.4.77 regen manifest)\n' "$g"; rc=1
    fi

    # (iv) setup.sh invokes the obtaining mechanism out-of-the-box.
    #      (Stream B's paired meta-test mutation removes this invocation line.)
    if ! grep -q 'obtain_local_deps.sh' "$REPO_ROOT/scripts/setup.sh" 2>/dev/null; then
        printf '[FAIL] %s (iv) scripts/setup.sh does not invoke obtain_local_deps.sh\n' "$g"; rc=1
    fi

    # (v) the wrapper template consumes the resolved-jemalloc mechanism. Require
    #     the EXACT __JEMALLOC_SO__ placeholder setup.sh substitutes (N2): a
    #     generic LD_PRELOAD reference must NOT let a gutted wiring pass — the
    #     placeholder is the load-bearing substitution seam (Step 3). The
    #     M-CM-LOCAL-DEPS-MECHANISM meta-test mutation targets invariant (iv)
    #     (setup.sh invocation) and is untouched by this tightening.
    if ! grep -q '__JEMALLOC_SO__' "$REPO_ROOT/scripts/tmx.template" 2>/dev/null; then
        printf '[FAIL] %s (v) scripts/tmx.template lacks the __JEMALLOC_SO__ placeholder setup.sh substitutes (resolved-jemalloc wiring gutted)\n' "$g"; rc=1
    fi

    # (vi) setup.sh obtains libevent + ncurses out-of-the-box (the v1.0.30
    #      build-dep addition — TMX-059 GAP B). The obtain invocation's DEPS list
    #      MUST include BOTH so a minimal host with no libevent-dev /
    #      libncurses-dev gets them resolved-or-obtained during setup; a
    #      jemalloc-only invocation (the pre-v1.0.30 shape) is the defect. The
    #      RUNTIME half is scripts/tests/72_libevent_ncurses_obtain.sh.
    #      setup.sh carries TWO obtain invocations — an early cc-only toolchain
    #      pre-obtain (`DEPS=cc …`) AND the main one — so we require that AT LEAST
    #      ONE `DEPS=… obtain_local_deps.sh` line lists BOTH libevent AND ncurses
    #      (chained greps keep only a line bearing both), not merely the first.
    local ld_line
    ld_line="$(grep -E 'DEPS=.*obtain_local_deps\.sh' "$REPO_ROOT/scripts/setup.sh" 2>/dev/null \
               | grep 'libevent' | grep 'ncurses' | head -1 || true)"
    if [ -z "$ld_line" ]; then
        printf '[FAIL] %s (vi) setup.sh has no `DEPS=… obtain_local_deps.sh` invocation listing BOTH libevent AND ncurses (build-dep obtain not wired out-of-the-box — GAP B)\n' "$g"; rc=1
    fi

    # (vii) obtain_local_deps.sh registers libevent + ncurses as kind=build AND
    #       emits their INCDIR wiring (%s_INCDIR=%s), so build_native.sh can wire
    #       -I/-L + PKG_CONFIG_PATH for tmux's ./configure. The runtime half is
    #       test 72 (obtain) + test 73 (build_native consumption). A jemalloc-only
    #       (runtime-kind-only) mechanism lacks these → this invariant FAILs.
    if [ -f "$s" ]; then
        grep -qE 'libevent:kind\)[[:space:]]*printf[^"]*"build"' "$s" 2>/dev/null \
          || { printf '[FAIL] %s (vii) obtain_local_deps.sh does not register libevent as a kind=build dependency\n' "$g"; rc=1; }
        grep -qE 'ncurses:kind\)[[:space:]]*printf[^"]*"build"' "$s" 2>/dev/null \
          || { printf '[FAIL] %s (vii) obtain_local_deps.sh does not register ncurses as a kind=build dependency\n' "$g"; rc=1; }
        grep -q '%s_INCDIR=%s' "$s" 2>/dev/null \
          || { printf '[FAIL] %s (vii) obtain_local_deps.sh emits no build-dep INCDIR wiring (%%s_INCDIR=%%s) — libevent/ncurses headers not exported\n' "$g"; rc=1; }
    fi

    if [ "$rc" -eq 0 ]; then
        printf '[PASS] %s (obtaining script + .gitignore + regen manifest + setup wiring + wrapper consume + libevent/ncurses build-dep obtain [vi/vii] all present)\n' "$g"
    fi
    return "$rc"
}

# ── CM-NO-SUDO-NO-INTERACTION (operator mandate 2026-06-29) ──────────────────
# "There cannot be any use of su or sudo inside our project full automation
# scripts or test and no user interaction!" — DIRECT user authority, 2026-06-29.
# This gate mechanically forbids, at pre-build time:
#   (A) sudo/su EXECUTION-or-printed-advice tokens in the install/build automation
#       path (scripts/setup.sh + scripts/install_deps.sh + scripts/install.sh).
#       The real escalation `sudo bash install_deps.sh` was removed; root-only
#       install, honest "re-run as root" message otherwise. A near-zero-token
#       census catches any executed sudo OR echo/printf "run sudo …" advice as a
#       regression; PURE `#` comment lines are filtered (consistent with (B)/(C))
#       so an internal code comment mentioning sudo (setup.sh's go-obtain note
#       "# … with no sudo …") is not a false positive (§11.4.6/§11.4.120).
#   (B) human-waiting prompts (`read … </dev/tty` / `read -p`) in ANY automation
#       script or test under scripts/. EXCLUDED BY DESIGN (NOT automation):
#         • scripts/tmx + scripts/tmx.template — the INTERACTIVE end-user wrapper
#           (its `read PASSWORD </dev/tty` is the operator's own tool).
#         • scripts/tests/lib/pty_harness.sh + scripts/tests/68_session_lifecycle.sh
#           — PTY-DRIVEN automation: the harness INJECTS input programmatically
#           down a pty, it never waits on a live human.
#   (C) PROJECT-WIDE sudo/su EXECUTION detector across EVERY automation script +
#       test in the WHOLE parent repo (TMX-064, 2026-06-29) — not only scripts/.
#       Covers every `*.sh` under scripts/ PLUS the other parent-repo automation
#       (commit_all.sh, docker/, Upstreams/, docs/qa/); the tmux/constitution/
#       Containers submodules (governed by their own gates) and the git-ignored
#       .local-deps/qa-results/out/build/dist/node_modules trees are PRUNED, so
#       vendored + obtained + captured-evidence content is out of scope. Same
#       per-file exclusions as (B). Unlike (A)'s zero-token census, (C) forbids a
#       sudo/su command actually EXECUTED (command position) while ALLOWING
#       print-only advice — comments, echo/printf strings, and the legitimate
#       "(as root) setcap …" guidance the OOM helper (build_oom_set.sh /
#       oom_set.c / tests/08) + the VM provisioning hint (test_vm.sh) now print
#       (reworded 2026-06-29 to drop every literal sudo/su token; the genuine
#       setcap install still needs root, stated honestly). Command position =
#       sudo/su right after line-start, ; & | (covers && and ||), or a
#       space-delimited then/do/else keyword. sudo must be followed by
#       whitespace, and su by whitespace or a dash.
# Runtime/on-test half (Layer 3): scripts/tests/70_native_fallback_cc_link.sh C10.
# Paired §1.1 mutation: scripts/tests/meta_test_false_positive_proof.sh injects a
# real sudo EXECUTION line into an in-scope automation script → invariant (C)
# [FAIL]s (MUTATION CAUGHT); removing it → the gate PASSes again (proving (C) is
# false-positive-free against the "(as root)" advice that remains in the tree).
# §11.4.67: this function is POSIX `sh -n` clean (no process substitution / [[ ]]).
_check_CM_NO_SUDO_NO_INTERACTION() {
    local g="CM-NO-SUDO-NO-INTERACTION"
    local rc=0
    local f hits rel

    # (A) install/build path: ZERO sudo/su EXECUTION-or-PRINTED-ADVICE tokens.
    #     Pure `#` comment lines are filtered (consistent with (B)/(C) below):
    #     an INTERNAL code comment mentioning sudo (e.g. setup.sh's go-obtain note
    #     "# … with no sudo …", 2026-06-29) is neither an executed command nor
    #     user-facing printed advice, so it must not false-FAIL the install path
    #     (§11.4.6 — match the real invariant, not a literal mention; §11.4.120 —
    #     reconciled to the gate's OWN comment-handling, NOT weakened: a real
    #     command-position sudo AND an echo/printf "run sudo …" advice line are
    #     still caught here, and (C) catches EXECUTION project-wide).
    for f in scripts/setup.sh scripts/install_deps.sh scripts/install.sh; do
        [ -f "$REPO_ROOT/$f" ] || continue
        hits="$(grep -nE '\bsudo\b|\bsu[ -]' "$REPO_ROOT/$f" 2>/dev/null \
                | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        if [ -n "$hits" ]; then
            printf '[FAIL] %s sudo/su token in install/build automation %s:\n' "$g" "$f"
            printf '%s\n' "$hits" | sed 's/^/         /'
            rc=1
        fi
    done

    # (B) no human-waiting prompt in automation scripts/tests (excludes below).
    #     Filter out comment lines (^NN:<ws>#) and echo/printf lines so the
    #     gate's OWN documentation + format strings (and similar literal
    #     mentions elsewhere) are not mistaken for an actual blocking read
    #     command (§11.4.6 — match the COMMAND, not the mention). A real
    #     human-wait `read … </dev/tty` / `read -p` is a bare command line,
    #     never a comment and never inside an echo/printf string.
    local excl=" scripts/tmx scripts/tmx.template scripts/tests/lib/pty_harness.sh scripts/tests/68_session_lifecycle.sh "
    for f in $(find "$REPO_ROOT/scripts" -type f -name '*.sh' 2>/dev/null | sort); do
        rel="${f#$REPO_ROOT/}"
        case "$excl" in *" $rel "*) continue ;; esac
        hits="$(grep -nE 'read[[:space:]][^|;&]*</dev/tty|read[[:space:]]+-p' "$f" 2>/dev/null \
                | grep -vE '^[0-9]+:[[:space:]]*#' \
                | grep -vE '(printf|echo)' || true)"
        if [ -n "$hits" ]; then
            printf '[FAIL] %s human-waiting prompt (read </dev/tty | read -p) in %s:\n' "$g" "$rel"
            printf '%s\n' "$hits" | sed 's/^/         /'
            rc=1
        fi
    done

    # (C) PROJECT-WIDE sudo/su EXECUTION detector. Command-position match,
    #     comment + echo/printf lines stripped first so print-only advice
    #     (incl. "(as root) setcap …") PASSes; only an executed sudo/su FAILs.
    #     Scope = the WHOLE parent repo (TMX-064), enumerated via `find` and NOT
    #     `git ls-files`: the paired §1.1 meta-mutation injects an UNTRACKED probe
    #     under scripts/tests/, which a tracked-only listing would silently miss
    #     (a §11.4.69 fail-open) — `find` catches it. Submodules + git-ignored
    #     trees are PRUNED by -path. The repo root basename is itself "tmux", so
    #     the submodule MUST be pruned by -path "$REPO_ROOT/tmux" (a `-name tmux`
    #     prune would kill the whole tree, root included).
    local exec_re='(^|[;&|]|[[:space:]](then|do|else)[[:space:]])[[:space:]]*(sudo[[:space:]]|su[[:space:]-])'
    for f in $(find "$REPO_ROOT" \
                    -name .git -prune \
                    -o -type d \( -path "$REPO_ROOT/tmux" -o -path "$REPO_ROOT/constitution" \
                                  -o -path "$REPO_ROOT/Containers" -o -path "$REPO_ROOT/.local-deps" \
                                  -o -path "$REPO_ROOT/qa-results" -o -path "$REPO_ROOT/out" \
                                  -o -path "$REPO_ROOT/build" -o -path "$REPO_ROOT/dist" \
                                  -o -path "$REPO_ROOT/node_modules" \) -prune \
                    -o -type f -name '*.sh' -print 2>/dev/null | sort); do
        rel="${f#$REPO_ROOT/}"
        case "$excl" in *" $rel "*) continue ;; esac
        hits="$(grep -nE "$exec_re" "$f" 2>/dev/null \
                | grep -vE '^[0-9]+:[[:space:]]*#' \
                | grep -vE '(echo|printf)' || true)"
        if [ -n "$hits" ]; then
            printf '[FAIL] %s sudo/su EXECUTION (command position) in %s:\n' "$g" "$rel"
            printf '%s\n' "$hits" | sed 's/^/         /'
            rc=1
        fi
    done

    if [ "$rc" -eq 0 ]; then
        printf '[PASS] %s (install/build path sudo/su-free; NO sudo/su EXECUTION in any automation script/test PROJECT-WIDE — whole repo, submodules + git-ignored trees pruned; no human-waiting prompts — interactive wrapper + PTY harness + test 68 excluded by design)\n' "$g"
    fi
    return "$rc"
}

# Run the new gates. Aggregate failure into V109_FAIL — Layer 1 must
# stay fail-fast, so any FAIL aborts before the runtime suite (binary is
# NOT operator-safe with broken P1-P4 artefacts).
V109_FAIL=0
_check_CM_RUNALL_OS_AWARE            || V109_FAIL=1
_check_CM_NO_HARDCODED_TMP_SCRATCH   || V109_FAIL=1
_check_CM_TMX_STATE_GO_MOD_EXISTS    || V109_FAIL=1
_check_CM_TMX_STATE_GO_PRESENT       || V109_FAIL=1
_check_CM_TMX_SHELL_INIT_POSIX       || V109_FAIL=1
_check_CM_TMX_SSH_DISPATCH_POSIX     || V109_FAIL=1
_check_CM_TMX_DOCS_GUIDES_EXIST      || V109_FAIL=1
_check_CM_TMX_WRAPPER_TMUXBIN_VALID  || V109_FAIL=1
_check_CM_NO_DYNAMIC_LIBTINFO        || V109_FAIL=1
if [ "$V109_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: one or more v1.0.9 PWU pre-build gates FAILed. Investigate"
    echo "     individual [FAIL] lines above. setup.sh will REFUSE."
    exit 1
fi
echo "  ✓ Layer-1 v1.0.9 PWU gates GREEN"

# ── Layer-1 — CM-LOCAL-DEPS-MECHANISM (§11.4.77/.81/.111) ──────────────
# Self-contained run block (its own FAIL var + accurate message) for the
# per-host local-dependency obtaining mechanism gate.
echo ""
echo "  Layer-1 static gate — CM-LOCAL-DEPS-MECHANISM (§11.4.77/.81/.111)..."
LOCALDEPS_FAIL=0
_check_CM_LOCAL_DEPS_MECHANISM || LOCALDEPS_FAIL=1
if [ "$LOCALDEPS_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: CM-LOCAL-DEPS-MECHANISM FAILed. The per-host local-dependency"
    echo "     obtaining mechanism (scripts/obtain_local_deps.sh) is not wired"
    echo "     end-to-end — investigate the individual [FAIL] (i)-(v) lines"
    echo "     above. setup.sh will REFUSE to PATH-export the binary."
    exit 1
fi
echo "  ✓ Layer-1 CM-LOCAL-DEPS-MECHANISM gate GREEN"

# ── Layer-1 — CM-NO-SUDO-NO-INTERACTION (operator mandate 2026-06-29) ──
# Self-contained run block (own FAIL var + accurate message) for the
# no-privilege-escalation + no-human-interaction invariant in the
# install/build automation path + all automation scripts/tests.
echo ""
echo "  Layer-1 static gate — CM-NO-SUDO-NO-INTERACTION (no sudo/su EXECUTION + no human-wait in automation)..."
NOSUDO_FAIL=0
_check_CM_NO_SUDO_NO_INTERACTION || NOSUDO_FAIL=1
if [ "$NOSUDO_FAIL" -ne 0 ]; then
    echo ""
    echo "RED: CM-NO-SUDO-NO-INTERACTION FAILed. An automation script/test escalates"
    echo "     privilege (sudo/su) or waits for human input (read </dev/tty | read -p)."
    echo "     Operator mandate 2026-06-29: NO sudo/su and NO human interaction in"
    echo "     full-automation scripts or tests. setup.sh will REFUSE to PATH-export."
    exit 1
fi
echo "  ✓ Layer-1 CM-NO-SUDO-NO-INTERACTION gate GREEN"

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
