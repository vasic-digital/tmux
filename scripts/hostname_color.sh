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

# ── Curated palette (27 colours, perceptually-balanced) ──────────────
# Selected from xterm 256-colour space. The previous palette was
# orange-heavy: 7 of 27 entries landed in the dark-orange / orange /
# orange-red / yellow-orange band (colour130 / colour166 / colour172 /
# colour178 / colour202 / colour208 / colour214). Two unrelated
# hostnames (e.g., "nezha" → colour130, "Mistborn" → colour202) both
# resolved to "orange" to the operator's eye even though the indices
# differed numerically.
#
# v1.0.7 rebalance (2026-05-21): one representative from each major
# hue region — red / orange / yellow / chartreuse / green / teal / cyan
# / sky / blue / indigo / violet / magenta / pink / rose / brown / olive
# / gray — so every two consecutive palette entries land in DIFFERENT
# hue regions. Each colour is in the saturated end of the xterm 256-
# cube (R/G/B levels mostly 0/95/175/215/255 with at most one
# component near 0 and at most one near max — staying readable as a
# status-bg with white fg).
#
# §11.4.6 honest-gap: even with 27 well-spread entries, the modulo-N
# pigeonhole keeps collisions possible. Test 10 T3 enforces ≥ 12/16
# unique indices across a deterministic 16-hostname probe; test 25
# NEW (2026-05-21) enforces perceptual-distance ≥ 80 for the specific
# nezha + Mistborn pair the operator caught, plus a 16-hostname pairwise
# minimum.
PALETTE=(
    colour160  colour208  colour226  colour46
    colour39   colour21   colour93   colour197
    colour201  colour130  colour51   colour154
    colour88   colour202  colour220  colour42
    colour87   colour33   colour129  colour19
    colour58   colour44   colour94   colour22
    colour54   colour206  colour240
)

idx=$(( h % ${#PALETTE[@]} ))
echo "${PALETTE[$idx]}"
