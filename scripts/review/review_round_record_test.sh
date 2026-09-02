#!/usr/bin/env bash
# =============================================================================
# review_round_record_test.sh — RED-first test for the review-round recorder
# =============================================================================
#
# WHAT IS UNDER TEST
#   scripts/review/review_round_record.sh — the durable, append-only,
#   machine-readable record of ONE code-review round.
#
# WHY IT EXISTS (captured forensic fact, 2026-09-01)
#   A code-review loop ran four rounds plus two deltas and wrote NO per-round
#   artifact to disk. Twice the round history was then stated WRONGLY in a
#   commit message, in OPPOSITE directions:
#     (a) commit 8dad4e3 folded round 1 into round 2 and mis-dated a BLOCKING
#         finding to the wrong round;
#     (b) commit 1690789 "corrected" (a) and OVER-ROTATED, moving three
#         surviving reviewer mutations to round 1 when only one belonged there.
#   Both were caught only because the reviewer still held the record in its own
#   volatile context. Once that context is gone the review history is
#   UNRECONSTRUCTABLE from the repository — the conductor said exactly that, in
#   both commits, as an honest §11.4.6 boundary.
#
#   A review loop whose only record is an agent's context is a PROSE-grade
#   record of a GATING decision — §11.4.115(F) demands MACHINE-WRITTEN verdicts,
#   §11.4.134 demands iterate-to-clean-GO, and §11.4.226 holds that the EVIDENCE
#   CLASS at closure predicts whether the work holds.
#
# THE TWO HISTORICAL FAILURE MODES ARE FIXTURES, NOT PROSE
#   T3  a later round MUST NOT be able to REWRITE an earlier round's record
#       (defeats (a)-style and (b)-style retroactive re-attribution at the
#       WRITE seam);
#   T5  a mutation recorded SURVIVED in round N MUST remain attributable to
#       round N after later rounds are appended (defeats (b) directly).
#
# ANTI-BLUFF (§11.4.201(1))
#   A recorder that refused every append would satisfy T3 perfectly and be
#   useless. T1/T4/T6/T9 are the false-positive guards: a legitimate append,
#   an untampered chain, and a well-formed query MUST all succeed.
#
# Usage:  bash scripts/review/review_round_record_test.sh
# Exit :  0 all PASS · 1 any FAIL · 77 SKIP-with-reason (§11.4.3)
# POSIX-compatible bash; `bash -n` and `sh -n` clean (§11.4.67).
# =============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REC="$REPO_ROOT/scripts/review/review_round_record.sh"

SCRATCH="${TMPDIR:-/tmp}"; SCRATCH="${SCRATCH%/}"
WORK="$SCRATCH/review_round_record_test.$$"
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "SKIP: scratch root $SCRATCH not writable — §11.4.3"; exit 77
fi
# §11.4.14 — quiescent exit on every path.
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: sha256sum absent — §11.4.3"; exit 77; }

N_PASS=0; N_FAIL=0
ok()   { N_PASS=$((N_PASS+1)); echo "PASS: $1"; }
bad()  { N_FAIL=$((N_FAIL+1)); echo "FAIL: $1"; }
check(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2 — $3"; fi; }

# --- PRECONDITION: the artifact under test must exist and be runnable -------
# A RED run before the helper is written stops HERE, and says why.
if [ ! -f "$REC" ]; then
    echo "FAIL: T0 recorder present — $REC does not exist (RED: helper not yet written)"
    echo "SUMMARY PASS=0 FAIL=1"; exit 1
fi
ok "T0 recorder present at scripts/review/review_round_record.sh"

S="$WORK/review_rounds.jsonl"
SNAP="$WORK/review_rounds.status.json"

# --- T1  a legitimate first append SUCCEEDS (false-positive guard) ----------
out=$(sh "$REC" append --stream "$S" --round 1 \
        --reviewer independent-reviewer --model opus --effort high \
        --verdict NO-GO --evidence "qa-results/round1.log" \
        --finding "BLOCKING:## H. over-deletion" \
        --mutation "M-A:SURVIVED" 2>&1); rc=$?
check "$rc" "T1 legitimate round-1 append succeeds" "rc=$rc out=$out"
[ -f "$S" ] && ok "T1b stream file created" || bad "T1b stream file created — $S absent"

# --- T2  the record is MACHINE-READABLE and carries the mandated fields -----
line1=$(head -1 "$S" 2>/dev/null)
miss=""
for f in '"round":1' '"reviewer":' '"model":' '"effort":' '"verdict":"NO-GO"' \
         '"evidence":' '"findings":' '"mutations":' '"ts":' '"seq":1' '"prev_digest":' '"digest":'; do
    case "$line1" in *"$f"*) : ;; *) miss="$miss $f" ;; esac
done
[ -z "$miss" ] && ok "T2 round record carries every mandated field" \
                || bad "T2 round record carries every mandated field — missing:$miss"

# --- T3  HISTORICAL FAILURE MODE (a): REWRITING round 1 MUST BE REFUSED -----
before=$(sha256sum "$S" | cut -d' ' -f1)
out=$(sh "$REC" append --stream "$S" --round 1 \
        --reviewer independent-reviewer --model opus --effort high \
        --verdict GO --evidence "qa-results/rewrite.log" 2>&1); rc=$?
after=$(sha256sum "$S" | cut -d' ' -f1)
if [ "$rc" -ne 0 ]; then ok "T3 re-appending an existing round is REFUSED"
else bad "T3 re-appending an existing round is REFUSED — rc=0, rewrite accepted: $out"; fi
[ "$before" = "$after" ] && ok "T3b stream bytes UNCHANGED by the refused rewrite" \
                          || bad "T3b stream bytes UNCHANGED by the refused rewrite — stream mutated"

# --- T4  appending LATER rounds succeeds (false-positive guard) -------------
sh "$REC" append --stream "$S" --round 2 --reviewer independent-reviewer \
     --model opus --effort high --verdict NO-GO --evidence "qa-results/round2.log" \
     --finding "IMPORTANT:regex widening" --mutation "M-A:CAUGHT" \
     --mutation "R1:SURVIVED" >/dev/null 2>&1
check "$?" "T4 round-2 append succeeds" "later round rejected"
sh "$REC" append --stream "$S" --round 3 --reviewer independent-reviewer \
     --model opus --effort high --verdict NO-GO --evidence "qa-results/round3.log" \
     --finding "IMPORTANT:defect 5" >/dev/null 2>&1
sh "$REC" append --stream "$S" --round 4 --reviewer independent-reviewer \
     --model opus --effort high --verdict GO --evidence "qa-results/round4.log" >/dev/null 2>&1
check "$?" "T4b round-4 GO append succeeds" "final round rejected"

# --- T5  HISTORICAL FAILURE MODE (b): attribution survives later rounds -----
# M-A was recorded SURVIVED in ROUND 1. After rounds 2-4 land, the round-1
# record MUST still say SURVIVED-in-round-1. This is the exact fact commit
# 1690789 over-rotated.
r1=$(sh "$REC" round --stream "$S" --round 1 2>/dev/null)
case "$r1" in
  *'"id":"M-A","outcome":"SURVIVED"'*) ok "T5 M-A still attributable SURVIVED to round 1" ;;
  *) bad "T5 M-A still attributable SURVIVED to round 1 — got: $r1" ;;
esac
# and round 2 must carry its OWN outcome for M-A (CAUGHT), not round 1's.
r2=$(sh "$REC" round --stream "$S" --round 2 2>/dev/null)
case "$r2" in
  *'"id":"M-A","outcome":"CAUGHT"'*) ok "T5b round 2 carries its own M-A outcome (CAUGHT)" ;;
  *) bad "T5b round 2 carries its own M-A outcome (CAUGHT) — got: $r2" ;;
esac
# the query interface must name the round, so attribution is mechanical
q=$(sh "$REC" mutation --stream "$S" --mutation M-A 2>/dev/null)
case "$q" in
  *"1"*SURVIVED*2*CAUGHT*) ok "T5c mutation query reports per-round outcomes in order" ;;
  *) bad "T5c mutation query reports per-round outcomes in order — got: $(echo "$q" | tr '\n' '|')" ;;
esac

# --- T6  an UNTAMPERED chain verifies clean (false-positive guard) ----------
sh "$REC" verify --stream "$S" >/dev/null 2>&1
check "$?" "T6 untampered chain verifies clean" "healthy chain refused"

# --- T7  a RETROACTIVE EDIT of an earlier round is DETECTED ----------------
# T3 blocks rewrite through the tool; T7 covers the raw-file edit path.
T="$WORK/tampered.jsonl"
sed '1s/NO-GO/GO/' "$S" > "$T"
sh "$REC" verify --stream "$T" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "T7 retroactive edit of round 1 is DETECTED by verify"
else bad "T7 retroactive edit of round 1 is DETECTED by verify — verify passed a tampered chain"; fi

# --- T8  closed verdict vocabulary: an invented verdict is REFUSED ---------
sh "$REC" append --stream "$S" --round 5 --reviewer r --model opus --effort high \
     --verdict PROBABLY-FINE --evidence "x.log" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "T8 verdict outside {GO,NO-GO} is REFUSED"
else bad "T8 verdict outside {GO,NO-GO} is REFUSED — invented verdict accepted"; fi

# --- T9  §11.4.116 status snapshot exists and reflects the LAST round ------
if [ -f "$SNAP" ]; then
    ok "T9 status snapshot written beside the stream"
    s=$(cat "$SNAP")
    case "$s" in *'"last_round":4'*) ok "T9b snapshot reports last_round=4" ;;
                 *) bad "T9b snapshot reports last_round=4 — got: $s" ;; esac
    case "$s" in *'"last_verdict":"GO"'*) ok "T9c snapshot reports last_verdict=GO" ;;
                 *) bad "T9c snapshot reports last_verdict=GO — got: $s" ;; esac
else
    bad "T9 status snapshot written beside the stream — $SNAP absent"
fi

# --- T10 §11.4.116 a verdict event MUST carry an evidence path -------------
sh "$REC" append --stream "$S" --round 5 --reviewer r --model opus --effort high \
     --verdict GO >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "T10 verdict with no evidence path is REFUSED"
else bad "T10 verdict with no evidence path is REFUSED — evidence-less verdict accepted"; fi

# --- T11 honest blindness: an absent stream REFUSES, never passes ----------
sh "$REC" verify --stream "$WORK/no_such_stream.jsonl" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "T11 verify of an ABSENT stream refuses (never a clean pass)"
else bad "T11 verify of an ABSENT stream refuses — absent stream reported clean"; fi

# --- T12 a BROKEN HASHER is refused, NOT reported as tampering -------------
#
# §11.4.201(1)(5). Every recomputed digest comes from `sha256sum`. When the
# hasher is missing or shimmed to fail, the recomputation returns nothing and a
# naive comparison mismatches on EVERY line — so verify accused a perfectly
# intact chain of having been "altered after it was written". That is a
# FAIL-bluff: it blames the STORE for a defect in the INSTRUMENT, and it sends
# an operator hunting a tamper that never happened. Both outcomes are a
# refusal (rc != 0); what this test pins is WHICH refusal, because the two
# demand opposite responses — repair the toolchain vs investigate an intrusion.
mkdir -p "$WORK/shimbin"
printf '#!/bin/sh\nexit 127\n' > "$WORK/shimbin/sha256sum"
chmod +x "$WORK/shimbin/sha256sum"
hash_out=$(PATH="$WORK/shimbin:$PATH" sh "$REC" verify --stream "$S" 2>&1)
case "$hash_out" in
    *"altered after it was written"*)
        bad "T12 broken hasher is not reported as tampering — got: $hash_out" ;;
    *"NOT evidence of tampering"*)
        ok "T12 broken hasher REFUSES and is explicitly not called tampering" ;;
    *)
        bad "T12 broken hasher REFUSES with an explicit reason — got: $hash_out" ;;
esac
# §11.4.201(5): the refusal must carry its RESOLVED evidence, so the operator
# can see WHICH hasher failed rather than being told only that something did.
case "$hash_out" in
    *"$WORK/shimbin/sha256sum"*) ok "T12b refusal names the resolved hasher path" ;;
    *) bad "T12b refusal names the resolved hasher path — got: $hash_out" ;;
esac

# --- T13 a SILENTLY WRONG hasher is refused too ----------------------------
#
# A hasher that resolves and emits a plausible digest is worse than one that is
# absent: every entry mismatches and the chain reads as wholly tampered. The
# probe therefore uses a known-answer control needle (the SHA-256 of the empty
# string), so a wrong-but-well-formed instrument is caught by its ANSWER, not
# merely by its exit status.
printf '#!/bin/sh\nprintf "deadbeef  -\\n"\n' > "$WORK/shimbin/sha256sum"
chmod +x "$WORK/shimbin/sha256sum"
wrong_out=$(PATH="$WORK/shimbin:$PATH" sh "$REC" verify --stream "$S" 2>&1)
case "$wrong_out" in
    *"NOT evidence of tampering"*) ok "T13 silently-wrong hasher REFUSES via the known-answer needle" ;;
    *) bad "T13 silently-wrong hasher REFUSES via the known-answer needle — got: $wrong_out" ;;
esac

# --- T14 FALSE-POSITIVE GUARD: a healthy hasher still verifies clean --------
#
# §11.4.201(1). T12/T13 are satisfied perfectly by a verify that refuses
# ALWAYS. This is the control needle proving the hasher probe does not refuse a
# working toolchain: with the shim OFF the very same stream must verify OK.
rm -rf "$WORK/shimbin"
if sh "$REC" verify --stream "$S" >/dev/null 2>&1; then
    ok "T14 healthy hasher still verifies the same chain clean (probe adds no false refusal)"
else
    bad "T14 healthy hasher still verifies the same chain clean — the hasher probe refuses a working toolchain"
fi

echo "SUMMARY PASS=$N_PASS FAIL=$N_FAIL"
[ "$N_FAIL" -eq 0 ] || exit 1
exit 0
