#!/bin/sh
# =============================================================================
# review_round_record.sh — durable, append-only, machine-readable record of
#                          ONE code-review round
# =============================================================================
#
# WHY THIS EXISTS (captured forensic fact, 2026-09-01)
#   A code-review loop ran four rounds plus two deltas and wrote NO per-round
#   artifact to disk. The round history was then stated WRONGLY in a commit
#   message twice, in OPPOSITE directions:
#     commit 8dad4e3  folded round 1 into round 2 and mis-dated a BLOCKING
#                     finding to the wrong round;
#     commit 1690789  "corrected" that and OVER-ROTATED, moving three surviving
#                     reviewer mutations to round 1 when only one belonged there.
#   Both errors were caught only because the reviewer still held the record in
#   its own volatile context. Once that context is gone the review history is
#   UNRECONSTRUCTABLE from the repository — which both commits stated as an
#   honest §11.4.6 boundary. This script removes that boundary: the record
#   lands on disk, at write time, in a form a later round cannot rewrite.
#
#   §11.4.115(F) requires MACHINE-WRITTEN verdicts rather than prose.
#   §11.4.134 requires iterate-to-clean-GO — which presumes the rounds are
#   individually knowable. §11.4.226 holds that the EVIDENCE CLASS at closure
#   predicts whether the work holds; an agent's context is prose-class.
#
# SUBSTRATE — REUSED, NOT INVENTED (§11.4.227 extend-don't-duplicate)
#   §11.4.116 already specifies exactly the right two-part channel for a
#   long-running process an orchestrator depends on:
#     (1) a structured APPEND-ONLY JSONL event stream, one event per line,
#         never rewritten;
#     (2) an ATOMICALLY-REWRITTEN status snapshot (write-temp-then-rename, so a
#         reader never observes a torn write).
#   This script emits precisely that pair. The per-entry chain fields are the
#   shape the constitution's own chain verifier already contracts for
#   (contiguous `seq` + `prev_digest`, per
#   constitution/scripts/gates/cm_chain_integrity_detects_alteration.sh), so
#   this record composes with that verifier rather than competing with it.
#
# APPEND-ONLY IS THE WHOLE POINT
#   Both historical errors were RETROACTIVE RE-ATTRIBUTIONS. Two seams close
#   that class:
#     WRITE seam  — `append` REFUSES any round already recorded, and any round
#                   not strictly greater than the highest recorded round. A
#                   later round therefore cannot restate an earlier one.
#     READ  seam  — `verify` recomputes every entry's digest and walks the
#                   prev_digest chain, so an edit made by going around this
#                   tool (a text editor on the .jsonl) is DETECTED.
#
# HONEST BOUNDARY (§11.4.6)
#   The chain proves INTERNAL consistency. It cannot, alone, detect a deletion
#   followed by a full re-chain, nor a tail truncation — both leave a perfect
#   chain. Detecting those needs a periodic external anchor (§11.4.268); this
#   script does NOT implement one and does not claim to. What it does claim is
#   exactly what it was built for: an in-place edit or an attempted rewrite of
#   an already-recorded round is refused or detected.
#
# VERDICT VOCABULARY
#   Round verdicts are GO / NO-GO — the §11.4.125 / §11.4.134 review vocabulary.
#   §11.4.116's PASS/FAIL/SKIP/OPERATOR-BLOCKED set is the per-TEST-item
#   vocabulary and is deliberately not reused here: a review round returns a
#   gate decision, not a test outcome. Stated rather than silently diverged.
#
# USAGE
#   review_round_record.sh append --stream <path> --round <N>
#        --reviewer <id> --verdict GO|NO-GO --evidence <path>
#        [--model <m>] [--effort <e>]
#        [--finding SEVERITY:TEXT]...  [--mutation ID:SURVIVED|CAUGHT]...
#   review_round_record.sh verify   --stream <path>
#   review_round_record.sh round    --stream <path> --round <N>
#   review_round_record.sh mutation --stream <path> --mutation <ID>
#   review_round_record.sh status   --stream <path>
#   review_round_record.sh --selftest
#
#   --model / --effort default to the honest "?" when the caller cannot derive
#   them, per the §11.4.182 label rule: an unknown field is recorded UNKNOWN,
#   never guessed and never back-filled from memory.
#
# EXIT CODES
#   0 success · 1 refusal or detected inconsistency · 2 usage error
#
# SIDE EFFECTS
#   Appends one line to <stream>; atomically rewrites <stream-base>.status.json.
#   Writes nothing on any refusal path.
#
# DEPENDENCIES
#   POSIX sh, sha256sum, sed, awk, date, mktemp. `sh -n` and `bash -n` clean
#   (§11.4.67). Every internal name is `_rr_`-prefixed.
# =============================================================================

_rr_die()  { printf '%s\n' "review_round_record: $1" >&2; exit "${2:-1}"; }
_rr_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_rr_sha()  { printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1; }

# _rr_hasher_probe — prove the hasher WORKS, with a known-answer control needle
# (§11.4.201(7)(b)). It is not enough that `sha256sum` resolves on PATH: a
# shimmed, non-executable, or wrong-output binary resolves fine and still
# returns nothing usable. The needle is the empty string, whose SHA-256 is a
# fixed constant, so a hasher that returns a plausible-looking but WRONG digest
# is refused too — an instrument that is silently wrong is worse than one that
# is absent. Prints the resolved evidence and returns non-zero on failure.
_rr_hasher_needle='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
_rr_hasher_probe() {
    _rr_hp_where=$(command -v sha256sum 2>/dev/null || printf '<not on PATH>')
    _rr_hp_got=$(printf '%s' '' | sha256sum 2>/dev/null | cut -d' ' -f1)
    if [ -z "$_rr_hp_got" ]; then
        printf 'sha256sum produced NO output — resolved to: %s\n' "$_rr_hp_where"
        return 1
    fi
    if [ "$_rr_hp_got" != "$_rr_hasher_needle" ]; then
        printf 'sha256sum produced a WRONG digest for the empty-string control needle — resolved to: %s (got %s, want %s)\n' \
            "$_rr_hp_where" "$_rr_hp_got" "$_rr_hasher_needle"
        return 1
    fi
    return 0
}

# JSON string escaping: backslash, quote, then newlines/tabs flattened.
_rr_esc() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr '\n' '\001' | tr '\t' '\002' \
        | sed -e 's/\001/\\n/g' -e 's/\002/\\t/g'
}

# The snapshot path is derived from the stream path, never taken separately —
# a snapshot that can point at a different stream is a divergence waiting to
# happen.
_rr_snap_path() {
    case "$1" in
        *.jsonl) printf '%s.status.json' "${1%.jsonl}" ;;
        *)       printf '%s.status.json' "$1" ;;
    esac
}

# Strip the trailing digest field to recover the exact bytes the digest covered.
_rr_core_of() { printf '%s' "$1" | sed -e 's/,"digest":"[0-9a-f]*"}$//'; }
_rr_digest_of() {
    printf '%s' "$1" | sed -n 's/.*,"digest":"\([0-9a-f]*\)"}$/\1/p'
}

# Read a numeric/simple field out of one entry line.
_rr_field() { printf '%s' "$2" | sed -n 's/.*"'"$1"'":\([0-9]*\).*/\1/p' | head -1; }

# --- highest recorded round, and whether a given round already exists -------
_rr_max_round() {
    [ -f "$1" ] || { printf '0'; return 0; }
    awk '{ if (match($0, /"round":[0-9]+/)) {
               r = substr($0, RSTART+8, RLENGTH-8) + 0; if (r > m) m = r } }
         END { printf "%d", m+0 }' "$1"
}
_rr_has_round() {
    [ -f "$1" ] || return 1
    grep -q '"round":'"$2"',' "$1"
}

# =============================================================================
# append
# =============================================================================
_rr_append() {
    _rr_stream=''; _rr_round=''; _rr_reviewer=''; _rr_model='?'; _rr_effort='?'
    _rr_verdict=''; _rr_evidence=''; _rr_findings=''; _rr_mutations=''

    while [ $# -gt 0 ]; do
        case "$1" in
            --stream)   _rr_stream="${2:-}";   shift 2 ;;
            --round)    _rr_round="${2:-}";    shift 2 ;;
            --reviewer) _rr_reviewer="${2:-}"; shift 2 ;;
            --model)    _rr_model="${2:-}";    shift 2 ;;
            --effort)   _rr_effort="${2:-}";   shift 2 ;;
            --verdict)  _rr_verdict="${2:-}";  shift 2 ;;
            --evidence) _rr_evidence="${2:-}"; shift 2 ;;
            --finding)
                _rr_sev=$(printf '%s' "${2:-}" | cut -d: -f1)
                _rr_txt=$(printf '%s' "${2:-}" | cut -d: -f2-)
                [ -n "$_rr_sev" ] || _rr_die "empty --finding severity" 2
                _rr_findings="$_rr_findings{\"severity\":\"$(_rr_esc "$_rr_sev")\",\"text\":\"$(_rr_esc "$_rr_txt")\"},"
                shift 2 ;;
            --mutation)
                _rr_id=$(printf '%s' "${2:-}" | cut -d: -f1)
                _rr_oc=$(printf '%s' "${2:-}" | cut -d: -f2-)
                case "$_rr_oc" in
                    SURVIVED|CAUGHT) : ;;
                    # A mutation whose outcome is neither SURVIVED nor CAUGHT is
                    # not a recordable fact — it is an unfinished experiment.
                    *) _rr_die "mutation outcome must be SURVIVED or CAUGHT (got '$_rr_oc')" 2 ;;
                esac
                [ -n "$_rr_id" ] || _rr_die "empty --mutation id" 2
                _rr_mutations="$_rr_mutations{\"id\":\"$(_rr_esc "$_rr_id")\",\"outcome\":\"$_rr_oc\"},"
                shift 2 ;;
            *) _rr_die "unknown append option '$1'" 2 ;;
        esac
    done

    [ -n "$_rr_stream" ]   || _rr_die "--stream is required" 2
    [ -n "$_rr_round" ]    || _rr_die "--round is required" 2
    [ -n "$_rr_reviewer" ] || _rr_die "--reviewer is required" 2
    case "$_rr_round" in ''|*[!0-9]*) _rr_die "--round must be a positive integer" 2 ;; esac
    [ "$_rr_round" -ge 1 ] || _rr_die "--round must be >= 1" 2

    # Closed verdict vocabulary. An invented verdict is refused, never coerced.
    case "$_rr_verdict" in
        GO|NO-GO) : ;;
        *) _rr_die "verdict must be GO or NO-GO (got '$_rr_verdict')" 1 ;;
    esac

    # §11.4.116: a verdict event MUST carry the evidence path backing it.
    # A verdict with no evidence path is a PASS-bluff at the channel layer.
    [ -n "$_rr_evidence" ] || _rr_die "a verdict event requires --evidence (§11.4.116)" 1

    # --- THE APPEND-ONLY SEAM ------------------------------------------------
    # This is the check that would have refused BOTH historical re-attributions.
    if _rr_has_round "$_rr_stream" "$_rr_round"; then
        _rr_die "round $_rr_round is already recorded — an earlier round is never rewritten (append-only)" 1
    fi
    _rr_max=$(_rr_max_round "$_rr_stream")
    if [ "$_rr_round" -le "$_rr_max" ]; then
        _rr_die "round $_rr_round is not greater than the highest recorded round $_rr_max — out-of-order append refused" 1
    fi

    _rr_dir=$(dirname "$_rr_stream")
    [ -d "$_rr_dir" ] || mkdir -p "$_rr_dir" 2>/dev/null || _rr_die "cannot create $_rr_dir" 1

    # Chain linkage: seq is contiguous, prev_digest points at the predecessor.
    if [ -f "$_rr_stream" ] && [ -s "$_rr_stream" ]; then
        _rr_prev_line=$(tail -1 "$_rr_stream")
        _rr_prev=$(_rr_digest_of "$_rr_prev_line")
        [ -n "$_rr_prev" ] || _rr_die "predecessor entry carries no digest — chain unreadable, refusing to extend" 1
        _rr_seq=$(( $(_rr_field seq "$_rr_prev_line") + 1 ))
    else
        _rr_prev='GENESIS'
        _rr_seq=1
    fi

    _rr_core="{\"seq\":${_rr_seq},\"prev_digest\":\"${_rr_prev}\",\"ts\":\"$(_rr_now)\""
    _rr_core="${_rr_core},\"round\":${_rr_round}"
    _rr_core="${_rr_core},\"reviewer\":\"$(_rr_esc "$_rr_reviewer")\""
    _rr_core="${_rr_core},\"model\":\"$(_rr_esc "$_rr_model")\""
    _rr_core="${_rr_core},\"effort\":\"$(_rr_esc "$_rr_effort")\""
    _rr_core="${_rr_core},\"verdict\":\"${_rr_verdict}\""
    _rr_core="${_rr_core},\"evidence\":\"$(_rr_esc "$_rr_evidence")\""
    _rr_core="${_rr_core},\"findings\":[${_rr_findings%,}]"
    _rr_core="${_rr_core},\"mutations\":[${_rr_mutations%,}]"

    _rr_dig=$(_rr_sha "$_rr_core")
    [ -n "$_rr_dig" ] || _rr_die "sha256sum unavailable — refusing to write an unchainable entry" 1

    printf '%s,"digest":"%s"}\n' "$_rr_core" "$_rr_dig" >> "$_rr_stream" \
        || _rr_die "cannot append to $_rr_stream" 1

    _rr_write_snapshot "$_rr_stream"
    printf 'recorded round %s (%s) seq=%s digest=%s\n' \
        "$_rr_round" "$_rr_verdict" "$_rr_seq" "$_rr_dig"
}

# =============================================================================
# status snapshot — write-temp-then-rename, so a reader never sees a torn write
# =============================================================================
_rr_write_snapshot() {
    _rr_s="$1"
    _rr_snap=$(_rr_snap_path "$_rr_s")
    _rr_last=$(tail -1 "$_rr_s")
    _rr_tmp="${_rr_snap}.tmp.$$"
    {
        printf '{"stream":"%s"' "$(_rr_esc "$_rr_s")"
        printf ',"rounds_total":%s' "$(wc -l < "$_rr_s" | tr -d ' ')"
        printf ',"last_round":%s' "$(_rr_field round "$_rr_last")"
        printf ',"last_verdict":"%s"' \
            "$(printf '%s' "$_rr_last" | sed -n 's/.*"verdict":"\([^"]*\)".*/\1/p')"
        printf ',"last_seq":%s' "$(_rr_field seq "$_rr_last")"
        printf ',"head_digest":"%s"' "$(_rr_digest_of "$_rr_last")"
        printf ',"updated_at":"%s"}\n' "$(_rr_now)"
    } > "$_rr_tmp" 2>/dev/null || { rm -f "$_rr_tmp"; _rr_die "cannot stage snapshot" 1; }
    mv -f "$_rr_tmp" "$_rr_snap" || { rm -f "$_rr_tmp"; _rr_die "cannot publish snapshot" 1; }
}

# =============================================================================
# verify — recompute every digest, walk the chain, check seq contiguity
# =============================================================================
_rr_verify() {
    _rr_stream=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --stream) _rr_stream="${2:-}"; shift 2 ;;
            *) _rr_die "unknown verify option '$1'" 2 ;;
        esac
    done
    [ -n "$_rr_stream" ] || _rr_die "--stream is required" 2
    # An absent or unreadable store REFUSES. "Could not look" and "looked and
    # found it clean" are different answers (§11.4.201(6) false null).
    [ -f "$_rr_stream" ] || _rr_die "stream absent: $_rr_stream — REFUSE (not a clean pass)" 1
    [ -r "$_rr_stream" ] || _rr_die "stream unreadable: $_rr_stream — REFUSE" 1
    [ -s "$_rr_stream" ] || _rr_die "stream empty: $_rr_stream — REFUSE (an empty chain proves nothing)" 1

    # A BROKEN HASHER IS NOT TAMPERING (§11.4.201(1)(5)). Every recomputed
    # digest below comes from _rr_sha; if the hasher is missing or shimmed to
    # fail, _rr_sha returns the empty string, every comparison mismatches, and
    # verify would report "entry was altered after it was written" on a
    # perfectly intact chain — a FAIL-bluff accusing the store of tampering
    # because the INSTRUMENT is broken. Probe the instrument FIRST, refuse with
    # the resolved evidence, and never let an un-recomputable digest masquerade
    # as a detected alteration.
    if ! _rr_hp_evidence=$(_rr_hasher_probe); then
        _rr_die "cannot verify: the hasher itself is unusable — REFUSE (this is NOT evidence of tampering). Resolved evidence: ${_rr_hp_evidence}" 1
    fi

    _rr_exp_seq=1; _rr_exp_prev='GENESIS'; _rr_bad=0; _rr_n=0
    while IFS= read -r _rr_line; do
        [ -n "$_rr_line" ] || continue
        _rr_n=$((_rr_n + 1))
        _rr_c=$(_rr_core_of "$_rr_line")
        _rr_d=$(_rr_digest_of "$_rr_line")
        if [ -z "$_rr_d" ]; then
            printf 'FAIL line %s: no digest field\n' "$_rr_n"; _rr_bad=1; continue
        fi
        _rr_r=$(_rr_sha "$_rr_c")
        if [ -z "$_rr_r" ]; then
            # Second line of defence behind the up-front probe: a hasher that
            # died mid-walk (resource exhaustion, a signal) must still be
            # reported as an instrument failure, never as an altered entry.
            printf 'REFUSE line %s: digest could not be RECOMPUTED (hasher failure mid-walk, resolved: %s) — NOT evidence of tampering\n' \
                "$_rr_n" "$(command -v sha256sum 2>/dev/null || printf '<not on PATH>')"
            _rr_bad=1
        elif [ "$_rr_r" != "$_rr_d" ]; then
            printf 'FAIL line %s: digest mismatch (entry was altered after it was written; recomputed %s, recorded %s)\n' \
                "$_rr_n" "$_rr_r" "$_rr_d"
            _rr_bad=1
        fi
        _rr_gotseq=$(_rr_field seq "$_rr_line")
        if [ "$_rr_gotseq" != "$_rr_exp_seq" ]; then
            printf 'FAIL line %s: seq %s, expected %s (entry deleted, reordered or inserted)\n' \
                "$_rr_n" "$_rr_gotseq" "$_rr_exp_seq"
            _rr_bad=1
        fi
        _rr_gotprev=$(printf '%s' "$_rr_line" | sed -n 's/.*"prev_digest":"\([^"]*\)".*/\1/p')
        if [ "$_rr_gotprev" != "$_rr_exp_prev" ]; then
            printf 'FAIL line %s: prev_digest does not match its predecessor\n' "$_rr_n"
            _rr_bad=1
        fi
        _rr_exp_prev="$_rr_d"
        _rr_exp_seq=$((_rr_exp_seq + 1))
    done < "$_rr_stream"

    if [ "$_rr_bad" -ne 0 ]; then
        printf 'VERIFY FAIL: %s entries walked, chain integrity broken\n' "$_rr_n"; exit 1
    fi
    printf 'VERIFY OK: %s entries, chain intact (internal consistency only — see §11.4.268 on anchors)\n' "$_rr_n"
}

# =============================================================================
# round / mutation / status queries
# =============================================================================
_rr_round_query() {
    _rr_stream=''; _rr_round=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --stream) _rr_stream="${2:-}"; shift 2 ;;
            --round)  _rr_round="${2:-}";  shift 2 ;;
            *) _rr_die "unknown round option '$1'" 2 ;;
        esac
    done
    [ -n "$_rr_stream" ] || _rr_die "--stream is required" 2
    [ -n "$_rr_round" ]  || _rr_die "--round is required" 2
    [ -f "$_rr_stream" ] || _rr_die "stream absent: $_rr_stream" 1
    _rr_hit=$(grep '"round":'"$_rr_round"',' "$_rr_stream" | head -1)
    [ -n "$_rr_hit" ] || _rr_die "round $_rr_round not recorded" 1
    printf '%s\n' "$_rr_hit"
}

_rr_mutation_query() {
    _rr_stream=''; _rr_mid=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --stream)   _rr_stream="${2:-}"; shift 2 ;;
            --mutation) _rr_mid="${2:-}";    shift 2 ;;
            *) _rr_die "unknown mutation option '$1'" 2 ;;
        esac
    done
    [ -n "$_rr_stream" ] || _rr_die "--stream is required" 2
    [ -n "$_rr_mid" ]    || _rr_die "--mutation is required" 2
    [ -f "$_rr_stream" ] || _rr_die "stream absent: $_rr_stream" 1
    # Per-round outcomes, in round order. This is the query that makes
    # "which round did this mutation survive in" a lookup rather than a memory.
    _rr_found=0
    while IFS= read -r _rr_line; do
        case "$_rr_line" in
            *"\"id\":\"$_rr_mid\",\"outcome\":\""*)
                _rr_rn=$(_rr_field round "$_rr_line")
                _rr_oc=$(printf '%s' "$_rr_line" \
                    | sed -n 's/.*"id":"'"$_rr_mid"'","outcome":"\([A-Z]*\)".*/\1/p')
                printf '%s\t%s\n' "$_rr_rn" "$_rr_oc"
                _rr_found=1 ;;
        esac
    done < "$_rr_stream"
    [ "$_rr_found" -eq 1 ] || _rr_die "mutation $_rr_mid not recorded in any round" 1
}

_rr_status_query() {
    _rr_stream=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --stream) _rr_stream="${2:-}"; shift 2 ;;
            *) _rr_die "unknown status option '$1'" 2 ;;
        esac
    done
    [ -n "$_rr_stream" ] || _rr_die "--stream is required" 2
    _rr_snap=$(_rr_snap_path "$_rr_stream")
    [ -f "$_rr_snap" ] || _rr_die "snapshot absent: $_rr_snap" 1
    cat "$_rr_snap"
}

# =============================================================================
# --selftest — the analyzer validates itself (§11.4.107(10))
#   golden-good  a healthy chain MUST verify clean
#   golden-bad   a tampered chain MUST be detected
#   A verifier that only ever refused would pass the bad case and fail the
#   good one; running both is what makes either meaningful.
# =============================================================================
_rr_selftest() {
    _rr_t=$(mktemp -d) || _rr_die "mktemp failed" 1
    _rr_rc=0
    _rr_g="$_rr_t/good.jsonl"
    _rr_append --stream "$_rr_g" --round 1 --reviewer selftest --verdict NO-GO \
        --evidence e1 --mutation "M1:SURVIVED" >/dev/null 2>&1
    _rr_append --stream "$_rr_g" --round 2 --reviewer selftest --verdict GO \
        --evidence e2 --mutation "M1:CAUGHT" >/dev/null 2>&1
    if ( _rr_verify --stream "$_rr_g" >/dev/null 2>&1 ); then
        printf 'SELFTEST golden-good: PASS (healthy chain verifies)\n'
    else
        printf 'SELFTEST golden-good: FAIL (healthy chain refused)\n'; _rr_rc=1
    fi
    _rr_b="$_rr_t/bad.jsonl"
    sed '1s/NO-GO/GO/' "$_rr_g" > "$_rr_b"
    if ( _rr_verify --stream "$_rr_b" >/dev/null 2>&1 ); then
        printf 'SELFTEST golden-bad: FAIL (tampered chain passed)\n'; _rr_rc=1
    else
        printf 'SELFTEST golden-bad: PASS (tampered chain detected)\n'
    fi
    rm -rf "$_rr_t"
    return "$_rr_rc"
}

_rr_usage() {
    sed -n '/^# USAGE/,/^# EXIT CODES/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'
}

# =============================================================================
# dispatch
# =============================================================================
[ $# -ge 1 ] || { _rr_usage >&2; exit 2; }
_rr_cmd="$1"; shift
case "$_rr_cmd" in
    append)     _rr_append "$@" ;;
    verify)     _rr_verify "$@" ;;
    round)      _rr_round_query "$@" ;;
    mutation)   _rr_mutation_query "$@" ;;
    status)     _rr_status_query "$@" ;;
    --selftest) _rr_selftest ;;
    -h|--help)  _rr_usage ;;
    *) _rr_die "unknown command '$_rr_cmd'" 2 ;;
esac
