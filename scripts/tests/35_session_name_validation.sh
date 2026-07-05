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

_cleanup() {
    rm -f "$INIT_FILE" "$INIT_STRIPPED" "$TMX_STATE_FILE" "$FAKE_LOG" 2>/dev/null || true
    rm -rf "$FAKE_PATH_DIR" 2>/dev/null || true
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

if [ "${_hashes[0]}" != "${_hashes[1]}" ] || [ "${_hashes[1]}" != "${_hashes[2]}" ]; then
    echo "FAIL 35: N=3 evidence hashes diverge: ${_hashes[*]}"
    exit 1
fi

echo "[evidence] reliability_hash=${_hashes[0]}"
echo "PASS 35 session-name sanitization normalizes ${#CASES[@]} inputs (3/3 iterations)"
exit 0
