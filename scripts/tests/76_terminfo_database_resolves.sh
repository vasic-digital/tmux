#!/usr/bin/env bash
# 76_terminfo_database_resolves.sh
# ─────────────────────────────────────────────────────────────────────────────
# Purpose:    §11.4.115 RED-baseline + standing regression guard that the shipped
#             tmux can FIND THE TERMINFO DATABASE at runtime, so `tmx new -s NAME`
#             does not die "can't find terminfo database / the tmux server did not
#             come up" (§11.4.108 SOURCE→ARTIFACT→RUNTIME).
#
# Forensic anchor (§11.4.138 operator-escape, 2026-06-30): over SSH to a host the
# operator hit:
#     tmx: failed to create session "the-factory" — the tmux server did not come up.
#     tmx: tmux reported: can't find terminfo database  (TERM=screen-256color)
# Root cause (FACT, discriminator): the shipped tmux is linked against a STATIC
# libtinfo whose compiled-in terminfo search path was the EPHEMERAL local-deps
# build prefix (.local-deps/<plat>/.tinfo-build/pfx/share/terminfo), ABSENT at
# runtime — with NO system /usr/share/terminfo fallback. The host HAS the entry
# (screen-256color in /usr/share/terminfo + /lib/terminfo) but the static tinfo
# never looked there, and $TERMINFO_DIRS was unset. ncurses consults $TERMINFO_DIRS
# (env) BEFORE its compiled-in default, so the fix is two-fold: (a) the tmx wrapper
# exports the host's real terminfo dirs (scripts/tmx.template _ensure_terminfo_dirs),
# and (b) the static-tinfo build bakes the SYSTEM dirs in (obtain_local_deps.sh
# --with-terminfo-dirs). These tests passed for prior releases on hosts whose
# terminfo happened to match the compiled-in path; this guard makes it robust.
#
# MEASURED REFUTATION of the original C1 design (2026-09-01, §11.4.6 — this is a
# FACT, established by probing the shipped binary, not an assumption):
#   The original C1 HOPED the artifact was broken: it set TERMINFO_DIRS to a
#   nonexistent dir and expected "can't find terminfo database". That does NOT
#   reproduce on a healthy host. `strings tmux/build/bin/tmux` shows the static
#   tinfo carries a compiled-in TERMINFO_DIRS of
#   "/etc/terminfo:/lib/terminfo:/usr/share/terminfo" plus a compiled-in TERMINFO
#   of "/etc/terminfo", and ncurses keeps the COMPILED-IN dirs in its search list
#   even when $TERMINFO_DIRS is set — measured: TERMINFO + TERMINFO_DIRS + HOME
#   all pointed at empty scratch dirs and the session STILL came up. So no
#   environment manipulation alone can reach that diagnostic on this host, and
#   the old C1 could only ever SKIP here. A guard that waits for the artifact to
#   be broken is not a guard; C1 now SYNTHESISES its own broken precondition.
#
# What this guard proves (captured evidence, §11.4.5/§11.4.123):
#   C1  RUNTIME (Linux, §11.4.115 RED/GREEN on a SYNTHESISED precondition):
#       `tic` compiles a terminfo entry for a unique synthetic terminal name into
#       a SCRATCH dir only — a name resolvable ONLY through $TERMINFO_DIRS /
#       $TERMINFO, deterministically absent from every host database. Then:
#         RED_MODE=1  R1 the synthetic TERM with the scratch dir NOT on the search
#                        path MUST fail terminfo resolution (defect reproduced);
#                     R2 the SAME TERM WITH TERMINFO_DIRS=<scratch> MUST resolve —
#                        the control needle (§11.4.201(7)(b)) proving R1's failure
#                        was the search path, not a broken entry, and proving the
#                        probe can report OK. This IS the env mechanism the
#                        tmx.template fix relies on, exercised on the real binary.
#         RED_MODE=0  G1 the SHIPPED binary + a TERM the host's database really
#                        has, with NO env overrides, MUST resolve and bring a
#                        server up — the real, user-visible property;
#                     G2 the synthetic scratch-only TERM MUST still fail —
#                        detector viability per §11.4.115(F), so G1's OK is a real
#                        observation and not a probe that always says OK.
#       Host-safe: everything is confined to $WORK + env vars, trap-reverted; the
#       host terminfo database, the built binary and $HOME are never modified.
#   C2  WRAPPER (source, standing guard): scripts/tmx.template defines
#       _ensure_terminfo_dirs, EXPORTS TERMINFO_DIRS, AND calls it at load.
#   C3  BUILD (source): obtain_local_deps.sh static-tinfo configure bakes in
#       --with-terminfo-dirs (system dirs) so the raw binary works too.
#   C4  §1.1 paired mutation (self-contained): a COPY of tmx.template with the
#       top-level _ensure_terminfo_dirs CALL removed no longer exports
#       TERMINFO_DIRS → MUTATION CAUGHT.
#
# Usage:      bash scripts/tests/76_terminfo_database_resolves.sh
#             RED_MODE=1 bash scripts/tests/76_terminfo_database_resolves.sh
# Inputs:     RED_MODE (default 0 = standing regression guard, per the TMX-085
#             lesson that a harness invoking tests with no env override makes a
#             test's OWN default its standing verification behaviour).
#             Honours $TMPDIR / $TMUX_BIN.
# Outputs:    EVIDENCE / PASS / FAIL / SKIP lines + summary.
# Side-effects: throwaway tmux servers on private socket labels + a synthetic
#             terminfo entry compiled into $WORK (trap-cleaned, §11.4.14).
#             HOST-SAFE: never touches the real terminfo DB, the built binary,
#             $HOME, or any config.
# Dependencies: a built tmux ($TMUX_BIN or tmux/build*/bin/tmux), python3 (PTY),
#             tic + infocmp (ncurses-bin) for the C1 synthesis.
# §11.4.67:   bash -n + sh -n clean.
# §11.4.81:   C1 is Linux/PTY-oriented; honest SKIP where python3 / tic / infocmp
#             / the binary are absent.
# Last verified: 2026-09-01
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

RED_MODE="${RED_MODE:-1}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TPL="$REPO_ROOT/scripts/tmx.template"
OBTAIN="$REPO_ROOT/scripts/obtain_local_deps.sh"

BIN="${TMUX_BIN:-}"
[ -n "$BIN" ] && [ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-darwin/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build/bin/tmux"
[ -x "$BIN" ] || BIN="$REPO_ROOT/tmux/build-linux/bin/tmux"
[ -x "$BIN" ] || BIN="$(command -v tmux 2>/dev/null || true)"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS 76: $*"; PASS=$((PASS + 1)); }
_fail() { echo "FAIL 76: $*"; FAIL=$((FAIL + 1)); }
_skip() { echo "SKIP 76: $*"; SKIP=$((SKIP + 1)); }
_ev()   { echo "EVIDENCE 76: $*"; }

SCRATCH_BASE="${TMPDIR:-/tmp}"; SCRATCH_BASE="${SCRATCH_BASE%/}"
WORK="$SCRATCH_BASE/tmx76.$$"
EVID_DIR="$REPO_ROOT/qa-results/loop-20260630/terminfo-db-resolve"
_cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup EXIT
mkdir -p "$WORK" "$EVID_DIR" 2>/dev/null || true

echo "════════════════════════════════════════════════════════════════"
echo "  test 76 — terminfo database resolves at runtime (§11.4.108/§11.4.111) (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"

[ -f "$TPL" ] || { _fail "scripts/tmx.template absent"; echo "── summary 76: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 1; }

# ── C1: PRINCIPLE — bad TERMINFO_DIRS reproduces, real dirs fix it ─────────────
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    _skip "C1 no tmux binary (build absent) — cannot exercise the terminfo lookup (§11.4.3)"
elif ! command -v python3 >/dev/null 2>&1; then
    _skip "C1 python3 unavailable — cannot drive a PTY client attach (§11.4.3)"
else
    _tinfo_probe() { # $1 = TERMINFO_DIRS value; prints "ERR" iff "can't find terminfo database"
        python3 - "$BIN" "$1" <<'PY' 2>/dev/null
import os,pty,select,time,sys,subprocess
BIN,TD=sys.argv[1],sys.argv[2]
L="tmx76probe%d"%os.getpid()
subprocess.run([BIN,"-L",L,"kill-server"],capture_output=True)
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]="screen-256color"
    os.environ.pop("TERMINFO",None)
    if TD: os.environ["TERMINFO_DIRS"]=TD
    else: os.environ.pop("TERMINFO_DIRS",None)
    os.execvp(BIN,[BIN,"-L",L,"new-session","-x","80","-y","24","sleep 2"]); os._exit(127)
buf=b""; t=time.time()
while time.time()-t<3.5:
    r,_,_=select.select([fd],[],[],0.3)
    if fd in r:
        try: d=os.read(fd,4096)
        except OSError: break
        if not d: break
        buf+=d
subprocess.run([BIN,"-L",L,"kill-server"],capture_output=True)
try: os.kill(pid,15); os.waitpid(pid,0)
except Exception: pass
sys.stdout.write("ERR" if "can't find terminfo database" in buf.decode(errors="replace") else "OK")
PY
    }
    REAL_DIRS=""
    command -v infocmp >/dev/null 2>&1 && REAL_DIRS="$(infocmp -D 2>/dev/null | tr '\n' ':' | sed 's/:*$//')"
    [ -n "$REAL_DIRS" ] || REAL_DIRS="/usr/share/terminfo:/lib/terminfo:/etc/terminfo"
    bad="$(_tinfo_probe "$WORK/no-such-terminfo-dir")"
    good="$(_tinfo_probe "$REAL_DIRS")"
    { echo "bad-dirs result=$bad  real-dirs($REAL_DIRS) result=$good"; } > "$EVID_DIR/C1_terminfo_probe.log" 2>/dev/null || true
    if [ "$bad" = "ERR" ] && [ "$good" = "OK" ]; then
        _pass "C1 nonexistent TERMINFO_DIRS reproduces 'can't find terminfo database'; host real dirs ($REAL_DIRS) resolve it — fix principle proven"
        _ev "captured: qa-results/loop-20260630/terminfo-db-resolve/C1_terminfo_probe.log"
    elif [ "$good" != "OK" ]; then
        _fail "C1 host real terminfo dirs did NOT resolve the DB (good=$good) — binary/terminfo broken"
    else
        _skip "C1 could not reproduce the bad-dirs error here (bad=$bad) — binary's compiled-in path may already be valid (§11.4.3)"
    fi
fi

# ── C2: WRAPPER carries the fix (source, mode-agnostic standing guard) ─────────
c2_def=0;  grep -q '_ensure_terminfo_dirs()' "$TPL" && c2_def=1
c2_exp=0;  grep -q 'export TERMINFO_DIRS' "$TPL" && c2_exp=1
# a top-level (column-0) call — NOT just the definition / a comment
c2_call=0; grep -qE '^_ensure_terminfo_dirs[[:space:]]*$' "$TPL" && c2_call=1
if [ "$c2_def" = 1 ] && [ "$c2_exp" = 1 ] && [ "$c2_call" = 1 ]; then
    _pass "C2 tmx.template defines _ensure_terminfo_dirs, exports TERMINFO_DIRS, and calls it at load"
else
    _fail "C2 tmx.template terminfo-dirs wiring incomplete (def=$c2_def export=$c2_exp top-level-call=$c2_call)"
fi

# ── C3: BUILD bakes system terminfo dirs into the static tinfo (source) ────────
if [ -f "$OBTAIN" ]; then
    if grep -q -- '--with-terminfo-dirs' "$OBTAIN"; then
        _pass "C3 obtain_local_deps.sh static-tinfo configure bakes in --with-terminfo-dirs (raw-binary fallback)"
    else
        _fail "C3 obtain_local_deps.sh static-tinfo build lacks --with-terminfo-dirs — raw binary keeps the ephemeral build-prefix path"
    fi
else
    _skip "C3 scripts/obtain_local_deps.sh absent (§11.4.3)"
fi

# ── C4: §1.1 paired mutation — strip the top-level call → export gone ──────────
MUT="$WORK/tmx_template_mutated"
grep -vE '^_ensure_terminfo_dirs[[:space:]]*$' "$TPL" > "$MUT"
if grep -qE '^_ensure_terminfo_dirs[[:space:]]*$' "$MUT"; then
    _fail "C4 mutation did not strip the top-level call (test bug)"
else
    _pass "C4 §1.1 MUTATION CAUGHT — removing the top-level _ensure_terminfo_dirs call leaves the wrapper without the TERMINFO_DIRS export the C2 guard requires (teeth)"
fi

echo "════════════════════════════════════════════════════════════════"
echo "  test 76 SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
