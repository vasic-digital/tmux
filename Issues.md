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

### A1. Meta-test paired-mutation harness — `OPEN`

* **State:** the constitution-level §1 covenant requires every gate to
  have a paired mutation that proves the gate catches regressions. This
  repo has 8 functional tests + test 09 (crash-isolation-scope) but no
  `meta_test_*.sh` harness yet. CLAUDE.md / AGENTS.md already reference
  the pattern ("when that file exists in v2") — promised, not landed.
* **Captured-evidence requirement:** for every test under
  `scripts/tests/`, a paired mutation must mutate the test source (or
  the wrapper / scope settings) so the test FAILs, then restore and
  prove the test PASSes. Mutation must use the same
  `LIKELY`-forbidden vocabulary discipline as §11.4.6.
* **Fix-direction proposal:** create
  `scripts/tests/meta_test_false_positive_proof.sh` mirroring the
  ATMOSphere pattern. Start with mutations against test 09 (rename
  `MemoryMax=` literal in `scripts/tmx`, assert T2 invariant FAILs;
  mutate the wrapper to skip `systemd-run --user --scope`, assert T3
  cgroup-readback FAILs).
* **Tracked task ID:** META-MUT-001.

---

## B. Anti-bluff completeness across the existing test surface

### B1. HelixQA Challenge entries for the per-session containerization model — `OPEN`

* **State:** CONTINUATION.md §3.3 listed Challenge coverage as
  pending. Tests 01-09 produce on-host runtime evidence; HelixQA
  Challenge entries that mirror the same expectations have not been
  written.
* **Captured-evidence requirement (§11.4.2 + §11.4.4):** each
  Challenge must independently exercise the user-visible path
  (`tmx new <session>`, attach, run a workload, kill the scope, verify
  sibling scope unaffected) and capture the same forensic artifacts
  the test suite captures (transient-scope `cgroup.procs`,
  `memory.max` readback, `default.target=active` throughout).
* **Fix-direction proposal:** add a `scripts/challenges/`
  README enumerating Challenge slugs (one per test) and wire them to
  the host-side runner the operator already uses.
* **Tracked task ID:** CHAL-COVER-001.



---

## C. Per-session containerization features pending evidence

### C1. T5 — Memory pressure under cap (actual allocation up to MemoryMax) — `PARTIAL`

* **State:** Test 09 covers T1/T2/T3/T4/T6. T5 (allocate-and-trigger-OOM
  inside the scope, verify enforcement, verify only the scope dies)
  was deferred from the 2026-05-08 cycle as risky on the operator's
  shared host. T3 already proves `memory.max` is set correctly via
  `/sys/fs/cgroup/.../memory.max` readback — that is positive
  evidence the kernel honors the cap. T5 is the live-fire variant.
* **Captured-evidence requirement:** stress-allocate inside the scope
  using `stress-ng --vm 1 --vm-bytes <MemoryMax+10%>`; capture
  `dmesg | grep -i 'oom-kill'` showing the kernel killed the scope
  (not user.slice); verify `systemctl --user status default.target`
  reads `active` after the kill.
* **Fix-direction proposal:** new test
  `scripts/tests/10_memory_pressure_under_cap.sh` runnable on a
  dedicated test host (not the operator's daily-driver). Gate with
  `TMX_TEST_DESTRUCTIVE=1` env-var to prevent accidental local runs.
* **Operator-unblock runbook:**
  1. Set up a dedicated VM or spare physical host (any Linux distro
     with systemd v240+ and cgroup v2).
  2. Clone repo, `bash scripts/setup.sh`.
  3. `TMX_TEST_DESTRUCTIVE=1 bash scripts/tests/10_memory_pressure_under_cap.sh`.
  4. Capture `dmesg` output to `evidence/T5-<host>-<date>.log`.
  5. Move to `Fixed.md` with the captured-evidence path on green.
* **Tracked task ID:** TMX-T5.

### C2. T7 — TasksMax stress (fork-bomb resistance) — `OPEN`

* **State:** the wrapper sets `TasksMax=4096`. No test verifies that
  a fork-bomb inside the scope is contained at 4096 processes
  without leaking outside the scope.
* **Captured-evidence requirement:** spawn forks inside the scope
  until `TasksMax` is hit; capture
  `/sys/fs/cgroup/.../pids.current` reading 4096; capture
  `/sys/fs/cgroup/.../pids.max` reading 4096; verify
  `systemctl --user status default.target` reads `active` throughout.
* **Fix-direction proposal:** new test
  `scripts/tests/11_tasksmax_stress.sh`. Same `TMX_TEST_DESTRUCTIVE=1`
  gate as T5.
* **Tracked task ID:** TMX-T7.

### C3. T8 — Concurrent OOM independence — `OPEN`

* **State:** T6 in test 09 covers the registration-side concurrency
  (3 scopes registered + active simultaneously). It does NOT test
  the failure-mode independence (one scope OOMs → siblings
  unaffected) which is the actual user-visible isolation claim.
* **Captured-evidence requirement:** spawn scopes A + B + C; trigger
  OOM in A by allocating > MemoryMax_A; capture `dmesg` showing
  scope-A-only kill; capture `systemctl --user list-units` showing B
  and C still active; capture each surviving scope's
  `cgroup.procs` reading the original MainPID.
* **Fix-direction proposal:** new test
  `scripts/tests/12_concurrent_oom_independence.sh`. Same destructive
  gate.
* **Tracked task ID:** TMX-T8.

---

## D. Host-capability + topology dispatch gaps

### D1. Per-host-topology dispatch (Constitution §11.4.3 adapted) — `PARTIAL`

* **State:** the wrapper at `scripts/tmx` performs a one-time check
  for systemd v240+ and cgroup v2 mount. Test 09 T1 verifies the
  capability. There is no formal dispatch matrix that records:
  - Distro family (Debian / Fedora / Arch / Ubuntu)
  - systemd version range
  - cgroup version (v1 hybrid / v2 unified)
  - kernel cgroup-v2 controller availability (memory, cpu, pids)
  Tests on a host that lacks any of these MUST SKIP-with-reason,
  not silently degrade to no-isolation.
* **Captured-evidence requirement:** for each tested topology,
  archive the `systemctl --version`, `mount | grep cgroup`,
  `cat /sys/fs/cgroup/cgroup.controllers` outputs into
  `evidence/topology-<host>-<date>.txt`.
* **Fix-direction proposal:** add a `host_topology_probe()` function
  to `scripts/tmx` that records the matrix and emits a single line
  classifying the host (`tmx-supported` / `tmx-degraded` /
  `tmx-unsupported`). Tests dispatch on this classification.
* **Tracked task ID:** TOPO-DISPATCH-001.

---

## E. Documentation / Continuation drift

(none open at this time; CONTINUATION.md §3 entries that resolve land in `Fixed.md` per Constitution §5 / §12.10.)

---

**Last reviewed:** 2026-05-08 (anti-bluff enforcement cycle).
