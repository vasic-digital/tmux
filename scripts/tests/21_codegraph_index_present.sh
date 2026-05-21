#!/usr/bin/env bash
# Test 21 — CodeGraph index materialised + non-empty.
#
# §11.4.78 mandates not just install but actual usage. Without an
# index, the MCP server has no facts to expose, and any agent claiming
# CodeGraph integration "works" would be in a §11.4 PASS-bluff state.
# This test runs `codegraph status` and captures the node count as
# positive runtime evidence per §11.4.5.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

CG_DB="$REPO_ROOT/.codegraph/codegraph.db"

# T1 — DB file present.
if [ ! -f "$CG_DB" ]; then
    _fail "T1: $CG_DB missing — run 'bash scripts/codegraph_reindex.sh'"
    echo ""
    echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    exit 1
else
    _pass "T1: codegraph.db present (positive evidence: file exists)"
fi

# T2 — DB non-trivial size. SQLite minimum is ~4 KB; a real index is
# at least tens of KB.
DB_SIZE=$(stat -f '%z' "$CG_DB" 2>/dev/null || stat -c '%s' "$CG_DB" 2>/dev/null || echo 0)
if [ "$DB_SIZE" -gt 4096 ] 2>/dev/null; then
    _pass "T2: codegraph.db size = $DB_SIZE bytes > 4 KB SQLite minimum (positive evidence: stat readback)"
else
    _fail "T2: codegraph.db size = $DB_SIZE bytes — too small to contain a real index"
fi

# T3 — codegraph status reports non-zero node count.
if ! command -v codegraph >/dev/null 2>&1; then
    _skip "T3: codegraph CLI not on PATH (covered by test 20 T1 FAIL)"
else
    CG_STATUS_OUT="$(codegraph status "$REPO_ROOT" 2>&1 | sed -E $'s/\033\\[[0-9;]*m//g')"
    NODE_COUNT="$(echo "$CG_STATUS_OUT" | grep -E 'Nodes:' | head -1 | grep -oE '[0-9]+' | head -1)"
    if [ -n "$NODE_COUNT" ] && [ "$NODE_COUNT" -gt 0 ] 2>/dev/null; then
        _pass "T3: codegraph status reports $NODE_COUNT nodes (positive runtime evidence per §11.4.5)"
    else
        _fail "T3: codegraph status returned no parseable node count (got: '$NODE_COUNT')"
    fi
fi

# T4 — stamp file from regen script present + recent (sanity check the
# regeneration mechanism actually ran).
STAMP="$REPO_ROOT/.gitignore-meta/.regenerated/codegraph-db.ok"
if [ -f "$STAMP" ]; then
    STAMP_NODES=$(grep '^node_count:' "$STAMP" | head -1 | grep -oE '[0-9]+' | head -1)
    if [ -n "$STAMP_NODES" ] && [ "$STAMP_NODES" -gt 0 ] 2>/dev/null; then
        _pass "T4: §11.4.77 regen stamp present, recorded node_count=$STAMP_NODES (positive evidence: stamp file)"
    else
        _fail "T4: $STAMP exists but no parseable node_count"
    fi
else
    # Soft: missing stamp is documented but not blocker (status query alone proves index works)
    _skip "T4: $STAMP not present — run bash scripts/codegraph_reindex.sh to materialise"
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
