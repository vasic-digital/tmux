#!/usr/bin/env bash
# 59_oomd_preference_avoid.sh — TMX-083 systemd-oomd victim-avoidance guard
#
# ─── GUARDS ────────────────────────────────────────────────────────────
# A new tmx-<NAME>.scope carries `ManagedOOMPreference=avoid` so
# systemd-oomd deprioritizes tmx sessions as kill victims under
# user-<uid>.slice memory pressure.
#
# ─── FORENSIC ANCHOR (2026-08-12) ──────────────────────────────────────
# Operator report on the boba project (universal Constitution §11.4.238
# coverage escape — the bug was found manually, NOT by automated QA):
# tmux sessions still crashed "as soon as we continue work" on tmx
# v1.0.40 despite the v1.0.39 (TMX-079) fix landing MemoryMax=infinity /
# TasksMax=infinity / recycler-off-by-default. Live probes on
# 2026-08-12 REFUTED every mechanism TMX-079 patched (scope caps confirmed
# infinity, recycler dormant), then surfaced the residual killer:
# `systemd-oomd` was active with `ManagedOOMSwap=kill` and
# `ManagedOOMMemoryPressure=kill` on `user-1000.slice`. systemd-oomd
# operates orthogonally to cgroup Max= limits — it selects victims by
# PSI-pressure/swap-usage, not by scope memory ceiling — so under any
# real memory-pressure spike (heavy compose start + Angular build +
# Gradle daemons + parallel subagents on a shared user-slice) it
# SIGKILLs the entire `tmx-<NAME>.scope`, taking tmux + every process
# in the session with it. The fix is a single systemd property set at
# scope creation: `ManagedOOMPreference=avoid` tells oomd to
# deprioritize this scope as a victim.
#
# ─── RED_MODE POLARITY (universal Constitution §11.4.115) ──────────────
# RED_MODE=1 (default) — asserts the scope does NOT carry
#                       ManagedOOMPreference=avoid. PASSes on the
#                       pre-fix artifact (evidence the defect is real);
#                       FAILs on the post-fix artifact (evidence the
#                       fix genuinely propagated the property). This
#                       polarity captures the defect on a broken tmx
#                       and is UNSAFE to run permanently as a guard.
# RED_MODE=0            — asserts the scope DOES carry
#                       ManagedOOMPreference=avoid. This is the
#                       permanent regression guard: PASSes on the
#                       post-fix artifact, FAILs on any regression.
#
# ─── SKIPS (§11.4.3 honest topology-appropriate SKIP-with-reason) ──────
# - Non-Linux hosts: systemd-oomd is Linux-only; the Darwin parallel
#   path is RLIMIT-based and has no equivalent mechanism.
# - systemd < 249: ManagedOOMPreference was added in systemd 249.
#
# ─── CROSS-REFERENCES ──────────────────────────────────────────────────
# - scripts/tmx (shared-topology systemd-run, split-topology
#   systemd-run + workload-slice set-property — all three sites carry
#   the fix under a `sd_ver >= 249` guard).
# - scripts/tmx.template (the SOURCE of truth; scripts/tmx is
#   regenerated from it by scripts/setup.sh).
# - Fixed.md §J1 TMX-083.
# - CHANGELOG.md v1.0.41.
#
# ─── LAST VERIFIED ─────────────────────────────────────────────────────
# 2026-08-12 on nezha (systemd 258, tmx v1.0.41-pre): RED_MODE=1 PASSes
# on the pre-edit tmx (property unset), RED_MODE=0 PASSes on the
# post-edit tmx (property =avoid).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMX_BIN="$TMX_DIR/tmx"
RED_MODE="${RED_MODE:-1}"
HOST_OS="$(uname -s)"

# ─── SKIP: non-Linux ────────────────────────────────────────────────────
if [ "$HOST_OS" != "Linux" ]; then
    printf 'SKIP: 59_oomd_preference_avoid — systemd-oomd is Linux-only (host=%s)\n' "$HOST_OS" >&2
    exit 0
fi

# ─── SKIP: systemd < 249 ────────────────────────────────────────────────
sd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}' || echo 0)
if ! [ "${sd_ver:-0}" -ge 249 ] 2>/dev/null; then
    printf 'SKIP: 59_oomd_preference_avoid — systemd %s < 249, ManagedOOMPreference not supported\n' "${sd_ver:-unknown}" >&2
    exit 0
fi

# ─── tmx wrapper must be present ────────────────────────────────────────
if [ ! -x "$TMX_BIN" ]; then
    printf 'FAIL: tmx wrapper %s not found or not executable\n' "$TMX_BIN" >&2
    exit 1
fi

# ─── CREATE throwaway session ───────────────────────────────────────────
# Suffix by PID + epoch to avoid collision with concurrent test runs
# (§11.4.119 single-resource-owner discipline at the test-input layer).
NAME="oomdprobe$$$(date +%s)"
SOCK="tmx-$NAME"
SCOPE="tmx-$NAME.scope"

_cleanup() {
    # Best-effort tidy on every exit path (§11.4.14).
    "$TMX_BIN" kill-session -t "$NAME" 2>/dev/null || true
    systemctl --user stop "$SCOPE" 2>/dev/null || true
    # Recycler marker + lock tidy — matches the wrapper's `delete` verb.
    _rc_dir="${TMUX_TMPDIR:-/tmp}/tmx-recycler-$(id -u)"
    rm -f  "$_rc_dir/$NAME.detached" 2>/dev/null || true
    rm -rf "$_rc_dir/$NAME.lock"     2>/dev/null || true
}
trap _cleanup EXIT INT TERM

# Force unlimited caps + shared topology + recycler off so no ambient
# env-var forces a topology that would confuse the property read.
env -u TMX_CPU -u TMX_TASKS -u TMX_MEM -u TMX_RECYCLE_IDLE_SECS -u TMX_SERVER_SPLIT \
    "$TMX_BIN" new -s "$NAME" -d >/dev/null 2>&1 || {
    printf 'FAIL: could not create test session %s (tmx new -s ... -d failed)\n' "$NAME" >&2
    exit 1
}

# systemd-run --scope is synchronous by the time control returns, but
# give property propagation a moment on slower hosts (matches the
# existing `_apply_oom_score` sleep 0.3 pattern in scripts/tmx).
sleep 0.5

# ─── READ ManagedOOMPreference from the live scope ──────────────────────
val=$(systemctl --user show "$SCOPE" -p ManagedOOMPreference --value 2>/dev/null || echo "")

# ─── VERDICT via RED_MODE polarity ──────────────────────────────────────
if [ "$RED_MODE" = "1" ]; then
    # RED — pre-fix state: property MUST NOT be `avoid`.
    if [ "$val" = "avoid" ]; then
        printf 'FAIL (RED): scope %s has ManagedOOMPreference=avoid on what should be pre-fix code\n' "$SCOPE" >&2
        printf 'FAIL (RED): the test cannot capture the pre-fix defect — either the fix is already in, or RED_MODE was set wrong\n' >&2
        exit 1
    fi
    printf 'PASS (RED): scope %s has ManagedOOMPreference=%s (not avoid) — defect reproduced\n' "$SCOPE" "${val:-<unset>}" >&2
else
    # GREEN — post-fix guard: property MUST be `avoid`.
    if [ "$val" != "avoid" ]; then
        printf 'FAIL (GREEN): scope %s has ManagedOOMPreference=%s, expected avoid\n' "$SCOPE" "${val:-<unset>}" >&2
        printf 'FAIL (GREEN): the TMX-083 fix (ManagedOOMPreference=avoid on systemd-run --scope) is missing or regressed\n' >&2
        exit 1
    fi
    printf 'PASS (GREEN): scope %s has ManagedOOMPreference=avoid — TMX-083 regression guard confirmed\n' "$SCOPE" >&2
fi

exit 0
