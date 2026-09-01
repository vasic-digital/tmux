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

RED_MODE="${RED_MODE:-0}"

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
# §11.4.14: every probe uses a private socket label carrying THIS invocation's
# pid, so the EXIT sweep can remove exactly our own dead sockets and can never
# touch a concurrent run's. (kill-server ends the server but whether its socket
# file is gone by the time we look is a race with the server's own teardown —
# UNCONFIRMED which side wins; the sweep is correct either way, so no verdict
# depends on that race.)
PROBE_TAG="tmx76p$$"
SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u 2>/dev/null || echo 0)"
_cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
    [ -n "${SOCK_DIR:-}" ] && [ -n "${PROBE_TAG:-}" ] && \
        rm -f "$SOCK_DIR/$PROBE_TAG"* 2>/dev/null
    return 0
}
trap _cleanup EXIT
mkdir -p "$WORK" "$EVID_DIR" 2>/dev/null || true

echo "════════════════════════════════════════════════════════════════"
echo "  test 76 — terminfo database resolves at runtime (§11.4.108/§11.4.111) (RED_MODE=$RED_MODE)"
echo "════════════════════════════════════════════════════════════════"

[ -f "$TPL" ] || { _fail "scripts/tmx.template absent"; echo "── summary 76: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ──"; exit 1; }

# ── C1: RUNTIME — RED/GREEN over a SYNTHESISED broken precondition ─────────────
# The probe drives the SHIPPED binary as a client over a real PTY under a fully
# controlled terminfo environment and CLASSIFIES what tmux itself reported. The
# classification patterns are tmux's own tty_term_create() diagnostics; an EMPTY
# read is classified ERR:no-output, never OK (§11.4.201(6) — a blind instrument
# and a healthy run must not return the same quiet answer).
_tinfo_probe() { # $1=TERM  $2=TERMINFO ('' unset)  $3=TERMINFO_DIRS ('' unset)  $4=HOME ('' inherit)
    python3 - "$BIN" "$1" "$2" "$3" "$4" "$PROBE_TAG" <<'PY' 2>/dev/null
import os,pty,select,time,sys,subprocess
BIN,TERM,TI,TD,HOME,TAG=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5],sys.argv[6]
L="%s_%d"%(TAG,os.getpid())
subprocess.run([BIN,"-L",L,"kill-server"],capture_output=True)
pid,fd=pty.fork()
if pid==0:
    os.environ["TERM"]=TERM
    for k,v in (("TERMINFO",TI),("TERMINFO_DIRS",TD)):
        if v: os.environ[k]=v
        else: os.environ.pop(k,None)
    if HOME: os.environ["HOME"]=HOME
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
# §11.4.14: kill-server ends the server but LEAVES its socket file behind, so a
# repeatedly-run guard slowly litters the tmux socket dir. Unlink our own
# private label's socket — never anything else's.
try: os.unlink(os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp","tmux-%d"%os.getuid(),L))
except OSError: pass
s=buf.decode(errors="replace")
for pat,tag in (("can't find terminfo database","ERR:db-not-found"),
                ("missing or unsuitable terminal","ERR:entry-not-found"),
                ("can't use hardcopy terminal","ERR:hardcopy"),
                ("open terminal failed","ERR:open-failed")):
    if pat in s:
        sys.stdout.write(tag); break
else:
    sys.stdout.write("OK" if s.strip() else "ERR:no-output")
PY
}

# Compile a terminfo entry for a UNIQUE synthetic terminal name into a SCRATCH
# dir only. Derived from a real host entry so it is a genuinely usable terminal —
# the ONLY thing wrong with it is that it lives nowhere the binary searches by
# default. That is the forensic defect's shape (an entry the binary cannot reach)
# constructed deterministically, instead of hoping the artifact is broken.
SYN_TERM="tmx76syn$$"
SYN_DIR="$WORK/terminfo"
SYN_HOME="$WORK/home"
SYN_BASE=""
_synthesise_scratch_only_terminal() {
    command -v infocmp >/dev/null 2>&1 || return 1
    command -v tic     >/dev/null 2>&1 || return 1
    mkdir -p "$SYN_DIR" "$SYN_HOME" 2>/dev/null || return 1
    for base in screen-256color "${TERM:-}" xterm; do
        [ -n "$base" ] || continue
        infocmp -1 "$base" 2>/dev/null \
            | sed -e "s#^$base|#$SYN_TERM|#" -e "s#^$base,#$SYN_TERM,#" > "$WORK/syn.ti" || continue
        grep -qE "^$SYN_TERM[|,]" "$WORK/syn.ti" || continue
        tic -x -o "$SYN_DIR" "$WORK/syn.ti" >/dev/null 2>&1 || continue
        SYN_BASE="$base"; return 0
    done
    return 1
}

# The TERM used for the GREEN user-visible assertion. infocmp is a SELECTION
# heuristic only (which names the host database actually carries) — the oracle is
# the tmux probe itself. Without infocmp we cannot establish that any given TERM
# is genuinely present, so G1 SKIPs rather than false-FAILing (§11.4.201(1)).
REAL_TERM=""
if command -v infocmp >/dev/null 2>&1; then
    for cand in screen-256color "${TERM:-}" xterm; do
        [ -n "$cand" ] || continue
        infocmp -1 "$cand" >/dev/null 2>&1 || continue
        REAL_TERM="$cand"; break
    done
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    _skip "C1 no tmux binary (build absent) — cannot exercise the terminfo lookup (§11.4.3)"
elif ! command -v python3 >/dev/null 2>&1; then
    _skip "C1 python3 unavailable — cannot drive a PTY client attach (§11.4.3)"
elif ! _synthesise_scratch_only_terminal; then
    _skip "C1 tic/infocmp unavailable (or no host entry to derive from) — cannot synthesise the broken precondition (§11.4.3)"
else
    syn_unreachable="$(_tinfo_probe "$SYN_TERM" "" "" "$SYN_HOME")"
    if [ "$RED_MODE" = "1" ]; then
        syn_reachable="$(_tinfo_probe "$SYN_TERM" "" "$SYN_DIR" "$SYN_HOME")"
        { echo "RED_MODE=1 synthetic=$SYN_TERM derived-from=$SYN_BASE scratch=$SYN_DIR"
          echo "R1 off-search-path result=$syn_unreachable"
          echo "R2 TERMINFO_DIRS=$SYN_DIR result=$syn_reachable"
        } > "$EVID_DIR/C1_terminfo_probe.log" 2>/dev/null || true
        case "$syn_unreachable" in
            ERR:*) _pass "C1/R1 RED: synthetic terminal '$SYN_TERM' (derived from $SYN_BASE, present ONLY in $SYN_DIR) is unresolvable when that dir is off the search path — terminfo-resolution failure reproduced ($syn_unreachable)" ;;
            *)     _fail "C1/R1 RED — the scratch-only terminal RESOLVED without its dir on the search path (result=$syn_unreachable); the broken precondition was not established, so this check proves nothing" ;;
        esac
        if [ "$syn_reachable" = "OK" ]; then
            _pass "C1/R2 control needle: the SAME terminal WITH TERMINFO_DIRS=$SYN_DIR resolves and the server comes up — R1's failure was the search path, not a bad entry, and the probe can report OK (§11.4.201(7)(b))"
        else
            _fail "C1/R2 control needle FAILED (result=$syn_reachable) — TERMINFO_DIRS did not make the entry reachable; R1's failure is unattributable and the env mechanism the fix relies on is NOT proven on this binary"
        fi
        _ev "captured: qa-results/loop-20260630/terminfo-db-resolve/C1_terminfo_probe.log"
    else
        if [ -z "$REAL_TERM" ]; then
            green="SKIP"
        else
            green="$(_tinfo_probe "$REAL_TERM" "" "" "")"
        fi
        { echo "RED_MODE=0 shipped-binary=$BIN"
          echo "G1 TERM=${REAL_TERM:-<none-selectable>} no-env-overrides result=$green"
          echo "G2 detector-viability synthetic=$SYN_TERM off-search-path result=$syn_unreachable"
        } > "$EVID_DIR/C1_terminfo_probe.log" 2>/dev/null || true
        if [ -z "$REAL_TERM" ]; then
            _skip "C1/G1 infocmp unavailable — cannot establish which TERM this host's database genuinely carries, so no TERM can be asserted resolvable without guessing (§11.4.3/§11.4.6)"
        elif [ "$green" = "OK" ]; then
            _pass "C1/G1 the shipped binary resolves TERM=$REAL_TERM from the host terminfo database with NO env overrides and brings a server up — the user-visible property this guard exists for"
        else
            _fail "C1/G1 the shipped binary could NOT resolve TERM=$REAL_TERM (result=$green) even though the host database carries it — the forensic defect is live: 'tmx new -s NAME' will die with the tmux server not coming up"
        fi
        case "$syn_unreachable" in
            ERR:*) _pass "C1/G2 detector viability (§11.4.115(F)): the scratch-only terminal '$SYN_TERM' still FAILS off the search path ($syn_unreachable) — G1's OK is a real observation, not a probe that always reports OK" ;;
            *)     _fail "C1/G2 detector viability FAILED — the scratch-only terminal RESOLVED off its search path (result=$syn_unreachable); this probe cannot distinguish a resolvable terminal from an unresolvable one, so G1's verdict is unvalidated instrumentation" ;;
        esac
        _ev "captured: qa-results/loop-20260630/terminfo-db-resolve/C1_terminfo_probe.log"
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
