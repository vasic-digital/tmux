# CONTINUATION.md — vasic-digital tmux

**Last updated:** 2026-05-13T00:00Z

## §0 — How to resume work in any CLI agent

Paste this prompt:

> Read `CONTINUATION.md` at the repo root. Identify the topmost item under `§3 Active work` with status IN PROGRESS or BLOCKED. Re-read `Constitution.md`, `CLAUDE.md`, `AGENTS.md`, `Issues.md`, `Fixed.md` for mandates and current backlog. Resume from current state. Update this document as you work.

## §1 — Snapshot

| Field | Value |
|---|---|
| Repo | vasic-digital/tmux on GitHub + GitLab |
| Origin | Migrated from ATMOSphere project (`scripts/tmux/`, `docker/Dockerfile.tmux-build`, `docs/guides/TMUX_OPTIMIZED_BUILD.md`) on 2026-05-07 |
| Pinned tmux | upstream tag `3.6a` |
| Verification | `scripts/verify.sh` runs 14-test suite (01-14); GREEN on this host (PASS=10 FAIL=0 SKIP=4: OOM helper + 3 destructive). Binary built (`tmux 3.6a`). tmx wrapper implements systemd-run --user --scope wrapping. Topology dispatch via functional probe. |
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

### §3.8 Audit cycle 2026-05-13 — submodule pin-drift caught + governance staleness fixed

**Status:** COMPLETE (2026-05-13T00:00Z).

Triggering event: user invoked `/init` followed by "what is left unfinished, no-bluff policy heavily enforced everywhere". Audit found and remediated:

- **CRITICAL §1 / §11.4.6 bluff**: `f4132aa Auto-commit` (2026-05-13) silently bumped tmux submodule from `cc117b5` (tag `3.6a`) to `3f651d9f` (`3.6a-329-g3f651d9f` — 329 commits past the only stable tag). Governance docs across Constitution / CLAUDE / AGENTS / CONTINUATION / README still claimed "pinned to tag 3.6a". User decision: revert to tag (newer stable tag does not exist; 329 commits are unreleased upstream master). Submodule pointer reverted to `cc117b5`.
- **README.md staleness**: line 5 ("eight verification tests"), line 33 (`PASS=6 FAIL=0 SKIP=2`), line 37 ("8 tests cover"), line 39 (2-SKIP list) — all rewritten to current 14-test / PASS=10 SKIP=4 / 4-SKIP-list state with explicit `TMX_TEST_DESTRUCTIVE=1` callout and §11.4.4 layer-4 harness reference.
- **CLAUDE.md drift**: added top-of-file project summary + canonical-doc cross-links + fresh-conversation workflow; fixed `0N_*.sh` glob → `NN_*.sh`; named the four layers inline in the Test-interrupt rule; added "Files to never edit directly" section (parity with AGENTS.md).
- **AGENTS.md drift**: mirrored CLAUDE.md project summary + cross-links; fixed same `0N_*.sh` glob bug; added meta-test row to commands table.
- **Issues.md format**: restored A / B / C / D / E section headers as empty sections (was: A / B / E only, with C and D missing despite conventions list referencing them). All bodies note "landed in `Fixed.md`" with item IDs for traceability.
- **CONTINUATION.md timestamp**: 2026-05-08T22:00Z → 2026-05-13T00:00Z; this entry added under §3.8 per §12.10 invariant.
- **M6 mutation added** (`scripts/tests/meta_test_false_positive_proof.sh`): injects `$$` into the hostname_color hash, making the algorithm non-deterministic per-invocation. Test 10 T1 must FAIL under this mutation. Closes the audit-flagged gap: until M6, the "same-host = same-color" user invariant was protected by side-effect only (no dedicated anti-randomness mutation).
- **`docs/GUIDE.md` phantom-script bluff fixed**: 3 occurrences each of `verify_tmux.sh` → `verify.sh`, `setup_tmux.sh` → `setup.sh`, `install_tmux_deps.sh` → `install_deps.sh`; "8 tests" → "14 tests" (2×).
- **GUIDE.md "severity hierarchy" pre-existing bluff caught** (Fixed.md A3): documented "blockers / critical / advisory" classification does not exist in `run_all.sh` — every test is treated equally (any FAIL = RED). Rewritten to describe the actual gate logic. Caught while extending the table for tests 09-14; would have been silently doubled otherwise.
- **Install-mechanism side-by-side bluffs** (Fixed.md A6): user asked about the alias and side-by-side coexistence requirement. Audit found three real defects:
  - bashrc snippet pointed PATH at `scripts/tmux/` (phantom subdir; wrapper is at `scripts/tmx`).
  - `alias tmux='tmx'` line shadowed the system tmux command → broke side-by-side.
  - setup.sh closing message said "Then 'tmux' will use the ATMOSphere build" (wrong command name + stale branding).
  - **Canonical answer to user's question**: the alias is **`tmx`** (not `tmux`). Wrapper at `scripts/tmx` generated from `tmx.template`. `tmx new|attach|ls|kill` invokes the verified vasic-digital tmux; `tmux` invokes whatever was on the operator's PATH before (system / Homebrew / apt / dnf). Both coexist.
- **Full destructive + meta-test cycle caught 6 more FAIL-bluffs** (Fixed.md A5): pushing past PASS=10 SKIP=4 into actually running TMX_TEST_DESTRUCTIVE=1 + meta-test in the podman machine VM (Fedora CoreOS 42 + systemd 257 + stress-ng + tmx-oom-set setcap) surfaced multiple §11.4.1 FAIL-bluffs. Final: **PASS=14 FAIL=0 SKIP=0** (full verify) + **12/12 mutations caught** (meta-test). Real defects fixed:
  - Tests 12/14 `_skip;<continue>` bug — printed SKIP but didn't exit; continued running and FAILed on missing stress-ng → false §11.4.1 FAIL-bluff. Fix: explicit `exit 0`.
  - Tests 12/14 unprivileged dmesg → fallback to journalctl -k via `_kring_count` / `_kring_tail` helpers; broader OOM regex.
  - Test 13 fork-storm OOM-killed its own scope (4096 sleeps × 700KB > 256M MemoryMax); two-phase scope, polling registration, test TASKS_MAX 4096→256 with MemoryMax=512M (production wrapper still TasksMax=4096 — separately grep-verified by test 09 T2.2).
  - Meta-test `sed -i` strip-exec-bit → orig_mode capture/restore via stat + chmod.
  - Meta-test M5 sed pattern was eval-expanded (`${TMX_MEM:-8G}` → `8G`) so it never matched → silent no-op → mutation escaped (a **bluff in the gate itself**). Fix: simplified to literal `MemoryMax=|MemMax=` pattern.
  - Meta-test had no debug visibility → added opt-in `TMX_META_DEBUG=1`.
  - **The user's "same-host = same-color" invariant is now PROVEN end-to-end** with `tmux show -g status-style` reading `colour166` on first session AND on second session on same host (test 11 T4.1 + T5).
- **Build pipeline bluffs caught while reproducing on macOS** (Fixed.md A4): three real defects surfaced when user asked why we couldn't build on macOS:
  - `docker/Dockerfile`: `groupadd -g 20` collided with Ubuntu's `dialout` group → build aborted at step 7/10. Fix: `-o` (non-unique) on groupadd + useradd. Build now reproducible on Darwin hosts.
  - `docker/build_inside_container.sh`: LDFLAGS `-ljemalloc` was being dropped by linker's default `--as-needed` because tmux doesn't reference jemalloc symbols. **README's "Build-time -ljemalloc" claim was a §1 bluff until this commit.** Fix: `-Wl,--no-as-needed -ljemalloc -Wl,--as-needed`. Verified `ldd` now shows `libjemalloc.so.2` in DT_NEEDED.
  - `docker/build_inside_container.sh`: `make -j2` silently no-op'd after LDFLAGS change (existing binary defeated mtime check). Fix: prepend `make clean` so LDFLAGS changes always take effect.

The `f4132aa Auto-commit` itself is a §12.10 / §11.4.6 violation — opaque commit message, silent submodule mutation, no CONTINUATION update. Cannot rewrite history per §9 data safety; documenting here is the audit trail.

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

- (this commit, 2026-05-13) — Audit cycle: tmux submodule reverted from `3f651d9f` to `cc117b5` (3.6a tag) after silent pin-drift caught; README.md test-count + PASS/SKIP staleness fixed (8→14 tests, PASS=6→10, SKIP=2→4); CLAUDE.md + AGENTS.md gained project summary, cross-links, fresh-conversation workflow, `NN_*.sh` glob fix, named four layers, "Files to never edit directly"; Issues.md restored A/B/C/D/E section headers; CONTINUATION.md §3.8 + timestamp refresh per §12.10. See §3.8.
- `f4132aa` — Auto-commit: opaque submodule bumps (Containers `e377dea`→`af51968` legitimate upstream governance; tmux `cc117b5`→`3f651d9f` reverted in this commit). §12.10 / §11.4.6 violation documented in §3.8.
- (previous commit) — §11.4.4 layer-4 paired-mutation harness (META-MUT-001):
  meta_test_false_positive_proof.sh with 5 mutations (10/0/0 all caught);
  CLAUDE.md/AGENTS.md PENDING→LANDED; Issues.md now empty of open items.
  Also: fixed 5 broken script references (REPO_ROOT wrong depth, filenames);
  implemented systemd-run --user --scope wrapping in tmx.template;
  test 09 topology dispatch fixed (functional probe, not mount grep);
  CLAUDE.md compacted to match AGENTS.md; binary built and verified GREEN
  (PASS=10 FAIL=0 SKIP=4: OOM helper + 3 destructive).
- `39284ab` — Full coverage: CH-09 added (was missing); tests 12/13/14 (T5/T7/T8 destructive) with TMX_TEST_DESTRUCTIVE=1 gate; topology probe in tmx.template; challenge entries CH-12/13/14; B1/C1/C2/C3/D1 migrated Issues→Fixed.
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
