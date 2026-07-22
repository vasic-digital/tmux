#!/usr/bin/env bash
# burst_ab_probe.sh — §11.4.115-style A/B evidence capture for the v1.0.37
# cpu.max.burst change: identical bursty workload in two throwaway scopes,
# one with burst=0 (pre-change behaviour) and one with burst=quota (the new
# wrapper default). Oracle: cgroup cpu.stat nr_throttled / nr_periods and
# throttled_usec DELTAS over a fixed window (§11.4.201 authoritative source).
#
# Workload shape mirrors the live forensics (2026-07-22): average demand
# well UNDER quota, spikes well OVER it — 4 workers each spinning ~60 ms
# then sleeping 150 ms inside a 100%-quota (1 CPU) scope. Average ≈ 1 CPU,
# spikes ≈ 4 CPUs.
#
# Usage: bash burst_ab_probe.sh [window_seconds]   (default 12)
set -u
WIN="${1:-12}"
CGROOT=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice

_run_phase() {  # _run_phase <label> <burst_usec>
    local label="$1" burst="$2"
    local unit="tmxburstprobe_${label}_$$.scope"
    # Workload: every 600 ms, TWO simultaneous ~60 ms spinners (≈120 ms CPU
    # demanded inside one 100 ms period → overflows quota during the spike)
    # then quiet — average ≈ 0.2 CPUs, far under the 1-CPU quota, so unused
    # quota banks up between spikes. Mirrors the live signature: average
    # demand under quota, episodic intra-period spikes over it.
    systemd-run --user --scope --quiet --unit="$unit" \
        -p "CPUQuota=100%" -p "Delegate=yes" \
        bash -c 'while :; do ( i=0; while [ $i -lt 40000 ]; do i=$((i+1)); done ) & ( i=0; while [ $i -lt 40000 ]; do i=$((i+1)); done ) & wait; sleep 0.6; done' \
        >/dev/null 2>&1 &
    local runner=$!
    sleep 1
    local cg="$CGROOT/$unit"
    [ -d "$cg" ] || cg="$(systemctl --user show "$unit" -p ControlGroup --value 2>/dev/null | sed 's|^|/sys/fs/cgroup|')"
    if [ -n "$burst" ] && [ "$burst" != "0" ] && [ -f "$cg/cpu.max.burst" ]; then
        echo "$burst" > "$cg/cpu.max.burst" 2>/dev/null || true
    fi
    local p0 t0 u0 p1 t1 u1
    p0=$(awk '/^nr_periods/{print $2}' "$cg/cpu.stat"); t0=$(awk '/^nr_throttled/{print $2}' "$cg/cpu.stat"); u0=$(awk '/^throttled_usec/{print $2}' "$cg/cpu.stat")
    sleep "$WIN"
    p1=$(awk '/^nr_periods/{print $2}' "$cg/cpu.stat"); t1=$(awk '/^nr_throttled/{print $2}' "$cg/cpu.stat"); u1=$(awk '/^throttled_usec/{print $2}' "$cg/cpu.stat")
    echo "$label: burst=$(cat "$cg/cpu.max.burst" 2>/dev/null) window=${WIN}s periods=$((p1-p0)) throttled=$((t1-t0)) ratio=$(( (t1-t0)*100 / ( (p1-p0)>0 ? (p1-p0) : 1 ) ))% throttled_usec_delta=$((u1-u0))"
    kill "$runner" 2>/dev/null
    systemctl --user stop "$unit" >/dev/null 2>&1
    wait "$runner" 2>/dev/null
}

echo "# burst A/B probe $(date -Is) — quota=100% (1 CPU); every 600ms two simultaneous ~60ms spinners (spike ~120ms CPU inside one 100ms period; average ~0.2 CPU)"
_run_phase A_burst0 0
_run_phase B_burstQ 100000
