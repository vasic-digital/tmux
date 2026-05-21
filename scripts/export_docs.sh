#!/usr/bin/env bash
# export_docs.sh — generate HTML + PDF siblings for every project Markdown
# document in scope of §11.4.65 universal-Markdown-export.
#
# Mandate anchor — user (2026-05-21):
#   "Make sure all this is fully documented in our main documentation,
#    user guides and manuals and all of them exported to PDF and HTML!"
#
# §11.4.65 scope: every .md NOT inside an application/service source tree.
# In this repo that means: root-level *.md + docs/**/*.md. Out of scope:
# tmux/** (upstream submodule), Containers/** (owned-but-separate-cycle
# submodule per §11.4.28 — Containers ships its own exports), constitution/
# ** (HelixConstitution submodule — ships its own exports), .codegraph/**,
# .gitignore-meta/**.
#
# §11.4.30 .gitignore: outputs (.html + .pdf siblings of governance .md
# files) ARE committed. The §11.4.65 mandate is "in sync at all times" —
# committed exports are how operators see them on github.com.
#
# Idempotent: re-running regenerates only stale outputs (HTML+PDF mtime
# < .md mtime) unless --force.
#
# Per-file timeout 60s; total cap 500 candidates (per §11.4.65 invariant).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

# Tool prerequisites — fail honestly per §1 / §11.4.6 (no-guessing).
need_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "RED: missing required tool '$1'" >&2
        echo "     install via: $2" >&2
        exit 1
    fi
}
need_tool pandoc     "brew install pandoc (macOS) | apt install pandoc (Debian/Ubuntu)"
need_tool weasyprint "brew install weasyprint (macOS) | pip install weasyprint (any)"

# Discover candidate Markdown files. The find expression below
# explicitly excludes the directories listed above. Maxdepth bounds keep
# the walk fast on a large repo. Sort for deterministic output.
EXCLUDES=( -not -path './tmux/*' -not -path './Containers/*' \
           -not -path './constitution/*' -not -path './.codegraph/*' \
           -not -path './.gitignore-meta/*' -not -path './.git/*' \
           -not -path './node_modules/*' -not -path './tests/.tmpdocs/*' )

# Cap at 500 (§11.4.65 invariant).
mapfile -t CANDIDATES < <(find . -type f -name '*.md' "${EXCLUDES[@]}" 2>/dev/null | sort | head -500)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "RED: no Markdown candidates found — something is wrong." >&2
    exit 1
fi

EXPORTED=0
SKIPPED=0
FAILED=0

# Pandoc-style HTML wrapper template — keeps output self-contained so
# operators can open it offline without missing CSS.
PANDOC_OPTS=(
    --from gfm+autolink_bare_uris+yaml_metadata_block
    --to html5
    --standalone
    --self-contained
    --highlight-style tango
    --metadata "title:$(basename "$PWD") documentation"
    --css /dev/null
)

# Per-file timeout (seconds). 60s is the §11.4.65 ceiling.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
maybe_timeout() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" 60 "$@"
    else
        "$@"  # honest: macOS without coreutils gtimeout — run without bound
    fi
}

for md in "${CANDIDATES[@]}"; do
    html="${md%.md}.html"
    pdf="${md%.md}.pdf"

    need_regen=0
    if [ "$FORCE" -eq 1 ] || [ ! -f "$html" ] || [ "$md" -nt "$html" ]; then
        need_regen=1
    fi
    if [ "$FORCE" -eq 1 ] || [ ! -f "$pdf" ] || [ "$md" -nt "$pdf" ]; then
        need_regen=1
    fi

    if [ "$need_regen" -eq 0 ]; then
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    # HTML first.
    if ! maybe_timeout pandoc "${PANDOC_OPTS[@]}" -o "$html" "$md" 2>/tmp/.export_docs_pandoc_err; then
        echo "  ✗ FAIL html: $md" >&2
        cat /tmp/.export_docs_pandoc_err >&2 || true
        FAILED=$((FAILED+1))
        continue
    fi

    # PDF from the just-emitted HTML — weasyprint preserves pandoc's CSS.
    if ! maybe_timeout weasyprint "$html" "$pdf" 2>/tmp/.export_docs_wp_err; then
        echo "  ✗ FAIL pdf: $md" >&2
        cat /tmp/.export_docs_wp_err >&2 || true
        FAILED=$((FAILED+1))
        continue
    fi

    echo "  ✓ $md"
    EXPORTED=$((EXPORTED+1))
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  export_docs SUMMARY: exported=$EXPORTED  skipped(fresh)=$SKIPPED  failed=$FAILED"
echo "════════════════════════════════════════════════════════════════"

# §11.4.6 honest exit: non-zero if any file failed.
[ "$FAILED" -eq 0 ]
