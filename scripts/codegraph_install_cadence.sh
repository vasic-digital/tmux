#!/usr/bin/env bash
# codegraph_install_cadence.sh — install the §11.4.80 weekly cadence
# trigger on the operator's host.
#
# Two layers:
#   1. **launchd plist (macOS)** — installs a per-user
#      LaunchAgent that fires `codegraph_reindex.sh` every 7 days.
#      File: ~/Library/LaunchAgents/digital.vasic.tmux.codegraph-cadence.plist
#   2. **git pre-push hook** — refuses (or warns, per CADENCE_MODE) when
#      `scripts/codegraph_cadence_check.sh` reports STALE.
#
# Anti-bluff (§107): the install records what it actually wrote and
# `launchctl print` reflects the installed job. The hook reads the
# stamp file's content (not just existence) before allowing push.
#
# Linux equivalent (per §11.4.81 cross-platform-parity): writes a
# systemd --user timer unit at ~/.config/systemd/user/.
#
# Usage:
#   bash scripts/codegraph_install_cadence.sh                # install
#   bash scripts/codegraph_install_cadence.sh --uninstall    # remove
#
# Env:
#   CADENCE_MODE=warn|block   pre-push hook behavior on STALE
#                              (default: warn; release-blocker mode = block)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_OS="$(uname -s)"
ACTION="${1:-install}"
CADENCE_MODE="${CADENCE_MODE:-warn}"

# Idempotent install OR clean uninstall.
case "$ACTION" in
    install|--install) ;;
    --uninstall|uninstall) ;;
    *) echo "usage: $0 [install|--uninstall]" >&2; exit 2 ;;
esac

PLIST_LABEL="digital.vasic.tmux.codegraph-cadence"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE_PATH="${SYSTEMD_USER_DIR}/tmux-codegraph-cadence.service"
SYSTEMD_TIMER_PATH="${SYSTEMD_USER_DIR}/tmux-codegraph-cadence.timer"
HOOK_DEST="${REPO_ROOT}/.git/hooks/pre-push"

if [ "$ACTION" = "--uninstall" ] || [ "$ACTION" = "uninstall" ]; then
    case "$HOST_OS" in
        Darwin)
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            rm -f "$PLIST_PATH"
            echo "  ✓ unloaded + removed $PLIST_PATH"
            ;;
        Linux)
            systemctl --user stop tmux-codegraph-cadence.timer 2>/dev/null || true
            systemctl --user disable tmux-codegraph-cadence.timer 2>/dev/null || true
            rm -f "$SYSTEMD_SERVICE_PATH" "$SYSTEMD_TIMER_PATH"
            systemctl --user daemon-reload 2>/dev/null || true
            echo "  ✓ disabled + removed systemd user timer"
            ;;
    esac
    if grep -q "codegraph_cadence_check" "$HOOK_DEST" 2>/dev/null; then
        rm -f "$HOOK_DEST"
        echo "  ✓ removed pre-push hook"
    fi
    exit 0
fi

# --- INSTALL ---

# §11.4.81 cross-platform-parity dispatch.
case "$HOST_OS" in
    Darwin)
        mkdir -p "$HOME/Library/LaunchAgents"
        # StartInterval=604800 seconds = 7 days. RunAtLoad=false to avoid
        # firing on every login; the cadence is anchored to the install
        # moment, not to user session.
        cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REPO_ROOT}/scripts/codegraph_reindex.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>604800</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.gitignore-meta/.regenerated/codegraph-cadence.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.gitignore-meta/.regenerated/codegraph-cadence.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLIST
        # Reload if already loaded (idempotent).
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        if launchctl load "$PLIST_PATH" 2>/dev/null; then
            echo "  ✓ launchd job '${PLIST_LABEL}' loaded (weekly at 7d interval)"
            # Anti-bluff: confirm the job is registered.
            if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
                echo "  ✓ positive evidence: launchctl list shows ${PLIST_LABEL}"
            else
                echo "  ⚠ launchctl list does NOT show ${PLIST_LABEL} (load may have failed silently)"
            fi
        else
            echo "  ⚠ launchctl load failed — fall back to manual invocation"
        fi
        ;;
    Linux)
        mkdir -p "$SYSTEMD_USER_DIR"
        cat > "$SYSTEMD_SERVICE_PATH" <<UNIT
[Unit]
Description=tmux CodeGraph re-index (§11.4.80 weekly cadence)

[Service]
Type=oneshot
WorkingDirectory=${REPO_ROOT}
ExecStart=/bin/bash ${REPO_ROOT}/scripts/codegraph_reindex.sh
UNIT
        cat > "$SYSTEMD_TIMER_PATH" <<TIMER
[Unit]
Description=tmux CodeGraph re-index (§11.4.80 weekly cadence) — timer

[Timer]
OnBootSec=15min
OnUnitActiveSec=1w
Unit=tmux-codegraph-cadence.service

[Install]
WantedBy=timers.target
TIMER
        systemctl --user daemon-reload 2>/dev/null || true
        if systemctl --user enable --now tmux-codegraph-cadence.timer 2>/dev/null; then
            echo "  ✓ systemd --user timer enabled (1w cadence)"
            if systemctl --user is-active --quiet tmux-codegraph-cadence.timer; then
                echo "  ✓ positive evidence: systemctl --user reports timer active"
            fi
        else
            echo "  ⚠ systemctl --user enable failed — fall back to manual invocation"
        fi
        ;;
    *)
        echo "  ⚠ host $HOST_OS not supported for automatic cadence; manual invocation only"
        ;;
esac

# --- git pre-push hook (cross-platform, runs in bash) ---
mkdir -p "$(dirname "$HOOK_DEST")"
cat > "$HOOK_DEST" <<HOOK
#!/usr/bin/env bash
# Auto-installed by scripts/codegraph_install_cadence.sh per §11.4.80.
# Checks codegraph index staleness before allowing push.
#
# CADENCE_MODE=warn   (default): print warning, allow push
# CADENCE_MODE=block            : refuse push when STALE
SCRIPT="\$(git rev-parse --show-toplevel)/scripts/codegraph_cadence_check.sh"
[ -x "\$SCRIPT" ] || exit 0
if ! "\$SCRIPT"; then
    if [ "\${CADENCE_MODE:-${CADENCE_MODE}}" = "block" ]; then
        echo "" >&2
        echo "REFUSING push — §11.4.80 codegraph cadence is STALE (see above)." >&2
        echo "  Run: bash scripts/codegraph_reindex.sh" >&2
        echo "  Or temporarily: CADENCE_MODE=warn git push" >&2
        exit 1
    fi
    echo "" >&2
    echo "WARNING — §11.4.80 cadence STALE (push allowed; CADENCE_MODE=warn)." >&2
fi
exit 0
HOOK
chmod +x "$HOOK_DEST"
echo "  ✓ git pre-push hook installed at $HOOK_DEST (CADENCE_MODE=$CADENCE_MODE)"

echo ""
echo "  §11.4.80 cadence installation: COMPLETE on $HOST_OS"
