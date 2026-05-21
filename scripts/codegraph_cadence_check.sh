#!/usr/bin/env bash
# codegraph_cadence_check.sh — §11.4.80 cadence enforcement.
#
# Mandate: weekly floor on `codegraph_update.sh` invocation. This script
# checks the stamp file `.gitignore-meta/.regenerated/codegraph-db.ok`
# (written by `scripts/codegraph_reindex.sh`) and emits one of three
# verdicts:
#
#   0  GREEN — stamp present + younger than $CADENCE_DAYS (default 7).
#   1  STALE — stamp older than $CADENCE_DAYS OR absent. Caller (e.g.
#              git pre-push hook) MAY choose to warn or refuse.
#   2  ENV   — environment problem (codegraph absent, no node count).
#
# Anti-bluff (§107): the verdict is derived from observed stamp content
# (regenerated_at + node_count) — NOT from a heartbeat file's existence.
# A stamp whose node_count is 0 or missing fails to GREEN even if the
# date is fresh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$REPO_ROOT/.gitignore-meta/.regenerated/codegraph-db.ok"
CADENCE_DAYS="${CODEGRAPH_CADENCE_DAYS:-7}"
QUIET="${1:-}"

emit() { [ "$QUIET" = "--quiet" ] || echo "$*"; }

# Env check.
if ! command -v codegraph >/dev/null 2>&1; then
    emit "RED: codegraph CLI not on PATH (§11.4.78 violation)"
    exit 2
fi

if [ ! -f "$STAMP" ]; then
    emit "STALE: codegraph stamp not present at $STAMP — run \`bash scripts/codegraph_reindex.sh\`"
    exit 1
fi

# Parse stamp.
STAMP_AT="$(grep '^regenerated_at:' "$STAMP" | head -1 | sed 's/^regenerated_at: *//')"
NODES="$(grep '^node_count:' "$STAMP" | head -1 | grep -oE '[0-9]+' | head -1)"

if [ -z "$STAMP_AT" ] || [ -z "$NODES" ]; then
    emit "STALE: codegraph stamp present but malformed (regenerated_at='$STAMP_AT' node_count='$NODES')"
    exit 1
fi
if [ "$NODES" -lt 1 ] 2>/dev/null; then
    emit "STALE: codegraph stamp reports node_count=$NODES — index empty per §11.4.78"
    exit 1
fi

# Age check. Use python3 for portable ISO-8601 arithmetic (BSD date
# rejects -d/-D conversion of ISO timestamps on macOS).
AGE_DAYS="$(python3 - "$STAMP_AT" <<'PYEOF'
import sys, datetime
stamp = sys.argv[1].rstrip('Z')
try:
    when = datetime.datetime.fromisoformat(stamp)
except Exception:
    print("ERR"); sys.exit(0)
now = datetime.datetime.utcnow()
delta = (now - when).total_seconds() / 86400
print(f"{delta:.1f}")
PYEOF
)"

if [ "$AGE_DAYS" = "ERR" ]; then
    emit "STALE: cannot parse stamp timestamp '$STAMP_AT'"
    exit 1
fi

# Integer comparison via awk (portable; no bash floating-point math).
OVER_FLOOR="$(awk -v a="$AGE_DAYS" -v c="$CADENCE_DAYS" 'BEGIN{print (a > c) ? 1 : 0}')"

if [ "$OVER_FLOOR" = "1" ]; then
    emit "STALE: codegraph index regenerated ${AGE_DAYS}d ago (>${CADENCE_DAYS}d floor) — run \`bash constitution/scripts/codegraph_update.sh\` + \`bash constitution/scripts/codegraph_sync.sh\` OR \`bash scripts/codegraph_reindex.sh\`"
    exit 1
fi

emit "GREEN: codegraph index regenerated ${AGE_DAYS}d ago ($NODES nodes) — within ${CADENCE_DAYS}d cadence per §11.4.80"
exit 0
