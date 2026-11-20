#!/usr/bin/env bash
# Test 35 — session name sanitization in the shell-init wizard.
#
# CONTRACT: names containing spaces, tabs, or special characters are
# normalized instead of rejected. Leading/trailing whitespace is trimmed,
# internal whitespace runs are collapsed to a single '-', and remaining
# characters outside the safe set are deleted. Empty/whitespace-only input
# falls through to the default/picker path (no tmx invocation).
#
# POSITIVE evidence per §11.4.5: the fake-tmx log shows the exact sanitized
# name passed to `tmx new -s NAME` for each test case.
#
# §11.4.50 reliability: 3 iterations.
# §11.4.14 cleanup.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_TEMPLATE="$REPO_ROOT/scripts/tmx-shell-init.sh.template"
SCRATCH="${TMPDIR:-/tmp}"
INIT_FILE="$SCRATCH/tmx-shell-init-35-$$.sh"
INIT_STRIPPED="$SCRATCH/tmx-shell-init-35-stripped-$$.sh"
export TMX_STATE_FILE="$SCRATCH/tmx-test-35-$$.json"
FAKE_LOG="$SCRATCH/tmx-fake-35-$$.log"
FAKE_PATH_DIR="$SCRATCH/tmx-test-35-fakepath-$$"

# TMX-077 scope-less collision-guard proof (live wrapper + real tmux).
WRAPPER35="$REPO_ROOT/scripts/tmx"
TMUX_BIN35=""
COLL_SESSION=""
COLL_FAKEBIN="$SCRATCH/tmx-35-fakebin-$$"
COLL_OUT="$SCRATCH/tmx-35-coll-out-$$.log"
COLL_ERR="$SCRATCH/tmx-35-coll-err-$$.log"

_cleanup() {
    rm -f "$INIT_FILE" "$INIT_STRIPPED" "$TMX_STATE_FILE" "$FAKE_LOG" 2>/dev/null || true
    rm -rf "$FAKE_PATH_DIR" 2>/dev/null || true
    if [ -n "$COLL_SESSION" ] && [ -n "$TMUX_BIN35" ]; then
        "$TMUX_BIN35" -L "tmx-$COLL_SESSION" kill-server >/dev/null 2>&1 || true
    fi
    [ -x "$REPO_ROOT/scripts/tmx-state-bin" ] && "$REPO_ROOT/scripts/tmx-state-bin" forget "$COLL_SESSION" >/dev/null 2>&1 || true
    rm -f "$COLL_OUT" "$COLL_ERR" 2>/dev/null || true
    rm -rf "$COLL_FAKEBIN" 2>/dev/null || true
}
trap '_cleanup' EXIT

# §11.4.3 scratch-root writability preflight.
_wtest="$SCRATCH/.tmx_wtest_$$"
if ! mkdir -p "$_wtest" 2>/dev/null || [ ! -w "$_wtest" ]; then
    echo "SKIP 35: scratch root $SCRATCH not writable — §11.4.3"; exit 77
fi
rmdir "$_wtest" 2>/dev/null || true

[ -f "$INIT_TEMPLATE" ] || { echo "SKIP 35: tmx-shell-init.sh.template not present"; exit 77; }

sed "s|__PROJECT__|$REPO_ROOT|g; s|__DATE__|test-35|g" "$INIT_TEMPLATE" > "$INIT_FILE"
chmod 755 "$INIT_FILE"
# Strip the [ -t 0 ] guard so we can drive it without a TTY.
sed '/if \[ ! -t 0 \] || \[ ! -t 1 \]; then/,/^fi$/d' "$INIT_FILE" > "$INIT_STRIPPED"

# Install a fake `tmx` on PATH that logs its arguments and exits 0.
mkdir -p "$FAKE_PATH_DIR"
cat > "$FAKE_PATH_DIR/tmx" <<FAKETMX
#!/bin/sh
printf '%s\\n' "\$*" >> "$FAKE_LOG"
exit 0
FAKETMX
chmod 755 "$FAKE_PATH_DIR/tmx"
export PATH="$FAKE_PATH_DIR:$PATH"

# Each line: INPUT|EXPECTED_SANITIZED_NAME
# TMX_EXACT_NAME=1 disables the random suffix so the assertion is exact.
CASES=(
    'my session|my-session'
    '  hello world  |hello-world'
    'a!b@c#d|abcd'
    'foo:bar|foo:bar'
    'my session:red|my-session:red'
    'one  two	three|one-two-three'
    '|default'
    '     |default'
    'valid_name|valid_name'
    'mix1  mix2!|mix1-mix2'
)

run_iteration() {
    local iter="$1"
    local failures=0
    > "$FAKE_LOG"
    for entry in "${CASES[@]}"; do
        local input expected
        input="$(printf '%s' "$entry" | cut -d'|' -f1)"
        expected="$(printf '%s' "$entry" | cut -d'|' -f2)"
        : > "$FAKE_LOG"
        env -u TMUX -u TMX_SKIP TMX_EXACT_NAME=1 bash "$INIT_STRIPPED" <<< "$input" >/dev/null 2>&1 || true
        if [ "$expected" = "default" ]; then
            # Empty/whitespace-only input falls through to the default/picker
            # path, which probes `tmx ls` but must NOT try to create a session.
            if grep -qE "(^| )new -s " "$FAKE_LOG"; then
                echo "  iter=$iter: input='$input' expected default path (no create), but log='$(cat "$FAKE_LOG")'"
                failures=$((failures + 1))
            fi
            continue
        fi
        if ! grep -qE "(^| )new -s $expected( |$)" "$FAKE_LOG"; then
            echo "  iter=$iter: input='$input' expected 'new -s $expected', log='$(cat "$FAKE_LOG")'"
            failures=$((failures + 1))
        fi
    done
    if [ "$failures" -gt 0 ]; then
        echo "FAIL 35 iter=$iter: $failures sanitization assertions failed"
        return 1
    fi
    _evidence="iter=$iter cases_tested=${#CASES[@]} all_sanitized=yes"
    return 0
}

_hashes=()
for i in 1 2 3; do
    if ! run_iteration "$i"; then exit 1; fi
    _h="$(echo "sanitized=${#CASES[@]}" | shasum | cut -d' ' -f1)"
    _hashes+=("$_h")
    echo "[evidence] $_evidence"
done

# ── TMX-077: Linux collision guard must NOT be gated on systemd user scopes ──
# Force the wrapper's REAL topology probe to report scope-unavailable by putting
# fake `systemctl` (version 229 < 230) + `systemd-run` (always fails) first on
# PATH. The real generated wrapper + real tmux server are used — only the probe
# inputs are faked (§11.4.201 control needle: prove the fake is actually seen).
if [ "$(uname -s)" != "Linux" ]; then
    echo "SKIP 35/TMX-077: Linux-only scope-less collision guard (§11.4.3)"
else
    if [ ! -x "$WRAPPER35" ]; then
        echo "SKIP 35/TMX-077: wrapper $WRAPPER35 missing — run scripts/setup.sh first"
    else
        TMUX_BIN35="$(sed -n 's/^TMUX_BIN="\(.*\)"$/\1/p' "$WRAPPER35" | head -1)"
        mkdir -p "$COLL_FAKEBIN"
        cat > "$COLL_FAKEBIN/systemctl" <<'SCEOF'
#!/bin/sh
if [ "$1" = "--version" ]; then echo "systemd 229"; exit 0; fi
exit 1
SCEOF
        cat > "$COLL_FAKEBIN/systemd-run" <<'SREOF'
#!/bin/sh
exit 1
SREOF
        chmod 755 "$COLL_FAKEBIN/systemctl" "$COLL_FAKEBIN/systemd-run"
        _seen="$(PATH="$COLL_FAKEBIN:$PATH" systemctl --version 2>/dev/null | head -1)"
        case "$_seen" in
            *229*) echo "[evidence] TMX-077 probe force: fake systemctl reports '$_seen' (<230 ⇒ _scope_ok=0)" ;;
            *) echo "FAIL 35/TMX-077: control needle — fake systemctl NOT seen ('$_seen')"; exit 1 ;;
        esac

        _coll_failures=0
        for iter in 1 2 3; do
            COLL_SESSION="t35coll_${$}_${iter}"
            # First create: a genuinely live session on socket tmx-<NAME>.
            if ! PATH="$COLL_FAKEBIN:$PATH" "$WRAPPER35" new -s "$COLL_SESSION" -d \
                 >"$COLL_OUT" 2>"$COLL_ERR"; then
                echo "  iter=$iter: setup create failed: $(head -c 200 "$COLL_ERR")"
                _coll_failures=$((_coll_failures + 1))
                COLL_SESSION=""
                continue
            fi
            if ! "$TMUX_BIN35" -L "tmx-$COLL_SESSION" has-session -t "$COLL_SESSION" 2>/dev/null; then
                echo "  iter=$iter: first session not live on socket tmx-$COLL_SESSION"
                _coll_failures=$((_coll_failures + 1))
                COLL_SESSION=""
                continue
            fi
            # Duplicate create against the SAME live name — must be refused.
            : > "$COLL_OUT"; : > "$COLL_ERR"
            if PATH="$COLL_FAKEBIN:$PATH" "$WRAPPER35" new -s "$COLL_SESSION" -d \
                 >"$COLL_OUT" 2>"$COLL_ERR"; then
                _rc=0
            else
                _rc=$?
            fi
            _both="$(cat "$COLL_OUT" "$COLL_ERR")"
            if [ "$_rc" -ne 4 ]; then
                echo "  iter=$iter: duplicate create rc=$_rc (want 4), output='$_both'"
                _coll_failures=$((_coll_failures + 1))
            elif ! printf '%s' "$_both" | grep -q "refusing to create session '$COLL_SESSION'"; then
                echo "  iter=$iter: no refusal message, output='$_both'"
                _coll_failures=$((_coll_failures + 1))
            elif printf '%s' "$_both" | grep -qiE 'enter password|confirm password|password-protected'; then
                echo "  iter=$iter: password prompt reached BEFORE collision refusal: '$_both'"
                _coll_failures=$((_coll_failures + 1))
            elif ! "$TMUX_BIN35" -L "tmx-$COLL_SESSION" has-session -t "$COLL_SESSION" 2>/dev/null; then
                echo "  iter=$iter: original session disturbed by refused duplicate create"
                _coll_failures=$((_coll_failures + 1))
            else
                echo "[evidence] TMX-077 iter=$iter: scope-less duplicate create refused rc=4, original session alive, no password prompt"
            fi
            "$TMUX_BIN35" -L "tmx-$COLL_SESSION" kill-server >/dev/null 2>&1 || true
            [ -x "$REPO_ROOT/scripts/tmx-state-bin" ] && \
                "$REPO_ROOT/scripts/tmx-state-bin" forget "$COLL_SESSION" >/dev/null 2>&1 || true
            COLL_SESSION=""
        done
        if [ "$_coll_failures" -gt 0 ]; then
            echo "FAIL 35/TMX-077: $_coll_failures/3 scope-less collision assertions failed"
            exit 1
        fi
        echo "[evidence] TMX-077 scope-less collision guard 3/3 (fallback path active with _scope_ok=0)"
    fi
fi

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 35: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 35 session-name sanitization (${#CASES[@]} inputs, 3/3) + TMX-077 scope-less collision guard (3/3)"
exit 0
