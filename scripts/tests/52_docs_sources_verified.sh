#!/usr/bin/env bash
# Test 52 — §11.4.99 Sources-verified footer presence in operator-facing docs.
#
# §11.4.99 FORENSIC ANCHOR:
#   The §11.4.99 mandate requires every operator-facing instruction /
#   guide / manual to carry a `## Sources verified <DATE>` (or
#   `### Sources verified <DATE>` for sub-sections) footer. The
#   intent: every operator-visible procedure is dated, audit-trail
#   captured, and stale (>6 months) doc surfaces are flagged for
#   refresh per (C). Without this gate, a guide can silently rot and
#   the operator follows stale instructions while every Markdown
#   sync wrapper reports "exports current".
#
#   Test 52 enumerates the canonical operator-facing docs and asserts
#   each carries a Sources-verified heading whose ISO date is ≤ 180
#   days old. The list of guarded docs is closed-set here; future
#   guides land in this list as part of their PWU.
#
# §11.4.2 captured evidence: per-doc heading line + parsed date.
# §11.4.50 reliability: 3 iterations, identical result every time
#   (filesystem state — deterministic by construction).
# §11.4.14 cleanup: no tmp files of consequence.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Canonical list of operator-facing docs guarded by §11.4.99.
# Each MUST have a `## Sources verified <YYYY-MM-DD>` heading (or `###`
# for sub-sections per §5.7 of docs/guide/README.md).
GUARDED_DOCS=(
    "docs/guides/clipboard.md"
    "docs/workable-items/README.md"
    "docs/scripts/workable-items.md"
)

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 52: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 52: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 52: $*"; SKIP=$((SKIP + 1)); }

echo "── Test 52: §11.4.99 Sources-verified footer presence ──"

# ── T0: docs structure exists ─────────────────────────────────────────
if [ ! -d "$REPO_ROOT/docs" ]; then
    _fail "T0 docs/ root missing"
    echo "── summary 52: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"
    exit 1
fi
_pass "T0 docs/ root present"

# Compute "today minus 180 days" for staleness threshold (§11.4.99(C)).
# Portable across BSD/GNU date: we use python3 which is in scope on both
# Mistborn (macOS) and nezha (Linux) per Constitution requirements.
THRESHOLD_DATE="$(python3 -c '
import datetime
print((datetime.date.today() - datetime.timedelta(days=180)).isoformat())
')"
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"

_evidence_lines=()

# ── T1 + T2 + T3: enumerate each doc, assert heading + ISO date + freshness.
check_doc() {
    local doc="$1"
    local path="$REPO_ROOT/$doc"
    if [ ! -f "$path" ]; then
        _fail "T1 doc missing: $doc"
        return 1
    fi
    # Look for `## Sources verified <DATE>` OR `### Sources verified <DATE>`.
    local heading_line
    heading_line="$(grep -E '^#{2,3} Sources verified ' "$path" | head -1)"
    if [ -z "$heading_line" ]; then
        _fail "T2 $doc missing '## Sources verified <DATE>' (or ### subsection) heading — §11.4.99 violation"
        return 1
    fi
    # Extract the date token. Format: '## Sources verified YYYY-MM-DD'.
    local date_str
    date_str="$(echo "$heading_line" | sed -nE 's/^#{2,3} Sources verified ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p')"
    if [ -z "$date_str" ]; then
        _fail "T2 $doc Sources-verified heading present but date not ISO YYYY-MM-DD: $heading_line"
        return 1
    fi
    # Validate the date parses + is not in the future + ≤ 180 days old.
    local age_days
    age_days="$(python3 -c "
import datetime, sys
try:
    d = datetime.date.fromisoformat('$date_str')
except Exception as e:
    print('PARSE_ERROR'); sys.exit(0)
today = datetime.date.today()
delta = (today - d).days
print(delta)
")"
    if [ "$age_days" = "PARSE_ERROR" ]; then
        _fail "T3 $doc Sources-verified date '$date_str' did not parse as ISO 8601"
        return 1
    fi
    if [ "$age_days" -lt 0 ]; then
        _fail "T3 $doc Sources-verified date '$date_str' is in the FUTURE (today=$TODAY)"
        return 1
    fi
    if [ "$age_days" -gt 180 ]; then
        _fail "T3 $doc Sources-verified date '$date_str' is ${age_days}d old (>180d threshold per §11.4.99(C)); refresh needed"
        return 1
    fi
    _evidence_lines+=("$doc verified=$date_str age=${age_days}d")
    return 0
}

doc_ok=0
doc_total=0
for doc in "${GUARDED_DOCS[@]}"; do
    doc_total=$((doc_total + 1))
    if check_doc "$doc"; then
        doc_ok=$((doc_ok + 1))
    fi
done

if [ "$doc_ok" -eq "$doc_total" ]; then
    _pass "T1 + T2 + T3 all $doc_total guarded docs carry valid Sources-verified footer (≤180d)"
    for line in "${_evidence_lines[@]}"; do
        echo "[evidence 52] $line"
    done
fi

# ── T4: §11.4.50 reliability — 3 iterations against filesystem state
#     produce identical evidence (trivially true for static files;
#     captured here so the test composes with §11.4.98 re-runnability).
_hashes=()
for i in 1 2 3; do
    h_inputs=""
    for doc in "${GUARDED_DOCS[@]}"; do
        line="$(grep -E '^#{2,3} Sources verified ' "$REPO_ROOT/$doc" 2>/dev/null | head -1)"
        h_inputs="${h_inputs}|${doc}=${line}"
    done
    _h="$(printf '%s' "$h_inputs" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
done
if [ "${_hashes[0]}" = "${_hashes[1]}" ] && [ "${_hashes[1]}" = "${_hashes[2]}" ]; then
    _pass "T4 §11.4.50 deterministic across 3 iterations (hash=${_hashes[0]})"
else
    _fail "T4 §11.4.50 divergent: ${_hashes[*]}"
fi

echo "── summary 52: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (threshold=${THRESHOLD_DATE}) ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
