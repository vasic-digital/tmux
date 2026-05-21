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
#
# CodeGraph 0.8.0 changed semantics from 0.6.8: `codegraph index` now
# refuses to run unless `codegraph init` has produced both a config AND
# the empty DB schema. The presence of `.codegraph/config.json` alone
# does NOT count as "initialized" anymore. So this script must run
# `codegraph init` whenever the DB is missing — but `init` SILENTLY
# CLOBBERS our tracked customisations in config.json (verified on Nezha
# 2026-05-21: SHA changes b50f440… → 0cfa449…). To preserve our config
# across init clobber, we snapshot it, run init, then restore.
#
# Customisations to preserve (§11.4.10 + §11.4.79):
#   - Added include globs: **/*.sh, **/*.bash, **/*.zsh
#   - Added secret-exclusion globs: **/.env, **/.env.*, **/*.env, **/*.pem,
#     **/*.key, **/*.crt, **/id_rsa*, **/id_ed25519*, **/secrets/**, **/api_keys.sh
#   - Excluded third-party submodule: tmux/**, tmux/build*/**
#   - Codegraph-own artefacts kept excluded: .codegraph/codegraph.db*, .codegraph/cache/**
#   - Per-machine personal context: .remember/**
#   - Exported docs: **/*.html, **/*.pdf
#
# These are deterministic — re-applied after every init.

CG_CFG="$REPO_ROOT/.codegraph/config.json"
CG_DB="$REPO_ROOT/.codegraph/codegraph.db"

# Customisations we must preserve across any `codegraph init` clobber.
# Source of truth: this script. Per §11.4.6, this is honest about what
# our project actually requires from the codegraph config — the tracked
# .codegraph/config.json could drift; the customisations list here is
# the canonical authority.
#
# §11.4.10 secret-exclusion (credentials never reach the index):
CUSTOM_EXCLUDE_SECRETS=(
    '**/.env' '**/.env.*' '**/*.env'
    '**/*.pem' '**/*.key' '**/*.crt'
    '**/id_rsa*' '**/id_ed25519*' '**/secrets/**' '**/.netrc'
    '**/api_keys.sh'
)
# §11.4.79 third-party (own-org constitution/ + Containers/ MUST stay
# INCLUDED — NOT in the exclude list):
CUSTOM_EXCLUDE_THIRDPARTY=(
    'tmux/**' 'tmux/build*/**'
)
# CodeGraph artefacts + per-machine personal context + binary exports:
CUSTOM_EXCLUDE_LOCAL=(
    '.codegraph/codegraph.db*' '.codegraph/cache/**'
    '**/*.html' '**/*.pdf'
    '.remember/**'
)
# Source languages the project actually uses (shell-heavy):
CUSTOM_INCLUDE=(
    '**/*.sh' '**/*.bash' '**/*.zsh'
)

# Decide whether init is needed. Init is needed when (a) config.json
# is absent, OR (b) DB is absent (codegraph 0.8.0 refuses index without
# the init-created DB schema even if config exists). Init clobbers
# config.json, so we always snapshot + merge after.
NEED_INIT=0
if [ ! -f "$CG_CFG" ] || [ ! -f "$CG_DB" ]; then
    NEED_INIT=1
fi

if [ "$NEED_INIT" -eq 1 ]; then
    CG_CFG_BACKUP=""
    if [ -f "$CG_CFG" ]; then
        CG_CFG_BACKUP="$(mktemp)"
        cp "$CG_CFG" "$CG_CFG_BACKUP"
    fi
    echo "  bootstrapping: codegraph init"
    codegraph init "$REPO_ROOT" >/dev/null 2>&1 || {
        echo "RED: codegraph init failed" >&2
        [ -n "$CG_CFG_BACKUP" ] && cp "$CG_CFG_BACKUP" "$CG_CFG"
        rm -f "$CG_CFG_BACKUP"
        exit 1
    }
    # Always (re-)apply our customisations on top of whatever init wrote.
    # If we had a prior config, also merge its include/exclude (preserves
    # operator-side additions). The CUSTOM_* arrays above are the canonical
    # authority — they're ALWAYS applied even if the backup is missing.
    CUSTOM_INC_JSON="$(printf '%s\n' "${CUSTOM_INCLUDE[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    CUSTOM_EXC_JSON="$(printf '%s\n' "${CUSTOM_EXCLUDE_SECRETS[@]}" "${CUSTOM_EXCLUDE_THIRDPARTY[@]}" "${CUSTOM_EXCLUDE_LOCAL[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    BACKUP_PATH="${CG_CFG_BACKUP:-/dev/null}"
    CFG_PATH="$CG_CFG" \
    BAK_PATH="$BACKUP_PATH" \
    CUSTOM_INC="$CUSTOM_INC_JSON" \
    CUSTOM_EXC="$CUSTOM_EXC_JSON" \
    python3 <<'PYEOF'
import json, os, sys
cfg_path = os.environ['CFG_PATH']
bak_path = os.environ['BAK_PATH']
custom_inc = json.loads(os.environ['CUSTOM_INC'])
custom_exc = json.loads(os.environ['CUSTOM_EXC'])
with open(cfg_path) as f: cur = json.load(f)
bak = {}
if bak_path != '/dev/null':
    try:
        with open(bak_path) as f: bak = json.load(f)
    except Exception:
        bak = {}
def union_keep_order(*lists):
    seen, out = set(), []
    for lst in lists:
        for x in (lst or []):
            if x not in seen:
                seen.add(x); out.append(x)
    return out
cur['include'] = union_keep_order(cur.get('include', []), bak.get('include', []), custom_inc)
cur['exclude'] = union_keep_order(cur.get('exclude', []), bak.get('exclude', []), custom_exc)
with open(cfg_path, 'w') as f:
    json.dump(cur, f, indent=2); f.write('\n')
print(f"  customisations applied: {len(cur['include'])} include / {len(cur['exclude'])} exclude entries")
PYEOF
    rm -f "$CG_CFG_BACKUP"
fi

# Step 3: index (first time / post-init) or sync (incremental).
if [ ! -f "$CG_DB" ] || [ "$(stat -f '%z' "$CG_DB" 2>/dev/null || stat -c '%s' "$CG_DB" 2>/dev/null || echo 0)" -lt 4096 ] || [ "$NEED_INIT" -eq 1 ]; then
    echo "  full index: codegraph index"
    codegraph index "$REPO_ROOT" 2>&1 | tail -3 || {
        echo "RED: codegraph index failed" >&2
        exit 1
    }
else
    echo "  incremental sync: codegraph sync"
    codegraph sync "$REPO_ROOT" 2>&1 | tail -3 || {
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
