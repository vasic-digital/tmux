#!/usr/bin/env bash
# commit_all.sh — commit + push everything to GitHub + GitLab.
# Locks via .git/.commit_all.lock to prevent concurrent runs.
set -euo pipefail

if [ $# -lt 1 ]; then echo "usage: $0 \"commit message\""; exit 2; fi
MSG="$1"

LOCK="$(git rev-parse --git-dir)/.commit_all.lock"
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { echo "ERROR: another commit_all.sh is already running"; exit 1; }
else
    # flock is GNU/Linux util-linux; macOS / Alpine-busybox lack it. The
    # § operator-honest path is to declare the degradation explicitly
    # rather than print a wrong "another instance is running" message.
    echo "[commit_all] WARN: 'flock' not available on this host — concurrent-run protection disabled."
fi

echo "[commit_all] git status..."
git status --short
echo ""

# ─── §11.4.93/95 — workable-items DB drift gate ─────────────────────────
# Before staging, verify the SQLite SSoT for workable items is in sync
# with the Markdown trackers. Graceful-degrade: if the binary or DB is
# missing (old branches, fresh clones pre-PWU-Q3), skip silently so this
# wrapper still works.
REPO_ROOT="$(git rev-parse --show-toplevel)"
WI_BIN="$REPO_ROOT/cmd/workable-items/workable-items"
WI_DB="$REPO_ROOT/docs/workable_items.db"
WI_ISSUES="$REPO_ROOT/Issues.md"
WI_FIXED="$REPO_ROOT/Fixed.md"
if [ -x "$WI_BIN" ] && [ -f "$WI_DB" ] && [ -f "$WI_ISSUES" ] && [ -f "$WI_FIXED" ]; then
    echo "[commit_all] §11.4.93/95 workable-items: checking md↔db drift..."
    if ! "$WI_BIN" diff --db "$WI_DB" --issues "$WI_ISSUES" --fixed "$WI_FIXED" 2>&1 | head -20; then
        echo "[commit_all] WARN: workable-items DB drift detected; running sync md-to-db..."
        "$WI_BIN" sync md-to-db \
            --db "$WI_DB" \
            --issues "$WI_ISSUES" \
            --fixed "$WI_FIXED" || \
            echo "[commit_all] WARN: workable-items sync md-to-db failed (non-fatal)"
    fi
else
    # Honest-skip per §107: declare what's missing rather than silently pass.
    echo "[commit_all] §11.4.93/95 workable-items: SKIP (binary/db/tracker absent)"
fi

# Stage everything (tracked + untracked, respecting .gitignore)
git add -A

if git diff --cached --quiet; then
    echo "[commit_all] nothing to commit"
else
    git commit -m "$MSG" --signoff
fi

echo ""
echo "[commit_all] ensure remotes (github + gitlab)"
if ! git remote get-url github >/dev/null 2>&1; then
    git remote add github git@github.com:vasic-digital/tmux.git
fi
if ! git remote get-url gitlab >/dev/null 2>&1; then
    git remote add gitlab git@gitlab.com:vasic-digital/tmux.git
fi

echo ""
echo "[commit_all] pushing to github..."
git push -u github "$(git symbolic-ref --short HEAD)" 2>&1 | tail -5
echo ""
echo "[commit_all] pushing to gitlab..."
git push -u gitlab "$(git symbolic-ref --short HEAD)" 2>&1 | tail -5

echo ""
echo "[commit_all] === Push Summary ==="
echo "  Branch: $(git symbolic-ref --short HEAD)"
echo "  Commit: $(git rev-parse --short HEAD)"
echo "  Message: $MSG"
echo "  Push: github + gitlab"
