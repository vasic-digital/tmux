#!/usr/bin/env bash
# sync_all_markdown_exports.sh — §11.4.65 universal Markdown export with
# HTML + PDF + DOCX siblings, generated in parallel per .md.
#
# Mandate anchors:
#   §11.4.65 — Every tracked .md outside an application/service source
#              tree MUST have synchronized .html + .pdf siblings; this
#              cycle adds .docx as the third format (PWU-D).
#   §11.4.98 — Full-automation: this script runs end-to-end with no
#              manual intervention.
#   §107     — Anti-bluff: per-format failures are surfaced individually;
#              the absence of a tool degrades gracefully (warning + skip)
#              rather than masking the gap with a silent PASS.
#
# Scope (same as export_docs.sh): root-level *.md + docs/**/*.md.
# Excludes upstream/owned-but-separate submodules + tool caches.
#
# Parallelism: per-file the three formats (HTML, PDF, DOCX) run in
# background and join via `wait`. The outer loop is serial so we can
# track per-file PASS/FAIL deterministically.
#
# Idempotent: regenerates only stale outputs (sibling missing OR older
# than the .md source) unless --force.
#
# Per-format timeout 60s (§11.4.65 ceiling). Total candidate cap 500.
#
# Usage:
#   bash scripts/sync_all_markdown_exports.sh           # incremental
#   bash scripts/sync_all_markdown_exports.sh --force   # rebuild all

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

# ─── Tool detection ────────────────────────────────────────────────────
# pandoc is required for HTML + DOCX. weasyprint is required for PDF.
# Per §107 honest-evidence: each missing tool degrades its format only,
# never the whole sync — but we report explicitly which formats are
# disabled this run so an operator never sees a hidden gap.

HAVE_PANDOC=0
HAVE_WEASYPRINT=0
if command -v pandoc >/dev/null 2>&1; then HAVE_PANDOC=1; fi
if command -v weasyprint >/dev/null 2>&1; then HAVE_WEASYPRINT=1; fi

if [ "$HAVE_PANDOC" -eq 0 ]; then
    echo "WARN: pandoc not on PATH — HTML + DOCX exports will be SKIPPED."
    echo "      install via: brew install pandoc | apt install pandoc"
fi
if [ "$HAVE_WEASYPRINT" -eq 0 ]; then
    echo "WARN: weasyprint not on PATH — PDF exports will be SKIPPED."
    echo "      install via: brew install weasyprint | pip install weasyprint"
fi

# Per-format timeout helper (60s ceiling).
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
maybe_timeout() {
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" 60 "$@"
    else
        "$@"  # honest: macOS without coreutils gtimeout — unbounded
    fi
}

# ─── Candidate discovery ───────────────────────────────────────────────
EXCLUDES=( -not -path './tmux/*' -not -path './Containers/*' \
           -not -path './constitution/*' -not -path './.codegraph/*' \
           -not -path './.gitignore-meta/*' -not -path './.git/*' \
           -not -path './node_modules/*' -not -path './tests/.tmpdocs/*' )

mapfile -t CANDIDATES < <(find . -type f -name '*.md' "${EXCLUDES[@]}" 2>/dev/null | sort | head -500)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "RED: no Markdown candidates found — something is wrong." >&2
    exit 1
fi

# ─── Counters ──────────────────────────────────────────────────────────
HTML_OK=0; HTML_SKIP=0; HTML_FAIL=0
PDF_OK=0;  PDF_SKIP=0;  PDF_FAIL=0
DOCX_OK=0; DOCX_SKIP=0; DOCX_FAIL=0

# Failure-list arrays so the summary surfaces problem files instead of
# burying them in a counter.
HTML_FAILED_FILES=()
PDF_FAILED_FILES=()
DOCX_FAILED_FILES=()

PANDOC_HTML_OPTS=(
    --from gfm+autolink_bare_uris+yaml_metadata_block
    --to html5
    --standalone
    --highlight-style tango
)

# DOCX uses pandoc's gfm reader → docx writer. --standalone keeps the
# output self-contained (no companion .docx-resources/ directory). The
# title metadata is the .md basename per the operator request.
pandoc_docx() {
    local md="$1" docx="$2" title
    title="$(basename "$md" .md)"
    maybe_timeout pandoc \
        --from gfm+autolink_bare_uris+yaml_metadata_block \
        --to docx \
        --standalone \
        --metadata "title:$title" \
        -o "$docx" "$md" 2>/tmp/.sync_md_docx_err
}

pandoc_html() {
    local md="$1" html="$2"
    maybe_timeout pandoc "${PANDOC_HTML_OPTS[@]}" \
        -o "$html" "$md" 2>/tmp/.sync_md_html_err
}

weasyprint_pdf() {
    local html="$1" pdf="$2"
    maybe_timeout weasyprint "$html" "$pdf" 2>/tmp/.sync_md_pdf_err
}

# ─── Main loop ─────────────────────────────────────────────────────────
for md in "${CANDIDATES[@]}"; do
    html="${md%.md}.html"
    pdf="${md%.md}.pdf"
    docx="${md%.md}.docx"

    need_html=0; need_pdf=0; need_docx=0
    if [ "$HAVE_PANDOC" -eq 1 ]; then
        if [ "$FORCE" -eq 1 ] || [ ! -f "$html" ] || [ "$md" -nt "$html" ]; then
            need_html=1
        fi
        if [ "$FORCE" -eq 1 ] || [ ! -f "$docx" ] || [ "$md" -nt "$docx" ]; then
            need_docx=1
        fi
    fi
    if [ "$HAVE_WEASYPRINT" -eq 1 ]; then
        if [ "$FORCE" -eq 1 ] || [ ! -f "$pdf" ] || [ "$md" -nt "$pdf" ]; then
            need_pdf=1
        fi
    fi

    # Skip-counter accounting for formats that are fresh OR for which the
    # backing tool is unavailable. Distinguish on counter alone via
    # presence of OK + SKIP both being incremented elsewhere; here we
    # only bump SKIP when nothing has to happen.
    if [ "$HAVE_PANDOC" -eq 1 ] && [ "$need_html" -eq 0 ]; then HTML_SKIP=$((HTML_SKIP+1)); fi
    if [ "$HAVE_WEASYPRINT" -eq 1 ] && [ "$need_pdf"  -eq 0 ]; then PDF_SKIP=$((PDF_SKIP+1));  fi
    if [ "$HAVE_PANDOC" -eq 1 ] && [ "$need_docx" -eq 0 ]; then DOCX_SKIP=$((DOCX_SKIP+1)); fi

    # If no work for this file (fresh on every available format), skip.
    if [ $((need_html + need_pdf + need_docx)) -eq 0 ]; then
        continue
    fi

    # ── Parallel dispatch ──────────────────────────────────────────────
    # HTML first (needed before PDF because PDF is rendered from HTML).
    # DOCX runs in parallel with HTML+PDF (it sources from .md directly).
    html_rc=0; pdf_rc=0; docx_rc=0
    html_pid=0; docx_pid=0

    if [ "$need_html" -eq 1 ]; then
        ( pandoc_html "$md" "$html" ) &
        html_pid=$!
    fi
    if [ "$need_docx" -eq 1 ]; then
        ( pandoc_docx "$md" "$docx" ) &
        docx_pid=$!
    fi

    # Join HTML before launching PDF (PDF depends on HTML).
    if [ "$html_pid" -ne 0 ]; then
        wait "$html_pid" || html_rc=$?
        if [ "$html_rc" -eq 0 ]; then
            HTML_OK=$((HTML_OK+1))
            echo "  ok html: $md"
        else
            HTML_FAIL=$((HTML_FAIL+1))
            HTML_FAILED_FILES+=("$md")
            echo "  FAIL html: $md (rc=$html_rc)" >&2
            cat /tmp/.sync_md_html_err >&2 2>/dev/null || true
        fi
    fi

    # PDF after HTML succeeds (or is already fresh).
    if [ "$need_pdf" -eq 1 ]; then
        if [ ! -f "$html" ]; then
            # HTML missing AND we can't produce it (pandoc absent) → PDF cannot proceed honestly.
            PDF_FAIL=$((PDF_FAIL+1))
            PDF_FAILED_FILES+=("$md")
            echo "  FAIL pdf: $md (no html available)" >&2
        else
            ( weasyprint_pdf "$html" "$pdf" ) &
            pdf_pid=$!
            wait "$pdf_pid" || pdf_rc=$?
            if [ "$pdf_rc" -eq 0 ]; then
                PDF_OK=$((PDF_OK+1))
                echo "  ok pdf:  $md"
            else
                PDF_FAIL=$((PDF_FAIL+1))
                PDF_FAILED_FILES+=("$md")
                echo "  FAIL pdf: $md (rc=$pdf_rc)" >&2
                cat /tmp/.sync_md_pdf_err >&2 2>/dev/null || true
            fi
        fi
    fi

    if [ "$docx_pid" -ne 0 ]; then
        wait "$docx_pid" || docx_rc=$?
        if [ "$docx_rc" -eq 0 ]; then
            DOCX_OK=$((DOCX_OK+1))
            echo "  ok docx: $md"
        else
            DOCX_FAIL=$((DOCX_FAIL+1))
            DOCX_FAILED_FILES+=("$md")
            echo "  FAIL docx: $md (rc=$docx_rc)" >&2
            cat /tmp/.sync_md_docx_err >&2 2>/dev/null || true
        fi
    fi
done

# ─── Summary ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  sync_all_markdown_exports SUMMARY"
echo "  candidates: ${#CANDIDATES[@]}"
echo "  HTML:  ok=$HTML_OK  skip(fresh)=$HTML_SKIP  fail=$HTML_FAIL$([ $HAVE_PANDOC -eq 0 ] && echo '  (pandoc absent — all SKIPPED)')"
echo "  PDF :  ok=$PDF_OK  skip(fresh)=$PDF_SKIP  fail=$PDF_FAIL$([ $HAVE_WEASYPRINT -eq 0 ] && echo '  (weasyprint absent — all SKIPPED)')"
echo "  DOCX:  ok=$DOCX_OK  skip(fresh)=$DOCX_SKIP  fail=$DOCX_FAIL$([ $HAVE_PANDOC -eq 0 ] && echo '  (pandoc absent — all SKIPPED)')"
echo "════════════════════════════════════════════════════════════════"

if [ ${#HTML_FAILED_FILES[@]} -gt 0 ]; then
    echo "HTML failures:"
    for f in "${HTML_FAILED_FILES[@]}"; do echo "  - $f"; done
fi
if [ ${#PDF_FAILED_FILES[@]} -gt 0 ]; then
    echo "PDF failures:"
    for f in "${PDF_FAILED_FILES[@]}"; do echo "  - $f"; done
fi
if [ ${#DOCX_FAILED_FILES[@]} -gt 0 ]; then
    echo "DOCX failures:"
    for f in "${DOCX_FAILED_FILES[@]}"; do echo "  - $f"; done
fi

# Honest exit: non-zero if any per-file conversion failed on an available
# tool. Missing tools are not failure (they're an SKIPPED-all warning).
total_fail=$((HTML_FAIL + PDF_FAIL + DOCX_FAIL))
[ "$total_fail" -eq 0 ]
