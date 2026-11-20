#!/usr/bin/env bash
# Test 69 — curl installer (scripts/install.sh) anti-bluff validation.
#
# §11.4.18 companion: docs/scripts/install.md.
# §11.4.2/§11.4.5: every PASS reads REAL captured behaviour — a real
#   recursive git clone (offline, from a local file:// mirror of THIS repo),
#   a real submodule checkout, the installer's own runtime output — never an
#   exit code alone.
# §11.4.123: validates the installer without a network round-trip and WITHOUT
#   mutating the real host (no setup.sh, no ~/.bashrc write, no tmux server).
#   The TMX_INSTALL_NO_SETUP=1 seam stops the installer after clone+submodules
#   so the heavy build + the host-config writes never run during the test.
# §11.4.50: rc-detection is deterministic (asserted by repeating it 3×).
# §11.4.14: trap-cleanup removes every throwaway directory on EXIT.
#
# What is intentionally NOT covered here (honest gaps, §11.4.6):
#   - The full setup.sh build/verify/install + real PATH wiring (mutates the
#     host) — that is the domain of test 42 (setup install/uninstall E2E) and a
#     real operator install. This test proves the CLONE + NAMING + RC-DETECT +
#     §9.2-refuse + IDEMPOTENCY layers of the installer only.
#   - A real network clone from github (the installer's default) — proven by
#     the offline file:// mirror path instead (same git machinery).
set -uo pipefail

# §11.4.3 / TMPDIR-HARDCODE: route all scratch through ${TMPDIR:-/tmp}.
SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install.sh"

echo "── Test 69: curl installer (scripts/install.sh) ──"
PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }
_summary() { echo "── Test 69 result: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; }

WORK="$SCRATCH/tmx_install_test_$$"
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"
    exit 0
fi
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

if [ ! -f "$INSTALL" ]; then
    _fail "scripts/install.sh missing"
    _summary; [ "$FAIL" -eq 0 ]; exit
fi

# ── A. parse / lint ──────────────────────────────────────────────────────────
if bash -n "$INSTALL" 2>"$WORK/bn.err"; then
    _pass "A1 bash -n scripts/install.sh clean"
else
    _fail "A1 bash -n: $(cat "$WORK/bn.err" 2>/dev/null | head -3)"
fi
# install.sh is intentionally bash (uses arrays for the -c git config flags);
# `sh -n` is therefore N/A for it (a bash-only script, not POSIX). The test
# harness runs every test via `bash "$t"`, so bash-parseability is the gate.
echo "note: install.sh is a bash script (arrays) — sh -n N/A by design (§11.4.67 honest)"

# ── B. PATH-detection unit (fake HOME, NO clone, NO host mutation) ───────────
# Proves detection keys off which rc FILE EXISTS, not merely $SHELL: B1 sets
# SHELL=bash but only .zshrc exists → must report .zshrc; B2 sets SHELL=zsh but
# only .bashrc exists → must report .bashrc.
FZ="$WORK/home_zsh"; mkdir -p "$FZ"; : > "$FZ/.zshrc"
out=$(HOME="$FZ" SHELL=/bin/bash TMX_INSTALL_DETECT_RC_ONLY=1 \
      env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
if printf '%s\n' "$out" | grep -q "shell rc detected: $FZ/.zshrc"; then
    _pass "B1 only-.zshrc present (SHELL=bash) → detected $FZ/.zshrc"
else
    _fail "B1 rc-detect zsh: $out"
fi

FB="$WORK/home_bash"; mkdir -p "$FB"; : > "$FB/.bashrc"
out=$(HOME="$FB" SHELL=/bin/zsh TMX_INSTALL_DETECT_RC_ONLY=1 \
      env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
if printf '%s\n' "$out" | grep -q "shell rc detected: $FB/.bashrc"; then
    _pass "B2 only-.bashrc present (SHELL=zsh) → detected $FB/.bashrc"
else
    _fail "B2 rc-detect bash: $out"
fi

# B3 determinism (§11.4.50): repeat B1 three times, assert identical output.
d1=$(HOME="$FZ" SHELL=/bin/bash TMX_INSTALL_DETECT_RC_ONLY=1 env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
d2=$(HOME="$FZ" SHELL=/bin/bash TMX_INSTALL_DETECT_RC_ONLY=1 env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
d3=$(HOME="$FZ" SHELL=/bin/bash TMX_INSTALL_DETECT_RC_ONLY=1 env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
if [ "$d1" = "$d2" ] && [ "$d2" = "$d3" ]; then
    _pass "B3 rc-detection deterministic across 3 runs (§11.4.50)"
else
    _fail "B3 non-deterministic rc-detection"
fi

# ── C. naming-convention default = \$HOME/tmux (§11.4.29), runtime evidence ──
FN="$WORK/home_naming"; mkdir -p "$FN"; : > "$FN/.bashrc"
out=$(HOME="$FN" TMX_INSTALL_DETECT_RC_ONLY=1 env -u TMX_INSTALL_DIR bash "$INSTALL" 2>&1 || true)
if printf '%s\n' "$out" | grep -q "install root (default): $FN/tmux"; then
    _pass "C default install root = \$HOME/tmux (lowercase snake_case, §11.4.29)"
else
    _fail "C naming default: $out"
fi

# ── D. §9.2 — refuse to clobber a non-empty foreign directory ────────────────
JUNK="$WORK/foreign_dir"; mkdir -p "$JUNK"; echo "not our repo" > "$JUNK/random.txt"
out=$(TMX_INSTALL_DIR="$JUNK" TMX_INSTALL_NO_SETUP=1 bash "$INSTALL" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "Refusing to clobber"; then
    _pass "D §9.2 refuses non-empty foreign dir (exit $rc, did not clobber)"
    [ -f "$JUNK/random.txt" ] && _pass "D2 foreign file left intact (not clobbered)" || _fail "D2 foreign file removed!"
else
    _fail "D §9.2 refuse: rc=$rc out=$out"
fi

# ── E. offline recursive clone + submodules (real git machinery, no network) ─
if ! command -v git >/dev/null 2>&1; then
    _skip "E clone: git not on PATH — cannot build local source mirror (§11.4.3)"
elif [ ! -e "$REPO_ROOT/.git" ]; then
    _skip "E clone: REPO_ROOT is not a git checkout — no local source (§11.4.3)"
else
    SRC="$WORK/src_mirror"
    DST="$WORK/install_dst"
    # Build an offline source mirror of THIS repo whose .gitmodules point at the
    # live local submodule worktrees, so the recursive clone needs no network.
    if git clone --quiet "$REPO_ROOT" "$SRC" 2>"$WORK/clone.err"; then
        (
          cd "$SRC"
          git config -f .gitmodules --get-regexp '\.path$' | while read -r k p; do
              n="${k#submodule.}"; n="${n%.path}"
              git config -f .gitmodules "submodule.$n.url" "file://$REPO_ROOT/$p"
          done
          git -c user.email=t@t -c user.name=t commit -q -am "test69: local submodule urls" >/dev/null 2>&1 || true
        )
        # §11.4.98 FULL AUTOMATION — the nested submodule URLs inside
        # constitution/ still point at GitHub. Rewriting only the TOP-LEVEL
        # .gitmodules (above) is no longer sufficient: install.sh's recursive
        # update then tries the network for 27+ nested repos (one private) and
        # hangs indefinitely. Inject url.*.insteadOf rewrites via GIT_CONFIG_*
        # env so EVERY git subprocess in the installer resolves nested
        # submodules to the local checkouts — truly offline, no credentials.
        local_map="$(python3 - "$REPO_ROOT" <<'PY'
import subprocess, sys, pathlib
root = pathlib.Path(sys.argv[1])
for gm in root.rglob('.gitmodules'):
    if 'tmux' in gm.parts:
        continue
    try:
        txt = subprocess.run(['git', 'config', '-f', str(gm), '--get-regexp',
                              r'^submodule\..*\.(path|url)$'],
                             capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError:
        continue
    opts = {}
    for line in txt.splitlines():
        key, val = line.split(None, 1)
        opts.setdefault(key.rsplit('.', 1)[0], {})[key.rsplit('.', 1)[1]] = val
    base = gm.parent
    for name, pair in opts.items():
        url, path = pair.get('url'), pair.get('path')
        if not url or not path:
            continue
        local = base / path
        if local.exists():
            print(f'{url}\t{local}')
PY
        )"
        cfg_n=0
        while IFS=$'\t' read -r sm_url local_path; do
            [ -n "${sm_url:-}" ] && [ -d "${local_path:-}" ] || continue
            export "GIT_CONFIG_KEY_${cfg_n}=url.file://${local_path}.insteadOf"
            export "GIT_CONFIG_VALUE_${cfg_n}=${sm_url}"
            cfg_n=$((cfg_n + 1))
        done <<< "$local_map"
        export GIT_CONFIG_COUNT="$cfg_n"
        echo "[offline] nested submodule URL rewrites: $cfg_n"
        out=$(TMX_REPO_URL="$SRC" TMX_INSTALL_DIR="$DST" TMX_INSTALL_NO_SETUP=1 \
              bash "$INSTALL" 2>&1); rc=$?
        unset GIT_CONFIG_COUNT
        for ((i=0; i<cfg_n; i++)); do
            unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
        done
        ok=1
        [ "$rc" -eq 0 ]                              || { ok=0; reason="exit=$rc"; }
        [ -d "$DST/.git" ]                           || { ok=0; reason="${reason:-} no-.git"; }
        [ -f "$DST/constitution/Constitution.md" ]   || { ok=0; reason="${reason:-} no-constitution"; }
        [ -f "$DST/scripts/setup.sh" ]               || { ok=0; reason="${reason:-} no-setup.sh"; }
        [ -f "$DST/scripts/tmx.template" ]           || { ok=0; reason="${reason:-} no-tmx.template"; }
        printf '%s\n' "$out" | grep -q "stopping before build" || { ok=0; reason="${reason:-} no-stop-msg"; }
        if [ "$ok" = 1 ]; then
            _pass "E offline recursive clone: $DST has .git + constitution/Constitution.md + setup.sh + tmx.template (exit $rc)"
        else
            _fail "E offline clone failed: ${reason:-?} | out: $(printf '%s' "$out" | tail -5)"
        fi

        # ── F. idempotent re-run → update mode (pull), not re-clone ──────────
        out2=$(TMX_REPO_URL="$SRC" TMX_INSTALL_DIR="$DST" TMX_INSTALL_NO_SETUP=1 \
               bash "$INSTALL" 2>&1); rc2=$?
        if [ "$rc2" -eq 0 ] \
           && printf '%s\n' "$out2" | grep -q "already our repo" \
           && [ -f "$DST/constitution/Constitution.md" ]; then
            _pass "F idempotent re-run → update mode, constitution/ intact (exit $rc2)"
        else
            _fail "F idempotent re-run: rc=$rc2 | out: $(printf '%s' "$out2" | tail -5)"
        fi
    else
        _skip "E clone: could not build local source mirror: $(head -2 "$WORK/clone.err" 2>/dev/null) (§11.4.3)"
    fi
fi

_summary
[ "$FAIL" -eq 0 ]
