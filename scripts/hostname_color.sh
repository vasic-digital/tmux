#!/usr/bin/env bash
# hostname_color.sh — deterministic hostname → tmux 256-color mapping.
#
# Usage:
#   ./hostname_color.sh                        # uses $(hostname)
#   ./hostname_color.sh myserver               # uses given name
#   COLOR=$(./hostname_color.sh)               # capture for tmux set
#
# Algorithm: DJB2 hash over hostname bytes → index into a curated palette
# of 27 visually distinct colours that work well as tmux status-bg.
#
# Constitution §1 anti-bluff: every invocation is deterministic — same
# hostname always produces the same colour. No randomness.

set -uo pipefail

H="${1:-$(hostname)}"

# ── DJB2 hash (31-bit, positive) ──────────────────────────────────────
h=5381
for ((i=0; i<${#H}; i++)); do
    c=$(printf '%d' "'${H:$i:1}")
    h=$(( ( (h << 5) + h ) + c ))
    h=$(( h & 0x7FFFFFFF ))
done

# ── Curated palette (27 colours) ──────────────────────────────────────
# Selected from xterm 256-colour space. Each entry is visually distinct
# from its neighbours and readable as a tmux status-bg with white fg.
PALETTE=(
    colour1    colour3    colour4    colour5
    colour6    colour9    colour11   colour12
    colour13   colour14   colour52   colour88
    colour130  colour166  colour172  colour178
    colour190  colour196  colour198  colour199
    colour200  colour202  colour208  colour214
    colour220  colour226  colour240
)

idx=$(( h % ${#PALETTE[@]} ))
echo "${PALETTE[$idx]}"
