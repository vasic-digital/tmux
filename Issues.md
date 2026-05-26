# vasic-digital tmux — Open Issues Tracker

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

(none open at this time — A1 META-MUT-001 landed in `Fixed.md`.)

---

## B. Anti-bluff completeness across the existing test surface

### B3. P5-M20 + P5-M21 paired-mutation ESCAPES — pre-existing v1.0.9 layer-4 gaps — `OPEN`

**Status:** `OPEN` — pre-existing from v1.0.9 (shell-session-resume PWUs).
**Re-discovered:** v1.0.14 verification cycle, 2026-05-22 on Mistborn:
`bash scripts/tests/meta_test_false_positive_proof.sh` reports
`MUTATIONS CAUGHT (PASS): 39  MUTATIONS ESCAPED (FAIL): 2  SKIPPED: 8`.

**Forensic detail (no guessing per §11.4.6):**

- **P5-M20** ("strip non-TTY guard from tmx-shell-init.sh"): the
  mutation removes the explicit non-TTY guard from
  `scripts/tmx-shell-init.sh`. The target test still exits fast
  because Darwin / libc enforces POSIX TTY semantics that ALSO cause
  the script to early-exit on non-TTY stdin (the test sees
  `Darwin: POSIX TTY semantics enforced by libc iter=N elapsed_ms<100`).
  The TEST verifies the END behaviour ("script exits fast") but the
  END behaviour is defended on TWO layers (script guard + libc
  semantics) and the test cannot distinguish which layer caught it.
  Mutation strips one layer; the other still saves the assertion.
- **P5-M21** ("strip cwd-capture tmux hook block from tmx.template"):
  the mutation removes the hook installation from the generated
  wrapper, but the target test (test 18 cwd persistence end-to-end)
  passes anyway because its harness manually triggers the hook via
  `tmux run-shell` — bypassing the template's auto-install. The test
  proves the recall MECHANISM works, never that the auto-install
  RECORDING path works.

**Why this is `OPEN`, not closed-by-disclosure:** the FEATURES under
test (shell-init non-TTY skip, cwd persistence) do work and are
covered by the GREEN tests 18, 21, 43. The escape is a layer-4
test-DESIGN gap — the test assertions cannot distinguish "guard
fired" from "fallback fired", so the mutation slips. Fixing requires
tightening the test assertions to isolate the layer the mutation
targets (e.g. test 21 should drive a build where the libc fallback
is intentionally disabled; test 18 should drive ONLY the auto-install
path without manually triggering the hook). Both require careful
re-architecting of the test harnesses, not a one-line change.

**Why not blocker for v1.0.14:** these escapes have been present
across v1.0.9 → v1.0.13 releases; the operative request for
v1.0.14 (clipboard physical proof + multi-host deploy) is fully
covered with GREEN tests and physical evidence. Test 44 + M44 close
the cycle's own anti-bluff cycle cleanly. Transparency in the
release notes per §11.4 / §101.

**Companion finding — nezha environmental escape (M22):** on nezha,
the meta-test additionally reports `M22 MUTATION ESCAPED` AND `V3
does not PASS after revert`. M22 targets the CodeGraph
`Containers/**` exclude path in `.codegraph/config.json`. Both the
mutate-and-test-fail step and the revert-and-test-pass step fail —
indicating the CodeGraph validate baseline itself is broken on
nezha (the test cannot reach GREEN even with original config). This
is an environmental state issue (CodeGraph index/config) on the
remote host, not a v1.0.14 regression. Closure condition: bring
nezha's CodeGraph state to the baseline `codegraph_validate` would
PASS on; either re-run `bash scripts/codegraph_setup.sh` on nezha
or document why M22 should SKIP on nezha-class hosts.

**Closure conditions:** test 21 design tightening so it specifically
asserts the SCRIPT GUARD fired (not the libc fallback); test 18
re-architecture so it does NOT short-circuit the hook auto-install.
Both close P5-M20 and P5-M21 in the meta-test in a future cycle.

---

(no other items open at this time — B1 CHAL-COVER-001, B2 TEST-AUDIT-001 landed in `Fixed.md`.)

---

## C. Per-session containerization features pending evidence

(none open at this time — C1 TMX-T5, C2 TMX-T7, C3 TMX-T8 landed in `Fixed.md`.)

---

## D. Host-capability + topology dispatch gaps

(none open at this time — D1 TOPO-DISPATCH-001 landed in `Fixed.md`.)

---

## E. Documentation / Continuation drift

(none open at this time; CONTINUATION.md §3 entries that resolve land in `Fixed.md` per Constitution §5 / §12.10.)

---

**Last reviewed:** 2026-05-22 (v1.0.14 cycle — clipboard physical-proof landing + multi-host deploy; opened B3 to track the pre-existing v1.0.9 P5-M20+P5-M21 layer-4 escapes transparently).
