# Issues — FIXTURE golden-BAD: the ACTUAL 2026-09-01 over-deletion

Reproduces the historical defect verbatim in shape: an ad-hoc removal loop
asked to delete the four `### G1..G4` item blocks ran past the last one and
swallowed everything up to the next `###` heading — which meant the `## H.`
SECTION HEADER and that section's §11.4.114 preamble went with them. The
`### H1` item survives, now orphaned under `## G.`.

The gate MUST FAIL on this file (A1: section H vanished; A3 would also have
fired had H survived with a gutted preamble).

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
