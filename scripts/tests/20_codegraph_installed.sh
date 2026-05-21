#!/usr/bin/env bash
# Test 20 — CodeGraph CLI installed + initialised + secret exclusions present.
#
# §11.4.78 + user mandate (2026-05-21): every project worked on by AI
# coding agents MUST install CodeGraph, initialize it, and configure
# secret exclusions per §11.4.10.
#
# Positive evidence per §11.4.2: this test reads CONTENT (config.json
# parsed, .gitignore greppped, CLI version captured) — never existence
# alone. Per §11.4.6 no-guessing: every assertion has a captured fact.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

# T1 — CodeGraph CLI on PATH + version ≥ 0.6.0.
if ! command -v codegraph >/dev/null 2>&1; then
    _fail "T1: codegraph CLI not on PATH — install per §11.4.78 (npm install -g @colbymchenry/codegraph; no sudo)"
else
    CG_VER="$(codegraph --version 2>&1 | head -1 | tr -d '[:space:]')"
    if [ -z "$CG_VER" ]; then
        _fail "T1: codegraph --version returned empty output"
    else
        CG_MAJ="$(echo "$CG_VER" | cut -d. -f1)"
        CG_MIN="$(echo "$CG_VER" | cut -d. -f2)"
        if [ "$CG_MAJ" -gt 0 ] 2>/dev/null || { [ "$CG_MAJ" = "0" ] && [ "$CG_MIN" -ge 6 ] 2>/dev/null; }; then
            _pass "T1: codegraph CLI on PATH, version=$CG_VER ≥ 0.6.0 (positive evidence: codegraph --version)"
        else
            _fail "T1: codegraph version $CG_VER < 0.6.0 minimum"
        fi
    fi
fi

# T2 — .codegraph/config.json present + parseable.
CG_CFG="$REPO_ROOT/.codegraph/config.json"
if [ ! -f "$CG_CFG" ]; then
    _fail "T2: $CG_CFG missing — run 'codegraph init' or 'bash scripts/codegraph_reindex.sh'"
elif ! python3 -c "import json; json.load(open('$CG_CFG'))" 2>/dev/null; then
    _fail "T2: $CG_CFG present but not valid JSON"
else
    _pass "T2: $CG_CFG present and valid JSON (positive evidence: python3 json.load)"
fi

# T3 — §11.4.10 secret-exclusion patterns present in config.
# Every required secret pattern + every owned-submodule path must be
# in the exclude list. We grep for EACH literal — a partial subset
# of secrets being present is a §11.4 PASS-bluff at the credentials layer.
T3_MISSING=()
T3_REQUIRED=(
    '**/.env'           '**/.env.*'         '**/*.env'
    '**/*.pem'          '**/*.key'          '**/*.crt'
    '**/id_rsa*'        '**/id_ed25519*'    '**/secrets/**'
    'constitution/**'   'Containers/**'     'tmux/**'
)
if [ -f "$CG_CFG" ]; then
    for pat in "${T3_REQUIRED[@]}"; do
        # Use python to safely check; bash grep would have false negatives on glob
        if ! python3 -c "
import json, sys
c = json.load(open('$CG_CFG'))
ex = c.get('exclude', [])
sys.exit(0 if '$pat' in ex else 1)
" 2>/dev/null; then
            T3_MISSING+=("$pat")
        fi
    done
    if [ ${#T3_MISSING[@]} -eq 0 ]; then
        _pass "T3: all 12 required secret/submodule exclude patterns present in config.exclude (positive evidence: each pattern verified by python json parse)"
    else
        _fail "T3: missing exclude patterns: ${T3_MISSING[*]}"
    fi
else
    _skip "T3: config.json absent (covered by T2 FAIL)"
fi

# T4 — project .gitignore covers .codegraph/codegraph.db per §11.4.30.
if grep -q '^\.codegraph/codegraph\.db$' "$REPO_ROOT/.gitignore" 2>/dev/null; then
    _pass "T4: .gitignore covers .codegraph/codegraph.db (positive evidence: grep hit on literal line)"
else
    _fail "T4: .gitignore missing .codegraph/codegraph.db entry (per §11.4.30 build-artefact rule)"
fi

# T5 — §11.4.77 regeneration mechanism manifest present.
REGEN_YAML="$REPO_ROOT/.gitignore-meta/codegraph-db.yaml"
if [ ! -f "$REGEN_YAML" ]; then
    _fail "T5: regeneration mechanism manifest missing at $REGEN_YAML (§11.4.77 violation)"
elif ! grep -q '^script_path:' "$REGEN_YAML"; then
    _fail "T5: $REGEN_YAML missing script_path field"
else
    REGEN_SCRIPT="$(grep '^script_path:' "$REGEN_YAML" | head -1 | sed 's/^script_path: *//')"
    if [ ! -x "$REPO_ROOT/$REGEN_SCRIPT" ]; then
        _fail "T5: regeneration script $REGEN_SCRIPT not executable"
    else
        _pass "T5: §11.4.77 manifest + executable regen script $REGEN_SCRIPT (positive evidence: file readable, declared script path resolves)"
    fi
fi

echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
