#!/usr/bin/env bash
# 62_distribution_orchestrator.sh
# ─────────────────────────────────────────────────────────────────────────
# Purpose:    End-to-end anti-bluff test for scripts/tmx-orchestrator/ — the
#             Containers-submodule distribution orchestrator binary. Proves
#             the operator deliverable ("a proper binary using the Containers
#             submodule lib to orchestrate distribution") REALLY works:
#               T1 build the consumer binary (go build against ../../Containers)
#               T2 `hosts` — register + SSH-probe nezha, assert REACHABLE=yes
#               T3 `distribute` — run a REAL nginx container on nezha with a
#                  published host port + HTTP health check; assert HEALTHY 200
#                  AND independently confirm via `podman ps` on nezha
#               T4 `down` — teardown; assert the container is REMOVED on nezha
#
# Anti-bluff: T3 reads positive sink-side evidence (HTTP 200 from the deployed
#             service + podman published-port state on the host) — not metadata.
#
# Opt-in (§11.4.3 topology dispatch): deploys a real container on a remote
#             host, so it is gated behind TMX_TEST_REMOTE=1 (like test 32) and
#             SKIPs-with-reason otherwise. Also SKIPs if Go, the orchestrator
#             source, the .env, or nezha are unavailable.
#
# Usage:      TMX_TEST_REMOTE=1 bash scripts/tests/62_distribution_orchestrator.sh
# Side-effects: builds scripts/tmx-orchestrator-bin (gitignored); deploys +
#             removes a uniquely-named container on the configured remote host.
#             trap cleanup removes the container on every exit path (§11.4.14).
# Dependencies: go, ssh, the configured remote host (nezha), Containers/.env.
# §11.4.67:  POSIX `sh -n` clean AND `bash -n` clean.
# Last verified: 2026-06-16
# ─────────────────────────────────────────────────────────────────────────
set -uo pipefail
# §11.4.3/D2 TMPDIR-HARDCODE-001: route scratch through ${TMPDIR:-/tmp}.
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
_wtest_dir="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest_dir" 2>/dev/null || [ ! -w "$_wtest_dir" ]; then
    echo "SKIP 62: scratch root $SCRATCH not writable (disk full / RO) — §11.4.3"
    rm -rf "$_wtest_dir" 2>/dev/null || true
    exit 77
fi
rm -rf "$_wtest_dir" 2>/dev/null || true

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
ORCH_DIR="$REPO_ROOT/scripts/tmx-orchestrator"
BIN="$REPO_ROOT/scripts/tmx-orchestrator-bin"
ENV_FILE="$REPO_ROOT/Containers/.env"
NAME="tmx-orch-t62-$$"
HOSTNAME_ADDR=""
HEALTH_PORT=""

cleanup() {
    if [ -n "$HOSTNAME_ADDR" ]; then
        ssh -o ConnectTimeout=8 "milosvasic@${HOSTNAME_ADDR}" \
            "podman rm -f $NAME >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── topology / opt-in gates (SKIP-with-reason) ──────────────────────────────
if [ "${TMX_TEST_REMOTE:-0}" != "1" ]; then
    echo "SKIP: 62 remote distribution test requires TMX_TEST_REMOTE=1 (opt-in — deploys a real container on a remote host)"
    exit 0
fi
if ! command -v go >/dev/null 2>&1; then
    echo "SKIP: 62 go toolchain not available (§11.4.3)"
    exit 0
fi
if [ ! -f "$ORCH_DIR/main.go" ]; then
    echo "SKIP: 62 orchestrator source $ORCH_DIR/main.go absent"
    exit 0
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "SKIP: 62 $ENV_FILE absent (configure remote host(s) first)"
    exit 0
fi

# Resolve the configured host address from .env (HOST_1).
HOSTNAME_ADDR="$(grep -E '^CONTAINERS_REMOTE_HOST_1_ADDRESS=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')"
if [ -z "$HOSTNAME_ADDR" ]; then
    echo "SKIP: 62 no CONTAINERS_REMOTE_HOST_1_ADDRESS in $ENV_FILE"
    exit 0
fi
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "milosvasic@${HOSTNAME_ADDR}" 'command -v podman >/dev/null' >/dev/null 2>&1; then
    echo "SKIP: 62 remote host $HOSTNAME_ADDR unreachable or lacks podman (§11.4.3)"
    exit 0
fi

echo "── Test 62: Containers-submodule distribution orchestrator (remote: $HOSTNAME_ADDR) ──"
P=0; F=0

# ── T1: build the consumer binary ───────────────────────────────────────────
if (cd "$ORCH_DIR" && go build -o "$BIN" . 2>"$SCRATCH/t62_build.$$"); then
    echo "PASS: T1 — orchestrator builds against the Containers submodule"
    P=$((P+1))
else
    echo "FAIL: T1 — orchestrator build failed:"; cat "$SCRATCH/t62_build.$$" 2>/dev/null | tail -5
    rm -f "$SCRATCH/t62_build.$$"; F=$((F+1))
    echo "  Tests: PASS=$P  FAIL=$F  SKIP=0"; exit 1
fi
rm -f "$SCRATCH/t62_build.$$"

# ── T2: hosts probe ─────────────────────────────────────────────────────────
HOUT="$("$BIN" hosts --env "$ENV_FILE" 2>&1)"
if printf '%s\n' "$HOUT" | grep -qE "nezha[[:space:]]+${HOSTNAME_ADDR}[[:space:]]+[0-9]+[[:space:]]+yes"; then
    echo "EVIDENCE (T2): $(printf '%s\n' "$HOUT" | grep -E "yes" | tail -1 | tr -s ' ')"
    echo "PASS: T2 — hosts probe reports nezha REACHABLE with real /proc resources"
    P=$((P+1))
else
    echo "FAIL: T2 — hosts probe did not report nezha reachable:"; printf '%s\n' "$HOUT" | tail -4
    F=$((F+1))
fi

# ── T3: distribute a real container + health check ──────────────────────────
# Pick a free host port on the remote (avoid pre-bound ports).
HEALTH_PORT=""
for p in 18080 28080 38080 47090; do
    # Portable free-port probe: `ss -ltn` lists listening TCP sockets on the
    # remote (NOT bash-only /dev/tcp, which silently no-ops under dash/busybox
    # sh and would pick a bound port — a §11.4.1 FAIL-bluff). Port absent from
    # the listen table => free.
    if ssh -o ConnectTimeout=8 "milosvasic@${HOSTNAME_ADDR}" "ss -ltn 2>/dev/null | grep -qE ':${p}[[:space:]]'"; then
        :  # port already listening, try next
    else
        HEALTH_PORT="$p"; break
    fi
done
if [ -z "$HEALTH_PORT" ]; then
    echo "SKIP: T3 — no free host port found on $HOSTNAME_ADDR (tried 18080/28080/38080/47090)"
else
    DOUT="$("$BIN" distribute --image docker.io/library/nginx:alpine \
        --name "$NAME" --port 80 --publish "$HEALTH_PORT" \
        --health http --health-path / --env "$ENV_FILE" --timeout 4m 2>&1)"
    DRC=$?
    PS_LINE="$(ssh -o ConnectTimeout=8 "milosvasic@${HOSTNAME_ADDR}" "podman ps --format '{{.Names}}|{{.Ports}}' | grep $NAME" 2>/dev/null)"
    if [ "$DRC" -eq 0 ] \
        && printf '%s\n' "$DOUT" | grep -q "HEALTHY" \
        && printf '%s\n' "$DOUT" | grep -q "status_code: 200" \
        && [ -n "$PS_LINE" ]; then
        echo "EVIDENCE (T3): $(printf '%s\n' "$DOUT" | grep HEALTHY | tail -1); podman: $PS_LINE"
        echo "PASS: T3 — distributed a real nginx container on $HOSTNAME_ADDR (published :$HEALTH_PORT), HTTP health = 200"
        P=$((P+1))
    else
        echo "FAIL: T3 — distribute/health did not confirm a healthy deployed service (rc=$DRC):"
        printf '%s\n' "$DOUT" | grep -E "Health|fail|Error|summary" | tail -5
        F=$((F+1))
    fi
fi

# ── T4: teardown ────────────────────────────────────────────────────────────
"$BIN" down --name "$NAME" --env "$ENV_FILE" >/dev/null 2>&1 || true
if ssh -o ConnectTimeout=8 "milosvasic@${HOSTNAME_ADDR}" "podman ps -a --format '{{.Names}}' | grep -q $NAME" 2>/dev/null; then
    echo "FAIL: T4 — container $NAME still present on $HOSTNAME_ADDR after down"
    F=$((F+1))
else
    echo "PASS: T4 — down removed the container on $HOSTNAME_ADDR (verified via podman ps -a)"
    P=$((P+1))
fi

echo ""
echo "  Tests: PASS=$P  FAIL=$F  SKIP=0"
[ "$F" -eq 0 ] || exit 1
exit 0
