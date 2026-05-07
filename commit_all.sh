#!/usr/bin/env bash
# commit_all.sh — commit + push everything to GitHub + GitLab.
# Locks via .git/.commit_all.lock to prevent concurrent runs.
set -euo pipefail

if [ $# -lt 1 ]; then echo "usage: $0 \"commit message\""; exit 2; fi
MSG="$1"

LOCK="$(git rev-parse --git-dir)/.commit_all.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "ERROR: another commit_all.sh is already running"; exit 1; }

echo "[commit_all] git status..."
git status --short
echo ""

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
