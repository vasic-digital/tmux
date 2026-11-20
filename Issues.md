# vasic-digital tmux — Open Issues Tracker

**Revision:** 1
**Last modified:** 2026-11-20T00:00:00Z

> **Canonical source of truth for everything currently unfinished, partially
> validated, or at risk of violating the anti-bluff covenant
> (`Constitution.md` §1 + §11.4.1 through §11.4.6).**
>
> Every PASS in this codebase MUST carry positive evidence captured live
> that the feature works for the end user. Metadata-only PASS,
> configuration-only PASS, "absence-of-error" PASS, and grep-based PASS
> without runtime evidence are all critical defects regardless of how
> green the summary line looks. **Tests AND HelixQA Challenges are bound
> equally.**
>
> Forensic anchor — direct user mandate (verbatim, 2026-04-28 +
> 2026-05-07 + 2026-05-08, repeatedly reasserted from upstream
> `vasic-digital` projects):
>
> > "We had been in position that all tests do execute with success
> > and all Challenges as well, but in reality the most of the
> > features does not work and can't be used! This MUST NOT be the
> > case and execution of tests and Challenges MUST guarantee the
> > quality, the completion and full usability by end users of the
> > product!"
>
> §11.4.6 forensic anchor (verbatim, 2026-05-08):
>
> > "'LIKELY' is guessing, we MUST NOT have guessing, since it can
> > be or may not be! No bluffing and uncertainity is allowed at any
> > cost! We MUST always know exactly precisly what is happening
> > exactly, in any context, under any conditions, everywhere!"

**Compiled:** 2026-05-08 (Phase B per-session-containerization cycle).
**Author:** Engineering coordinator
**Working pool source:** the items below feed the active task list directly.
Each item carries a current state, the captured-evidence requirement,
and a fix-direction proposal so future-self can resume cold.

> **Migration policy** (mirrors upstream `vasic-digital` projects):
> resolved items are moved to **[`Fixed.md`](Fixed.md)** in the same
> commit that closes them. **`Issues.md` holds OPEN / PARTIAL /
> BLOCKED / RUNNING / INVESTIGATED only**; once an item is closed and
> verified end-to-end, it migrates to `Fixed.md` and disappears from
> here. Never delete items outright — history matters for cold-start
> handover.

---

## Document conventions

| Code | Meaning |
|---|---|
| `OPEN` | Unfinished work; needs implementation + anti-bluff coverage |
| `PARTIAL` | Implementation exists but coverage gaps remain (positive evidence missing or environmental SKIP unresolved) |
| `BLOCKED` | Cannot progress without external dependency (host capability, third-party tool, distro support, etc.) |
| `RUNNING` | In-flight in this session (background process, ongoing test cycle) |
| `INVESTIGATED` | Forensic investigation produced findings; closure pending decision on fix scope |

**Status reclassification rules (§11.4.6 enforced):**

- A `PARTIAL` may not move to closed without runtime evidence
  (`/sys/fs/cgroup/.../memory.max` readback, `systemctl status` showing
  scope active, `kill -9` survivor proof — never just script exit code).
- A `BLOCKED` reclassifies to `OPEN` when the blocking dependency
  resolves; it must NOT skip directly to closed.
- An `INVESTIGATED` item must record the captured forensic trace
  (file path / command output / log timestamp) — never speculation
  ("likely" / "probably" / "appears to" — see Constitution §11.4.6).

Categories:

* **A** — Tooling / harness gaps
* **B** — Anti-bluff completeness across the existing test surface
* **C** — Per-session containerization features pending evidence
* **D** — Host-capability + topology dispatch gaps
* **E** — Documentation / Continuation drift

---

## A. Tooling / harness gaps

---

---

---

---

---

## B. Anti-bluff completeness across the existing test surface

(Prior B-items closed: B3 P5-M20/P5-M21 escapes CLOSED in v1.0.16
[tests 49/50 + meta-test retarget], state-verified 2026-05-29 with
`MUTATIONS CAUGHT 45 / ESCAPED 0`, migrated to `Fixed.md` §B3 as TMX-054;
B1 CHAL-COVER-001, B2 TEST-AUDIT-001 also in `Fixed.md`. New open work below.)

---

## C. Per-session containerization features pending evidence

(none open at this time — C1 TMX-T5, C2 TMX-T7, C3 TMX-T8 landed in `Fixed.md`.)

---

## D. Host-capability + topology dispatch gaps

---

## E. Documentation / Continuation drift

(CONTINUATION.md §3 entries that resolve land in `Fixed.md` per Constitution §5 / §12.10. New open work below.)

---

## F. Runtime crash — operator-gated reproduction

(none open — F1 `tmx` session named "HelixCode" crashes the whole terminal RESOLVED 2026-06-13, operator-confirmed, migrated to `Fixed.md` A45 with reproduced root cause [stale wrapper `TMUX_BIN` pointing at a non-existent prior-checkout path → `exec` of missing binary → login shell dies → terminal closes] + 4-layer regression guard [test 60 + verify gate `CM-TMX-WRAPPER-TMUXBIN-VALID` + meta `M-WRAPPER-TMUXBIN`]).

---

**Last reviewed:** 2026-06-19 (v1.0.27 WIP burn-down. §11.4.138 operator-escape A51
[name:color prompt rejection] FIXED — shell-init + SSH-dispatcher char-set now
allows `:` and `#`, max-length 64→80; test 65 operator-escape guard PASS=6/6.
M24/A2/D2 in parallel streams per §11.4.103.)

---

## G. Interactive wizard + session-password redesign (2026-07-05)

New OPEN work from the 14-task wizard + session-password redesign plan
(`docs/superpowers/plans/2026-07-05-tmx-wizard-password-redesign.md`; spec
`docs/superpowers/specs/2026-07-05-tmx-wizard-password-redesign-design.md`).
Code lands across sibling tasks of that plan; these four entries track the
four user-visible requirements from the operator mandate (random-suffix
create, masked password input, single-prompt reopen, existing-session
picker).

**Section closed 2026-09-01.** All five entries have landed and now live in
`Fixed.md`: G1/TMX-072, G2/TMX-073, G3/TMX-074, G4/TMX-075 (the four listed
above) and the session-name sanitization work as §A55/TMX-078. Their blocks
were duplicated here while they were also in `Fixed.md`; the duplicates were
retired on operator decision so each item has exactly one block. The heading
is kept for the historical context above — it is deliberately empty of items,
not missing them.

---

## H. Pre-existing timing issues surfaced during the 2026-08-10 no-limits-by-default cycle

Discovered while validating TMX-079 (see `Fixed.md`). Confirmed via §11.4.114
A/B isolation against the v1.0.38 baseline (identical failures reproduced
BEFORE any of TMX-079's changes were applied) — NOT caused by TMX-079, and
TMX-079's own fix + tests are unaffected. Tracked here so they are not lost.

---

## I. Live copy-mode wheel binding (2026-09-01)

Surfaced during the v1.0.44 verification work. Tracked here because it is a real, currently-failing check that was not previously recorded anywhere — leaving it only in a test log would be a §11.4.238 coverage escape at the tracking layer.
