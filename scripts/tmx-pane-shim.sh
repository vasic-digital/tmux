#!/usr/bin/env bash
# tmx-pane-shim.sh — split-topology pane launcher (§11.4.225, TMX_SERVER_SPLIT=1).
#
# Purpose
#   In the split topology every pane of a tmx session runs its shell inside
#   its OWN transient systemd scope under the session's workload slice
#   (tmxw-<name>.slice). The fleet a pane spawns is then CPU/Tasks-bounded
#   by the SLICE while the tmux server keeps its own small scope — fleet
#   bursts can never starve the server's keystroke/echo/timer handling
#   (HEL-006/HEL-003 forensics 2026-07-22/23).
#
# Usage
#   bash tmx-pane-shim.sh <workload-slice-unit>            outer stage (tmux
#       runs this as the window command / default-command)
#   bash tmx-pane-shim.sh --inner <slice> <marker-file>    inner stage (runs
#       INSIDE the pane scope via systemd-run; internal use only)
#
# Inputs        $1 = slice unit name (already \x2d-escaped by the wrapper);
#               $SHELL = user's shell (fallback /bin/bash).
# Outputs       exec's the user's login shell inside the pane scope.
# Side-effects  one transient run-*.scope under the slice per pane
#               (--collect: reaped by systemd when the shell exits).
# Dependencies  systemd-run + a reachable user manager ($XDG_RUNTIME_DIR/bus,
#               inherited from the tmux server's environment).
# Cross-refs    scripts/tmx.template (spawner + post-create verify),
#               scripts/tests/87_server_scope_split.sh,
#               docs/scripts/tmx-pane-shim.md.
#
# FAIL-CLOSED (§11.4.200/§11.4.201): a pane that cannot be placed INSIDE
# the slice must NEVER silently run outside it — that would put the whole
# fleet into the server's small scope (or an unbounded cgroup), strictly
# worse than the shared topology. Two independent layers:
#   outer  — the inner stage writes a PLACED marker only after verifying
#            its cgroup; a missing marker means scope creation failed =>
#            loud error + non-zero exit (the wrapper's post-create verify
#            then aborts the whole session for the first pane).
#   inner  — re-reads /proc/self/cgroup (the KERNEL's record, not the
#            tool's exit status) and aborts unless it names the slice.

set -u

_die() {
    printf '\n[tmx-pane-shim] FATAL: %s\n' "$*" >&2
    printf '[tmx-pane-shim] refusing to run this pane outside its workload slice (fail-closed, never mis-placed).\n' >&2
    # Keep the message visible briefly in later windows; the FIRST pane's
    # death is caught by the wrapper's post-create slice verify, which
    # aborts the whole session loudly.
    sleep 5
    exit 7
}

if [ "${1:-}" = "--inner" ]; then
    SLICE="${2:-}"
    MARKER="${3:-}"
    [ -n "$SLICE" ] || _die "inner stage called without a slice unit"
    # §11.4.200 verify-after-write against the authoritative source: the
    # kernel's own record of this process's cgroup must name the slice.
    if ! grep -Fq "/${SLICE}/" /proc/self/cgroup 2>/dev/null; then
        _die "pane cgroup '$(cat /proc/self/cgroup 2>/dev/null)' is NOT under ${SLICE}"
    fi
    # Placement verified — tell the outer stage before handing over.
    [ -n "$MARKER" ] && printf 'PLACED\n' > "$MARKER" 2>/dev/null
    USER_SHELL="${SHELL:-/bin/bash}"
    # shellcheck disable=SC2093  # deliberate: reach _die ONLY if exec fails
    exec "$USER_SHELL" -l
    _die "exec $USER_SHELL failed"
fi

SLICE="${1:-}"
[ -n "$SLICE" ] || _die "no workload-slice argument"
command -v systemd-run >/dev/null 2>&1 || _die "systemd-run not available in the pane environment"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
MARKER="$(mktemp "${TMUX_TMPDIR:-/tmp}/.tmx-pane-shim.XXXXXX" 2>/dev/null)" || MARKER=""

systemd-run --user --scope --collect --quiet --slice="$SLICE" -- \
    bash "$SELF" --inner "$SLICE" "$MARKER"
rc=$?

if [ -n "$MARKER" ]; then
    if [ ! -s "$MARKER" ]; then
        rm -f "$MARKER" 2>/dev/null
        _die "pane scope creation under $SLICE failed (systemd-run rc=$rc) — the shell never entered the slice"
    fi
    rm -f "$MARKER" 2>/dev/null
fi
# Marker present: the shell ran INSIDE the slice and has now exited —
# propagate its exit status so tmux closes the pane normally.
exit "$rc"
