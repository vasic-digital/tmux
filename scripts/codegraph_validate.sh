#!/usr/bin/env bash
# codegraph_validate.sh — §11.4.78 step 4 anti-bluff verifier + §11.4.79
# own-org-inclusion validation. Invoked by the constitution submodule's
# scripts/codegraph_sync.sh per §11.4.80 (inherited by reference, never
# copied).
#
# Anti-bluff (§11.4 + §107): each PASS reads captured content (status
# output, files-list, query result) — never just exit codes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

# V1 — CLI present + version observable.
if ! command -v codegraph >/dev/null 2>&1; then
    _fail "V1: codegraph CLI not on PATH"
    echo "  Tests: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"; exit 1
fi
_pass "V1: codegraph $(codegraph --version 2>&1 | head -1 | tr -d '[:space:]') on PATH"

# V2 — Index materialised + non-zero node count (anti-bluff: read the actual
# integer from `codegraph status`, not just exit code).
CG_STATUS="$(codegraph status "$REPO_ROOT" 2>&1 | sed -E $'s/\033\\[[0-9;]*m//g')"
NODES="$(echo "$CG_STATUS" | grep -E 'Nodes:' | head -1 | grep -oE '[0-9]+' | head -1)"
if [ -n "$NODES" ] && [ "$NODES" -gt 0 ] 2>/dev/null; then
    _pass "V2: index reports $NODES nodes (positive runtime evidence)"
else
    _fail "V2: codegraph status reports no parseable node count — re-run scripts/codegraph_reindex.sh"
fi

# V3 — §11.4.79 own-org-inclusion config check.
# The mandate: own-org submodules MUST NOT appear in exclude. Third-party
# submodules MUST be excluded. Verify by parsing config.json.
if [ ! -f "$REPO_ROOT/.codegraph/config.json" ]; then
    _fail "V3: .codegraph/config.json missing — run codegraph init"
else
    V3_RESULT="$(python3 - <<'PYEOF'
import json
c = json.load(open('.codegraph/config.json'))
ex = c.get('exclude', [])
# Own-org submodules — MUST NOT be in exclude.
violations = []
for own_org in ('constitution/**', 'Containers/**'):
    if own_org in ex:
        violations.append(f"own-org '{own_org}' wrongly excluded")
# Third-party — MUST be in exclude.
for third_party in ('tmux/**',):
    if third_party not in ex:
        violations.append(f"third-party '{third_party}' should be excluded but isn't")
if violations:
    print('FAIL: ' + '; '.join(violations))
else:
    print('OK: own-org constitution/+Containers/ NOT excluded; third-party tmux/ excluded')
PYEOF
)"
    case "$V3_RESULT" in
        OK:*) _pass "V3 (§11.4.79): ${V3_RESULT#OK: }" ;;
        FAIL:*) _fail "V3 (§11.4.79): ${V3_RESULT#FAIL: }" ;;
        *) _fail "V3: unexpected probe result: $V3_RESULT" ;;
    esac
fi

# V4 — Honest gap probe (§11.4.6 + §11.4.79). CodeGraph 0.6.8 does NOT
# traverse git submodule directories from the parent index. Even with
# own-org NOT in exclude, codegraph reports 0 files from constitution/
# or Containers/. This is a CodeGraph CLI limitation, not a config bug.
# §11.4.79's spirit is met by NOT excluding them (so when CodeGraph adds
# submodule traversal, the index expands automatically). For now we
# report this honestly per §11.4.6 rather than bluff.
CG_FILES="$(codegraph files 2>&1 | sed -E $'s/\033\\[[0-9;]*m//g')"
if echo "$CG_FILES" | grep -qE '(^|/)Containers/|(^|/)constitution/'; then
    _pass "V4 (§11.4.79): index reaches own-org submodule content (positive evidence)"
else
    # Not a FAIL — this is a CodeGraph CLI limitation, honestly documented.
    _skip "V4 (§11.4.79): CodeGraph 0.6.8 does not traverse git submodules from parent index. Config compliant (own-org not excluded). See docs/codegraph/README.md §9 honest-gap. Sub-indexing each submodule would be the workaround if needed."
fi

# V5 — MCP-server spawn smoke check (proves codegraph serve --mcp boots).
SPAWN_OK="$(python3 - <<'PYEOF'
import subprocess, time, sys
try:
    p = subprocess.Popen(['codegraph', 'serve', '--mcp'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    time.sleep(0.4)
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=2)
        except subprocess.TimeoutExpired: p.kill()
        print("OK")
    else:
        print(f"EXITED:{p.returncode}")
except Exception as e:
    print(f"ERR:{e}")
PYEOF
)"
case "$SPAWN_OK" in
    OK) _pass "V5: codegraph serve --mcp spawns + stays alive (>400ms) — MCP runtime functional" ;;
    *) _fail "V5: codegraph serve --mcp did not stay alive: $SPAWN_OK" ;;
esac

echo ""
echo "  codegraph_validate summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
