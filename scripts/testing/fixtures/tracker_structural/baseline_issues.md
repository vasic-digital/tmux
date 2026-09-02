# Issues — FIXTURE baseline (mirrors the real pre-repair shape of Issues.md)

This fixture reproduces the structural shape of `Issues.md` immediately
before the 2026-09-01 corpus repair (commit 8dad4e3). It is deliberately
abridged: only the sections and the preamble text that the historical
defect touched are kept, in their real relative order.

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

### G1 WIZARD-SUFFIX-001 — wizard-created sessions get a random 4-digit name suffix

**Type:** Feature
**Status:** Implemented (→ Fixed.md)

Body text.

### G2 PASSWORD-MASK-001 — password input is masked with asterisks while typing

**Type:** Feature
**Status:** Implemented (→ Fixed.md)

Body text.

### G3 DOUBLE-PROMPT-001 — reopening a password-protected session no longer asks twice

**Type:** Bug
**Status:** Fixed (→ Fixed.md)

Body text.

### G4 WIZARD-PICKER-001 — wizard offers a picker of existing sessions

**Type:** Feature
**Status:** Implemented (→ Fixed.md)

Body text.

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
