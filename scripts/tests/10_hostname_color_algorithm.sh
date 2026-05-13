#!/usr/bin/env bash
# Test 10 — hostname→color algorithm: deterministic, palette-bound,
# visually varied across different hostnames.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALGO="$REPO_ROOT/scripts/hostname_color.sh"
echo "── Test 10: hostname→color algorithm ──"

if [ ! -x "$ALGO" ]; then
    echo "FAIL: $ALGO not found or not executable"
    exit 1
fi

PASS=0
FAIL=0

_pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ── T1: deterministic — same hostname → same colour every time ────────
C1=$("$ALGO" "testhost-001")
C2=$("$ALGO" "testhost-001")
if [ "$C1" = "$C2" ] && [ -n "$C1" ]; then
    _pass "T1: deterministic — 'testhost-001' → $C1 (twice)"
else
    _fail "T1: not deterministic: '$C1' vs '$C2'"
fi

# ── T2: each hostname maps to a valid tmux colourNNN ──────────────────
C3=$("$ALGO" "validity-check")
if echo "$C3" | grep -qE '^colour[0-9]+$'; then
    NUM=${C3#colour}
    if [ "$NUM" -ge 0 ] && [ "$NUM" -le 255 ]; then
        _pass "T2: '$C3' is a valid tmux 256-colour"
    else
        _fail "T2: colour index $NUM out of 0-255 range"
    fi
else
    _fail "T2: output '$C3' not of form colourNNN"
fi

# ── T3: different hostnames produce different colours ─────────────────
declare -A SEEN
DIVERGENT=0
for name in a b c d e f g h i j k l m n o p; do
    col=$("$ALGO" "$name")
    if [ -n "${SEEN[$col]:-}" ]; then
        :  # collision — allowed but we track the ratio
    else
        DIVERGENT=$((DIVERGENT + 1))
    fi
    SEEN[$col]=1
done
if [ "$DIVERGENT" -ge 12 ]; then
    _pass "T3: $DIVERGENT/16 hostnames produced unique colours (good spread)"
elif [ "$DIVERGENT" -ge 6 ]; then
    _pass "T3: $DIVERGENT/16 hostnames produced unique colours (spread ok, some collisions)"
else
    _fail "T3: only $DIVERGENT/16 unique colours — hash collision rate too high"
fi

# ── T4: output is in the curated palette ──────────────────────────────
# Extract palette from the script source. Strategy: take everything between
# `PALETTE=(` and the FIRST subsequent `)`, then collapse whitespace. This
# avoids sed-portability bugs around `)$` not matching when `tr '\n' ' '`
# leaves a trailing space (Darwin + GNU sed both affected).
PALETTE_LINE=$(awk '/^PALETTE=\(/{flag=1; sub(/^PALETTE=\(/, ""); }
                    flag{
                        if (match($0, /\)/)) { print substr($0, 1, RSTART-1); exit }
                        else { print }
                    }' "$ALGO" | tr '\n' ' ')
# Split into array (whitespace-separated). `read -ra <<<` only reads one
# line, so awk output must be flattened by tr first.
read -ra PALETTE <<<"$PALETTE_LINE"
C4=$("$ALGO" "palette-check")
IN_PALETTE=0
for p in "${PALETTE[@]}"; do
    [ "$p" = "$C4" ] && { IN_PALETTE=1; break; }
done
if [ "$IN_PALETTE" = "1" ]; then
    _pass "T4: '$C4' is a member of the curated palette (${#PALETTE[@]} colours)"
else
    _fail "T4: '$C4' not found in palette — algorithm may be out of sync"
fi

# ── T5: empty hostname falls back to $(hostname) ──────────────────────
HOST_SYS=$(hostname 2>/dev/null || echo "localhost")
C_EMPTY=$("$ALGO" "")
C_SYS=$("$ALGO" "$HOST_SYS")
if [ "$C_EMPTY" = "$C_SYS" ]; then
    _pass "T5: empty argument uses system hostname (→ $C_EMPTY)"
else
    _fail "T5: empty arg gave '$C_EMPTY' but system hostname '$HOST_SYS' gave '$C_SYS'"
fi

# ── summary ────────────────────────────────────────────────────────────
echo ""
echo "  Tests: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
