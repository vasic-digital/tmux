# TMX-090 closure evidence — I1 WHEEL-COPY-MODE-OVERRIDE-001

**Date:** 2026-09-29
**Investigator:** Claude (systematic-debugging arc, root-cause investigation per §11.4.102)

## Summary

Issues.md item I1/TMX-090 was tracked as "In progress — cause NOT established" for
test 17 sub-check T3 ("FAIL: T3: live WheelUpPane binding is not the copy-mode
override"). Investigation confirms the underlying defect was **already root-caused
and already fixed** in commit `2e4ec22` (2026-09-01 18:27:50 +0200,
"fix(tests): version-stable key readback + six skip remediations (TMX-090/091)") —
but the Issues.md entry was added by that SAME commit, describing the investigation's
pre-diagnosis state (before the root cause was found later in that work session), and
was never updated afterward. This closure corrects that tracker-sync gap.

## Root cause (proven in `2e4ec22`'s own commit message, independently re-confirmed
live today)

tmux 3.7b's `cmd-list-keys.c` print branch is:

```c
if ((single && tc != NULL) || n == 1)
```

The `|| n == 1` arm has NO `tc != NULL` guard, so ANY `list-keys` query matching
exactly one row is routed to a nonexistent client's status line and DISCARDED when
run from a script (no attached client). The raw single-key query form,
`tmux list-keys -T root WheelUpPane`, therefore returns `rc=0` with EMPTY output
even though the binding is genuinely present and correct — a §11.4.201(6) false
null, not a missing binding.

## Fix (already landed, 2026-09-01, commit `2e4ec22`)

`scripts/tests/lib/list_key.sh` — a version-stable `tmx_list_key` helper that lists
the WHOLE key table and field-matches via `awk`, rather than querying a single key.
Wired into 10 call sites across tests 17/44/46/47/48, replacing the raw
`list-keys -T <table> <key>` form. A paired mutation,
`M-LIST-KEY-VERSION-STABLE` (scripts/tests/meta_test_false_positive_proof.sh),
reverts the helper to the broken single-key form and asserts test 17's T3 goes
FAIL — proving the regression guard is real per §1.1.

## Independent re-verification performed today (2026-09-29), on a LIVE fresh build

Two independent subagents, two independent fresh builds (`bash scripts/setup.sh
--rebuild`), both confirming `tmux 3.7b`:

1. **Direct capture (test 17):** standalone run of
   `scripts/tests/17_scrollback_copy_mode.sh` — `PASS=13 FAIL=0 SKIP=0`, `EXIT=0`,
   including explicit `PASS: T3: live WheelUpPane binding drives copy-mode
   scroll-up (override active, not tmux default)`. Same result reproduced inside
   the full `setup.sh` verification-gate run (not a standalone-only fluke).
   The raw single-key form (`list-keys -T root WheelUpPane`) was independently
   re-queried live and reproduced the documented tmux 3.7b quirk exactly: `rc=0`,
   empty output. The full `list-keys -T root` table (27 rows) shows `WheelUpPane`
   present exactly once, correctly formed, matching `scripts/tmux.conf.template:81`
   verbatim — no double-binding, no stale config, config file confirmed as the
   tracked repo path (`/home/milosvasic/Projects/tmux/scripts/tmux.conf.template`,
   not a stale system-wide copy).

2. **Sibling check (test 47, same mechanism):** standalone run of
   `scripts/tests/47_alt_screen_scroll.sh`, twice, deterministic —
   `PASS=8 FAIL=0 SKIP=0`, `EXIT=0` both times, including
   `PASS: T6: live WheelUpPane binding overrides tmux default — drives copy-mode
   unconditionally even under mouse-tracking`. T6 uses the identical
   `tmx_list_key` helper and assertion shape as T3.

3. **Static trace (Phase 2 pattern analysis):** confirmed the config mechanism
   itself is unchanged and clean — the binding at
   `scripts/tmux.conf.template:81` was introduced once in commit `d0825e1c7`
   (2026-05-21) and never modified since; `tmx` (both Linux and Darwin branches)
   loads this exact file directly via `-f`/`source-file` on every `new`/`attach`/
   `reload`, with no templating/sed touching the line and no OS-conditional
   exclusion; the binding syntax is confirmed valid for the pinned tmux 3.7b by
   both the shipped man page and tmux's own compiled-in default `WheelUpPane`
   binding using the identical `bind -n WheelUpPane if -F ...` grammar form.

4. **Meta-test mutation re-verification (today, this closure):**
   `scripts/tests/meta_test_false_positive_proof.sh` (the FULL suite, including
   `M-LIST-KEY-VERSION-STABLE`) was run in full against this same fresh build to
   confirm the regression guard for this fix still functions. Result recorded
   separately in the release-gate evidence for this cycle
   (also satisfies CONTINUATION.md §3.37b's outstanding "whole-suite meta-test
   mutation sweep NOT RUN" item).

## Verdict

**FIXED.** The live product behaviour is correct and has been correct since
commit `2e4ec22` landed on 2026-09-01. Today's independent re-verification on a
freshly-built binary confirms no regression since. Issues.md I1/TMX-090 is closed
as a §11.4.7-compliant demotion: the FAIL no longer reproduces, under the SAME
conditions (same test, same live-server readback mechanism, same config), backed
by captured evidence, not merely "cannot reproduce in isolation."

**Distinct finding, tracked separately, not part of this closure:** the Issues.md
entry itself was never updated after its own fix landed in the same commit — a
tracker-hygiene gap of the same class already found and being addressed this
cycle for A2/D2 (stale `Fixed` status never migrated). No new item filed for
this specific instance since it is fully resolved by this closure.
