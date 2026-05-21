#!/usr/bin/env bash
# codegraph_reindex.sh — §11.4.77 regeneration mechanism for the
# .codegraph/codegraph.db artefact.
#
# Forensic anchor:
#   - §11.4.30 .gitignore + no-versioned-build-artifacts
#   - §11.4.77 regeneration-mechanism-required
#   - §11.4.78 CodeGraph code-intelligence mandate
#
# Idempotent: safe to invoke repeatedly. On success writes a stamp file
# at .gitignore-meta/.regenerated/codegraph-db.ok so the pre-build gate
# can check freshness.
#
# Honest-gap (§11.4.6): on Darwin npm prefix /opt/homebrew (admin-owned),
# `npm install -g` works for users in the admin group. On other prefixes
# the operator may need to fix permissions per §11.4.78 (no sudo).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

STAMP_DIR="$REPO_ROOT/.gitignore-meta/.regenerated"
STAMP_FILE="$STAMP_DIR/codegraph-db.ok"

# Step 1: ensure the CLI is on PATH.
#
# Nezha fix (2026-05-21): npm installs to ~/.npm-global/bin (or whatever
# `npm config get prefix` returns) which interactive shells add to PATH
# via .bashrc / .zshrc — but non-interactive contexts (SSH-batch, cron,
# systemd-run, setup.sh invoked from a shell that didn't source .bashrc)
# inherit only /bin:/usr/bin:/usr/local/bin. Augment PATH from npm's
# reported prefix BEFORE bailing out. This makes the bootstrap robust
# to non-interactive invocation per §11.4.78's portability requirement.
if ! command -v codegraph >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
        NPM_PREFIX="$(npm config get prefix 2>/dev/null | tr -d '\r\n' || true)"
        if [ -n "$NPM_PREFIX" ] && [ -x "${NPM_PREFIX}/bin/codegraph" ]; then
            export PATH="${NPM_PREFIX}/bin:$PATH"
        fi
    fi
fi
if ! command -v codegraph >/dev/null 2>&1; then
    echo "RED: codegraph CLI not on PATH (also not at npm-prefix/bin/codegraph)" >&2
    echo "     install per §11.4.78:" >&2
    echo "       npm install -g @colbymchenry/codegraph" >&2
    echo "       (npm prefix MUST be user-writable; no sudo)" >&2
    exit 1
fi

# Step 2: ensure .codegraph/ is initialized.
if [ ! -f "$REPO_ROOT/.codegraph/config.json" ]; then
    echo "  bootstrapping: codegraph init"
    codegraph init "$REPO_ROOT" || {
        echo "RED: codegraph init failed" >&2
        exit 1
    }
fi

# Step 3: index (first time) or sync (incremental).
if [ ! -f "$REPO_ROOT/.codegraph/codegraph.db" ]; then
    echo "  full index (first run): codegraph index"
    codegraph index "$REPO_ROOT" || {
        echo "RED: codegraph index failed" >&2
        exit 1
    }
else
    echo "  incremental sync: codegraph sync"
    codegraph sync "$REPO_ROOT" || {
        echo "RED: codegraph sync failed" >&2
        exit 1
    }
fi

# Step 4: capture node count as positive evidence per §11.4.5 / §11.4.78.
# Strip ANSI escapes and surrounding whitespace before parsing the integer.
NODE_COUNT="$(codegraph status "$REPO_ROOT" 2>/dev/null \
    | sed -E $'s/\033\\[[0-9;]*m//g' \
    | grep -E 'Nodes:' | head -1 \
    | grep -oE '[0-9]+' | head -1)"
if [ -z "$NODE_COUNT" ] || [ "$NODE_COUNT" -lt 1 ] 2>/dev/null; then
    echo "RED: codegraph status reports zero nodes — index empty or unreadable" >&2
    exit 1
fi

# Step 5: stamp.
mkdir -p "$STAMP_DIR"
{
    echo "regenerated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host: $(uname -srm)"
    echo "node_count: $NODE_COUNT"
    echo "db_size: $(ls -la "$REPO_ROOT/.codegraph/codegraph.db" 2>/dev/null | awk '{print $5}') bytes"
    echo "codegraph_version: $(codegraph --version 2>/dev/null)"
} > "$STAMP_FILE"

echo ""
echo "  ✓ regenerated .codegraph/codegraph.db ($NODE_COUNT nodes); stamp: $STAMP_FILE"
exit 0
