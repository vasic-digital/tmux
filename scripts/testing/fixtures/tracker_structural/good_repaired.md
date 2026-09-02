# Issues — FIXTURE golden-FALSE: the repair that actually landed

The SAME intended removal as `bad_over_deleted.md` — the four `### G1..G4`
item blocks are gone — done correctly: the `## G.` header is TOMBSTONED
(kept and annotated, the corpus's own precedent in commit 8dad4e3), and the
`## H.` header plus its §11.4.114 preamble are untouched.

The gate MUST NOT fire on this file. Removing items is legitimate and
routine; only removing SECTIONS and their governing preambles is not.

---

## F. Runtime crash — operator-gated reproduction

Kept here so the fixture has a section BEFORE the damaged pair; a guard
that only ever looks at the last section would pass this file by accident.

### F1 WRAPPER-TMUXBIN-001 — stale wrapper points at a missing binary

**Type:** Bug
**Status:** Fixed (→ Fixed.md)

Body text.

---

## G. Interactive wizard + session-password redesign (2026-07-05)

New OPEN work from the 14-task wizard + session-password redesign plan.
Code lands across sibling tasks of that plan; these four entries track the
four user-visible requirements from the operator mandate.

**Section closed 2026-09-01.** All four entries have landed and now live in
`Fixed.md`. Their blocks were duplicated here while they were also in
`Fixed.md`; the duplicates were retired on operator decision so each item
has exactly one block. The heading is kept for the historical context
above — it is deliberately empty of items, not missing them.

---

## H. Pre-existing timing issues surfaced during the 2026-08-10 no-limits-by-default cycle

Discovered while validating TMX-079 (see `Fixed.md`). Confirmed via §11.4.114
A/B isolation against the v1.0.38 baseline (identical failures reproduced
BEFORE any of TMX-079's changes were applied) — NOT caused by TMX-079, and
TMX-079's own fix + tests are unaffected. Tracked here so they are not lost.

### H1 STATE-HOOK-RACE-001 — test 27 sub-check "18" intermittently fails

**Type:** Bug
**Status:** Reopened

Body text.

---

## I. Live copy-mode wheel binding (2026-09-01)

A section AFTER the damaged pair, so the fixture proves the guard walks the
whole file rather than stopping at the first divergence.

### I1 WHEEL-BINDING-001 — placeholder

**Type:** Bug
**Status:** Queued

Body text.
