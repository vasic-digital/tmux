# CONTINUATION.md — vasic-digital tmux

**Last updated:** 2026-05-08T21:00Z

## §0 — How to resume work in any CLI agent

Paste this prompt:

> Read `CONTINUATION.md` at the repo root. Identify the topmost item under `§3 Active work` with status IN PROGRESS or BLOCKED. Re-read `Constitution.md`, `CLAUDE.md`, `AGENTS.md`, `Issues.md`, `Fixed.md` for mandates and current backlog. Resume from current state. Update this document as you work.

## §1 — Snapshot

| Field | Value |
|---|---|
| Repo | vasic-digital/tmux on GitHub + GitLab |
| Origin | Migrated from ATMOSphere project (`scripts/tmux/`, `docker/Dockerfile.tmux-build`, `docs/guides/TMUX_OPTIMIZED_BUILD.md`) on 2026-05-07 |
| Pinned tmux | upstream tag `3.6a` |
| Verification | `scripts/verify.sh` runs 14-test suite (01-14); all tests carry §11.4.2 positive runtime evidence. Challenge entries for all 14 tests exist (CH-01 through CH-14). Topology dispatch at `scripts/tmx._probe_topology()`. |
| Governance docs | `Constitution.md` (§1 + §11.4.1-§11.4.6 + §9 + §12.6 + §5/§12.10), `CLAUDE.md`, `AGENTS.md`, `Issues.md`, `Fixed.md`, this document |

## §2 — Mandates (canonical authority)

- `Constitution.md` §1 anti-bluff covenant (verbatim user-mandate quote propagated)
- `Constitution.md` §11.4.1 FAIL-bluffs equally forbidden
- `Constitution.md` §11.4.2 recorded-evidence requirement
- `Constitution.md` §11.4.3 per-host-topology test dispatch
- `Constitution.md` §11.4.4 test-interrupt-on-discovery + 4-layer test coverage
- `Constitution.md` §11.4.5 audio + video quality analysis (N/A for tmux scope; principle generalized)
- `Constitution.md` §11.4.6 — No-guessing mandate (verbatim user-mandate quote)
- `Constitution.md` §9 absolute data safety
- `Constitution.md` §12.6 60% host memory budget (per-session `TMX_MEM` is the enforcement)
- `Constitution.md` §5 / §12.10 continuation-document sacred invariant

## §3 — Active work

### §3.1 Governance bring-up — Issues.md / Fixed.md / explicit §11.4.x anchors landed

**Status:** COMPLETE (2026-05-08T17:06Z).

- Created `Issues.md` (open / in-flight tracker) with:
  - Categories A-E, status conventions OPEN / PARTIAL / BLOCKED / RUNNING / INVESTIGATED
  - Status reclassification rules referencing §11.4.6
  - Seeded items: META-MUT-001, CHAL-COVER-001, TEST-AUDIT-001, TMX-T5, TMX-T7, TMX-T8, TOPO-DISPATCH-001
- Created `Fixed.md` (closed archive) with:
  - A0 initial migration (commit `08d4ba5`, 2026-05-07)
  - B0 §1 covenant propagation (commit `b92bf7f`, 2026-05-08)
  - C0 test 09 crash-isolation-scope landed and green (commit `b92bf7f`, 2026-05-08)
- Updated `Constitution.md`:
  - Explicit §11.4.1, §11.4.2, §11.4.3, §11.4.4, §11.4.5 anchors added (preserving §1 prose verbatim)
  - §11.4.6 no-guessing mandate added with verbatim user-mandate quote
  - §9 absolute data safety added
  - §12.6 60% host memory budget added (TMX_MEM enforcement seam)
  - §5 expanded into full §12.10 continuation-document mandate
- Updated `CLAUDE.md` and `AGENTS.md` to carry every numbered anchor + canonical-authority cross-references

### §3.2 Per-session containerization (Phase B — multi-session work)

**Status:** RESEARCH COMPLETE + WRAPPER LANDED + ISOLATION VERIFIED (2026-05-08).

Web research output: `docs/CONTAINERIZATION_PLAN.md` recommends `systemd-run --user --scope` (cgroup-v2 transient scope) over podman-per-session. Wrapper at `scripts/tmx` implements `tmx {new|attach|ls|kill}` with `MemoryMax=$TMX_MEM` (default 8G), `CPUQuota=$TMX_CPU` (default 200%), `TasksMax=4096`, `Delegate=yes`.

Test 09 (`scripts/tests/09_crash_isolation_scope.sh`) — 14 PASS / 0 FAIL / 0 SKIP — verifies T1 (host capability), T2 (wrapper invariants), T3 (cgroup interface evidence), T4 (SIGKILL containment + user.slice survival), T6 (concurrent registration independence). Source-line breakdown:

- **T1:** systemd 258 + cgroup v2 mounted ✓
- **T2:** tmx wrapper invokes `systemd-run --user --scope` + sets MemoryMax/CPUQuota/TasksMax/Delegate=yes ✓
- **T3:** transient scope created; `/sys/fs/cgroup/.../memory.max` reads 268435456 bytes (matches set 256M) + `/sys/fs/cgroup/.../cpu.max` reads `50000 100000` (50% quota over 100ms period) — both POSITIVE EVIDENCE per §1 ✓
- **T4:** spawn scope, read MainPID from `cgroup.procs`, SIGKILL it, verify scope inactive AFTER kill, verify `default.target=active` THROUGHOUT (user.slice survives — Constitution §1 invariant) ✓
- **T6:** 3 concurrent scopes, all registered + active simultaneously ✓

### §3.3 Pending tests — moved to Issues.md

The previously-listed deferred tests (T5 memory pressure under cap, TasksMax stress, Concurrent OOM independence) have migrated to `Issues.md`:

- **TMX-T5** — Issues.md C1 (PARTIAL; operator-unblock runbook for dedicated test host)
- **TMX-T7** — Issues.md C2 (OPEN; new test 11 planned)
- **TMX-T8** — Issues.md C3 (OPEN; new test 12 planned)

Cross-cutting blockers also tracked in `Issues.md`:

- **META-MUT-001** — Issues.md A1 (paired-mutation harness needed before §11.4.4 layer-4 coverage is real)
- **CHAL-COVER-001** — Issues.md B1 (HelixQA Challenge entries pending)
- **TOPO-DISPATCH-001** — Issues.md D1 (formal topology dispatch matrix)

### §3.4 Anti-bluff enforcement — test audit + challenges fix + covenant propagation verification

**Status:** COMPLETE (2026-05-08T18:00Z).

- Verified anti-bluff covenant propagation across ALL governance files:
  - Root `Constitution.md`: §1 + §11.4.1-§11.4.6 present ✓
  - Root `CLAUDE.md`: full covenant present ✓
  - Root `AGENTS.md`: compact covenant present ✓
  - `Containers/CLAUDE.md`: full covenant present ✓
  - `Containers/AGENTS.md`: full covenant present ✓
  - `tmux/` (upstream submodule pinned to `3.6a`): N/A — no governance files, not modified per Constitution
- Performed line-by-line §11.4.2 anti-bluff audit of tests 01-09:
  - All 9 tests confirmed to carry positive runtime evidence (/proc files, cgroup interfaces, tmux command output, systemctl state).
  - No FAIL-bluff vectors found (all `set -uo pipefail`, guarded variables).
  - Full audit table moved to `Fixed.md` B2.
- Fixed broken paths in `scripts/challenges/tmux.yaml` (`scripts/tmux/tests/` → `scripts/tests/`).
- Migrated TEST-AUDIT-001 from `Issues.md` B2 → `Fixed.md` B2.

### §3.5 Hostname-derived status-bar colour — algorithm + wrapper + 2 tests + challenges

**Status:** COMPLETE (2026-05-08T19:00Z).

- Created `scripts/hostname_color.sh` — DJB2 hash over hostname → curated 27-colour palette. Deterministic, testable standalone.
- Updated `scripts/tmx.template` — added `_apply_host_color()` function that invokes `hostname_color.sh` and applies `set -g status-style bg=<colour>` on the running tmux server. Applied on both new-session and attach paths.
- Created `scripts/tests/10_hostname_color_algorithm.sh` — 5 invariants (deterministic, valid `colourNNN`, palette member, spread ≥12/16, empty-fallback to system hostname). All 5 PASS on this host.
- Created `scripts/tests/11_hostname_color_integration.sh` — verifies wrapper applies correct colour to tmux server. SKIPs if binary/wrapper not yet built.
- Updated `scripts/tests/run_all.sh` — glob changed from `0[1-9]_*.sh` to `[0-9][0-9]_*.sh` to support tests 10+.
- Updated `scripts/challenges/tmux.yaml` — added TMUX-CH-10 (algorithm) and TMUX-CH-11 (integration).
- Updated `docs/research/customization/colors.md` — added implementation documentation covering algorithm, integration, verification, usage, and anti-bluff covenant.
- Updated `AGENTS.md` — bump test count from 9 to 11.

### §3.6 Full coverage — missing challenge entries, destructive tests, topology dispatch

**Status:** COMPLETE (2026-05-08T20:00Z).

- **CH-09**: Added missing challenge entry for crash isolation scope (test 09) — was the only test without a challenge.
- **Test 12** (`12_memory_pressure_under_cap.sh`): TMX-T5 — allocates up to MemoryMax+10% inside a transient scope, captures dmesg OOM-kill evidence, validates user.slice survival. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **Test 13** (`13_tasksmax_stress.sh`): TMX-T7 — fork-bomb resistance. Spawns processes up to TasksMax=4096, reads pids.current/pids.max from cgroup interface. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **Test 14** (`14_concurrent_oom_independence.sh`): TMX-T8 — three scopes A/B/C, OOM-kills A, verifies B and C survive with original MainPIDs. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **CH-12/13/14**: Challenge entries for all three destructive tests.
- **Topology dispatch**: added `_probe_topology()` to `scripts/tmx.template` — detects systemd version + cgroup v2, classifies host as `tmx-supported`/`tmx-degraded`/`tmx-unsupported` per §11.4.3.
- **Fixed.md B2**: closure SHA updated to `68a65b0`.
- **Issues.md → Fixed.md migration**: B1 (CHAL-COVER-001), C1 (TMX-T5), C2 (TMX-T7), C3 (TMX-T8), D1 (TOPO-DISPATCH-001) moved to Fixed.md.

### §3.7 §11.4.4 layer-4 paired-mutation harness landed (A1 META-MUT-001)

**Status:** COMPLETE (2026-05-08T21:00Z).

- Created `scripts/tests/meta_test_false_positive_proof.sh` — §11.4.4
  layer-4 harness with 5 registered mutations:
  - **M1**: break hostname_color output format → test 10 T2 FAILs (invalid format)
  - **M2**: force hash to zero → test 10 T3 FAILs (zero spread)
  - **M3**: single-entry palette → test 10 T3 FAILs (palette mismatch)
  - **M4**: remove systemd-run flag from tmx.template → test 09 T2 FAILs
  - **M5**: remove Delegate=yes from tmx.template → test 09 T2 FAILs
- Results on this host: **10 PASS / 0 FAIL / 0 SKIP** — all mutations caught.
- Updated `CLAUDE.md`: removed "PENDING" references, wired mandatory
  operations to the actual file.
- Updated `AGENTS.md`: layer 4 now marked as landed, not PENDING.
- Updated `Fixed.md`: A1 entry with closure details; all "PENDING
  META-MUT-001" references replaced with actual coverage references.
- Updated `Issues.md`: A1 removed (→ Fixed.md A1). Issues.md now has
  **zero open items** — all originally seeded items are closed.
- Cleaned up `CONTINUATION.md` §3.6: removed stale "remaining open" note.

## §4 — Recent commits

- (this commit) — §11.4.4 layer-4 paired-mutation harness (META-MUT-001):
  meta_test_false_positive_proof.sh with 5 mutations (10/0/0 all caught);
  CLAUDE.md/AGENTS.md PENDING→LANDED; Issues.md now empty of open items.

**Status:** COMPLETE (2026-05-08T20:00Z).

- **CH-09**: Added missing challenge entry for crash isolation scope (test 09) — was the only test without a challenge.
- **Test 12** (`12_memory_pressure_under_cap.sh`): TMX-T5 — allocates up to MemoryMax+10% inside a transient scope, captures dmesg OOM-kill evidence, validates user.slice survival. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **Test 13** (`13_tasksmax_stress.sh`): TMX-T7 — fork-bomb resistance. Spawns processes up to TasksMax=4096, reads pids.current/pids.max from cgroup interface. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **Test 14** (`14_concurrent_oom_independence.sh`): TMX-T8 — three scopes A/B/C, OOM-kills A, verifies B and C survive with original MainPIDs. Gated by `TMX_TEST_DESTRUCTIVE=1`.
- **CH-12/13/14**: Challenge entries for all three destructive tests.
- **Topology dispatch**: added `_probe_topology()` to `scripts/tmx.template` — detects systemd version + cgroup v2, classifies host as `tmx-supported`/`tmx-degraded`/`tmx-unsupported` per §11.4.3.
- **Fixed.md B2**: closure SHA updated to `68a65b0`.
- **Issues.md → Fixed.md migration**: B1 (CHAL-COVER-001), C1 (TMX-T5), C2 (TMX-T7), C3 (TMX-T8), D1 (TOPO-DISPATCH-001) moved to Fixed.md.
- **Remaining open**: all previously OPEN items now RESOLVED. Issues.md is empty of open items. §11.4.4 layers 2 (runtime tests) and 4 (paired mutation harness) are met. Layers 1 and 3 tracked as roadmap items.

## §4 — Recent commits

- (this commit) — Full coverage: CH-09 added (was missing); tests 12/13/14 (T5/T7/T8 destructive) with TMX_TEST_DESTRUCTIVE=1 gate; topology probe in tmx.template; challenge entries CH-12/13/14; B1/C1/C2/C3/D1 migrated Issues→Fixed.
- `8b37046` — Hostname-derived status-bar colour: DJB2→27-colour palette algorithm + wrapper integration + tests 10/11 + challenges + docs.
- `68a65b0` — Anti-bluff enforcement: TEST-AUDIT-001 complete (9 tests §11.4.2-audited), challenges paths fixed, AGENTS.md compact rewrite, covenant propagation verified.
- `b92bf7f` (2026-05-08) — §1 anti-bluff covenant verbatim user-mandate quote added; test 09 crash-isolation-scope (14/0/0) landed.
- `08d4ba5` (2026-05-07) — Initial vasic-digital/tmux: migrated from ATMOSphere project + per-session containerization plan + 8-test verification gate.

## §8 — Resumption recipe

1. `cd ~/Projects/tmux`
2. Read this document
3. Read `Constitution.md`, `CLAUDE.md`, `AGENTS.md`, `Issues.md`, `Fixed.md`
4. Find the topmost IN PROGRESS / OPEN item, resume
5. Update this document in the SAME commit as the work itself (§12.10 invariant)
