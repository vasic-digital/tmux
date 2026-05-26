# CONTINUATION.md — vasic-digital tmux

**Last updated:** 2026-05-22T15:00Z

## §0 — How to resume work in any CLI agent

Paste this prompt:

> Read `CONTINUATION.md` at the repo root. Identify the topmost item under `§3 Active work` with status IN PROGRESS or BLOCKED. Re-read `Constitution.md`, `CLAUDE.md`, `AGENTS.md`, `Issues.md`, `Fixed.md` for mandates and current backlog. Resume from current state. Update this document as you work.

## §1 — Snapshot

| Field | Value |
|---|---|
| Repo | vasic-digital/tmux on GitHub + GitLab |
| Origin | Migrated from ATMOSphere project (`scripts/tmux/`, `docker/Dockerfile.tmux-build`, `docs/guides/TMUX_OPTIMIZED_BUILD.md`) on 2026-05-07 |
| Pinned tmux | upstream tag `3.6a` |
| Version | **1.0.14** (versionCode 15) — A35 clipboard copy-OUT physical proof (test 44 + M44 + TMUX-CH-44 + verify.sh Layer-1 extension) + A36 e2e stale-podman-prereq fix + B3 P5 escape transparency; multi-host deploy (Mistborn + nezha), 2026-05-22 |
| Verification (this cycle) | **Multi-host deploy GREEN.** Mistborn (Darwin arm64): `bash scripts/setup.sh --rebuild` → GREEN; suite `PASS=41 FAIL=0 SKIP=3`. NEW test 44 PASS=7/0/0 with T5 `pbpaste` returning the marker — physical end-user clipboard proof. e2e PASS=9/0/0 (after A36 fix). Meta-test `39 caught / 2 escaped / 8 skipped` (escapes pre-existing P5-M20/M21, see `Issues.md` B3). Nezha (Linux ALT 6.12 x86_64): `bash scripts/setup.sh --rebuild` → GREEN; suite `PASS=37 FAIL=0 SKIP=7` (SKIP 44 because T5 honestly SKIPs on headless server with no DISPLAY/Wayland; T1-T4 binding-chain proof all PASS — exactly the §104 topology dispatch the test was designed for). e2e PASS=9/0/0 including T7 distinct cgroup scopes for two operator-path sessions. Meta-test `37 caught / 4 escaped / 8 skipped` (P5-M20/M21 same pre-existing + M22 environmental-CodeGraph-state issue, see B3 — neither introduced by v1.0.14). Captured 2026-05-22 on both hosts. |
| Governance docs | `constitution/` submodule (HelixConstitution, pinned `84c948d`); `Containers/` submodule (pinned `fbef9d6`); project `Constitution.md` (Project Articles §101–§109, extends the submodule), `CLAUDE.md`, `AGENTS.md`, `QWEN.md`, `Issues.md`, `Fixed.md`, this document |

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

Web research output: `docs/plans/containerization.md` recommends `systemd-run --user --scope` (cgroup-v2 transient scope) over podman-per-session. Wrapper at `scripts/tmx` implements `tmx {new|attach|ls|kill}` with `MemoryMax=$TMX_MEM` (default 8G), `CPUQuota=$TMX_CPU` (default 200%), `TasksMax=4096`, `Delegate=yes`.

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
- **`docs/guide/README.md` phantom-script bluff fixed**: 3 occurrences each of `verify_tmux.sh` → `verify.sh`, `setup_tmux.sh` → `setup.sh`, `install_tmux_deps.sh` → `install_deps.sh`; "8 tests" → "14 tests" (2×).
- **GUIDE.md "severity hierarchy" pre-existing bluff caught** (Fixed.md A3): documented "blockers / critical / advisory" classification does not exist in `run_all.sh` — every test is treated equally (any FAIL = RED). Rewritten to describe the actual gate logic. Caught while extending the table for tests 09-14; would have been silently doubled otherwise.
- **Verification + validation cycle 2026-05-13** (Fixed.md A14): operator invoked `superpowers:verification-before-completion` + asked for full anti-bluff verification + governance propagation. Every verification command run FRESH this session per Iron Law. Captured evidence: `setup.sh --verify-only` SUMMARY=PASS=10 FAIL=0 SKIP=5 GREEN; `test_e2e.sh` PASS=9/0/0 GREEN; test 15 PASS=6/0/0; live `tmx new -s VerifyDemo` shows operator's host shell (`milosvasic@Mistborn`, `which brew=/opt/homebrew/bin/brew`, `ulimit -t=86400`, `ulimit -u=2666`). Two defects caught and fixed: (D1) wrapper hostname resolution drifted to FQDN after bridge removal — restored scutil-LocalHostName path so colour stays `colour202` for Mistborn; (D2) `install_deps.sh` + `build_oom_set.sh` weren't OS-aware out of the box — now `install_deps.sh` detects Darwin → brew install (no sudo), `build_oom_set.sh` SKIPs on non-Linux. Governance propagation completed: verbatim user-mandate quote now in root CLAUDE.md + AGENTS.md (previously only in Constitution + Containers); §11.4.7 reference added to Containers/CLAUDE.md + Containers/AGENTS.md (previously only Containers/CONSTITUTION.md). Install state: shell snippets in both ~/.bashrc + ~/.zshrc, `zsh -c 'which tmx; tmx -V'` returns native wrapper + `tmux 3.6a`. macOS RLIMIT_AS gap documented honestly per §1 (XNU EINVAL for unprivileged setrlimit on memory).
- **Per-session isolation + Constitution §11.4.7** (Fixed.md A13): user reported `core@localhost` + lack of OOM containment. Forensic: `tmx new -s isol1 -d` + `tmx new -s isol2 -d` previously shared ONE cgroup (`run-p504653-i504654.scope`) — README's "if one session OOMs, others survive" was a §1 bluff. Architectural rewrite: each `tmx new -s NAME` now spawns its OWN tmux server on socket `tmx-NAME` inside its OWN scope `tmx-NAME.scope` with host-adaptive `MemoryMax` (max(MemTotal × 60% / 4, 2GB)), `CPUQuota=200%`, `TasksMax=4096`, `Delegate=yes`. OOM in any session = contained to that scope; B+C survive with original MainPIDs (verified test 14 PASS=8/0/0 with stress-ng `tmx send-keys`). Test 15 NEW: per-session cgroup distinctness (6 assertions, positive readback from /sys/fs/cgroup). Test 11 + test 14 + test 08 rewritten to OPERATOR PATH (`tmx new -s NAME` instead of hand-crafted `systemd-run --user --scope`). e2e T7 NEW: bridge confirms two distinct scopes via VM systemctl. Meta-test M5 retargeted, M7 retargeted, M9+M10 NEW (10/10 mutations caught). Plan + operator decisions captured in [`docs/plans/per-session-isolation.md`](docs/plans/per-session-isolation.md). **Constitution §11.4.7 NEW** (operator-path test coverage rule): every gate test MUST exercise the same entry point an end-user invokes; tests that hand-craft equivalents are supplementary. Propagated to `Containers/CONSTITUTION.md` at same depth. Forensic anchor: Fixed.md A12 (status-bar green default) + A13 (sessions sharing one cgroup) — both shipped while non-operator-path tests reported GREEN.
- **Regression protection for A10 — gate-coverage gap closed** (Fixed.md A11): user demanded "make sure nothing passes again! zero-bluff policy MUST BE followed blindly!" — honest accounting of why the existing gates missed the colour bug:
  - test 11 always passed `-S "$SOCKET"` → tested explicit-socket path only; operator's default-socket use case uncovered.
  - meta-test M4/M5 targeted `scripts/tmx` (the SSH bridge on Darwin) instead of `scripts/tmx-vm` (the actual VM wrapper) — paired-mutation harness was mutating the wrong file.
  - test_e2e.sh pre-fix didn't read `status-style` at all.
  - Triple-layer regression protection added: (1) test 11 T6 — new test exercising default-socket path with positive evidence (`tmux show -g status-style` with NO `-S`, FAILs explicitly on `bg=green` default-applied bluff); (2) meta-test M4/M5 retargeted to `scripts/tmx-vm`; (3) M7 (re-introduce SOCK-empty early return) + M8 (hardcode bg=green) both caught by test 11 T4.1/T6. Result: all 8 mutations caught + reverted (16 PASS), full destructive suite PASS=14/0/0, e2e PASS=8/0/0.
- **Status-bar colour silently green (default) + bridge ignored macOS hostname** (Fixed.md A10): user said "Bottom was green for current host. Is that expected for mistborn?" — two stacked bluffs caught:
  - `_apply_host_color` / `_apply_oom_score` had `[ -n "$sock" ] || return 0` — silently bailed when `tmx new -s Test` was invoked WITHOUT `-S` (which is the primary operator use case; tmux uses its default socket then). So `set -g status-style` was never fired → tmux default `bg=green` shown. Test 11 always passes `-S "$SOCKET"` so the bug was uncovered. Fix: helpers now build `target=(-S "$sock")` only when sock is non-empty; otherwise omit `-S` and let tmux use its default socket.
  - Bridge `scripts/tmx-mac.template` didn't forward macOS hostname → `hostname_color.sh` inside VM resolved against `localhost.localdomain` regardless of macOS host. Every macOS user got the same VM-derived colour, violating host-distinguishability. Fix: bridge captures `scutil --get LocalHostName` (e.g., "Mistborn"), forwards as `TMX_HOSTNAME=<host>` in the remote SSH command. Wrapper's `_apply_host_color` passes `${TMX_HOSTNAME:+"$TMX_HOSTNAME"}` to hostname_color.sh — env var is source of truth when set, `$(hostname)` fallback otherwise.
  - New `test_e2e.sh` T4.5 explicitly reads `tmx show -g status-style`, computes expected colour from `scutil --get LocalHostName` (or `hostname` on Linux), FAILs on `bg=green` (default-applied bluff) or non-match. Captured runtime evidence on Mistborn: `status-bg 'colour202' matches hostname-derived 'colour202' for 'Mistborn'`.
- **Interactive `tmx new` fixed + e2e automation harness** (Fixed.md A9):
  - User ran `tmx new -s Test` interactively after install and hit `open terminal failed: not a terminal`. The bridge + ssh -t allocated TTY correctly; the WRAPPER's `cmd & wait` pattern was disconnecting tmux from the foreground process group → no TTY access. Detached-mode tests (`-d`) all passed because tmux daemonizes; interactive (no `-d`) hit the bluff. §11.4.1 FAIL-bluff in the wrapper itself.
  - Fix: wrapper now detects `-d`/`-D` in args (INTERACTIVE flag), and for interactive: runs systemd-run in foreground inheriting TTY, injects `-d` after the new-session keyword (so tmux server detaches), then `exec attach` to take over TTY interactively. For detached: keeps existing path.
  - New: `scripts/test_e2e.sh` — 7-test operator-facing automation: prerequisites + `tmx -V` (via bridge) + new-session + send-keys + capture-pane + survive-without-client + kill-session. All with positive runtime evidence; trap-on-EXIT cleanup. Captured the literal marker string echoed inside the session pane through the bridge — proves the full operator stack carries intent end-to-end.
  - Verified: `bash scripts/test_e2e.sh` GREEN 7/0/0; `TMX_TEST_DESTRUCTIVE=1 bash scripts/test_vm.sh` still GREEN 14/0/0 (wrapper change didn't regress existing tests).
- **macOS `tmx` fully operational + side-by-side end-to-end** (Fixed.md A8):
  - `bash scripts/setup.sh` on Darwin now diverges intelligently: builds (containerized), generates BOTH `scripts/tmx-vm` (Linux wrapper for VM paths) AND `scripts/tmx` (Darwin SSH bridge from new `scripts/tmx-mac.template`); runs `scripts/test_vm.sh` for §11.4 target-env verification (since binary cannot exec on Darwin); on GREEN, appends bashrc snippet to BOTH `~/.bashrc` AND `~/.zshrc` (macOS defaults to zsh).
  - **Bridge mechanics**: `scripts/tmx-mac.template` discovers podman machine's SSH endpoint via `podman machine inspect` at every call (port re-discovery — survives `podman machine stop && start`), verifies `tmx-vm` is executable in the VM, then `ssh -t -i <identity> -p <port> core@127.0.0.1 "<vm-repo>/scripts/tmx-vm <quoted-args>"`.
  - **Verified end-to-end on Darwin 24.5.0 / Apple Silicon**: `zsh -c 'source ~/.zshrc; which tmx; tmx -V'` → `/Users/.../scripts/tmx` + `tmux 3.6a`; system `/opt/homebrew/bin/tmux -V` → `tmux 3.6a` — side-by-side coexistence proven; VM-side verify GREEN PASS=11 FAIL=0 SKIP=3.
  - **`scripts/verify.sh` now respects `$WRAPPER` and `$TMUX_BIN` env vars** so test_vm.sh / bridge tooling can redirect to the right wrapper without source modifications.
  - **README.md** gained a new "Architecture" section with ASCII diagram showing Linux-native vs Darwin-bridge dispatch; `docs/guide/README.md` §5.5 documents the bridge mechanics + Mermaid flowchart; CLAUDE/AGENTS one-liners updated.
- **Final sweep — env-specific wrapper + §255 violations + sed portability** (Fixed.md A7):
  - **Environment-bound wrapper:** `scripts/tmx` was generated for one env (container `/repo` paths OR VM `/Users/.../` paths) and silently failed in the other. New `scripts/test_vm.sh` orchestrator regenerates the wrapper with VM-native paths before each VM-side run. Both `test_containerized.sh` and `test_vm.sh` now own the wrapper-regeneration step for their respective target.
  - **Constitution §255 violations:** "ATMOSphere" in GUIDE.md title + body, challenge yaml description, oom_set.c license comment, tmux.conf.template attribution; `atm_tmux_test_*` / `atm_test_*` / `atm_tmx_test_color_*` socket/session names across 8 test files; `~/.tmux.conf.pre-atmosphere` backup naming. All renamed: code uses `tmx_*` / `pre-vasic-digital`; docs branded "vasic-digital".
  - **`sed -i` portability:** setup.sh used GNU-only `sed -i` for bashrc markers — would fail on macOS BSD sed. Centralized in `_strip_bashrc_snippet()` using `perl -i -ne ... ../ ...` flip-flop range delete (portable GNU+BSD).
  - **Verified post-fix in VM:** `TMX_TEST_DESTRUCTIVE=1 bash scripts/test_vm.sh` → PASS=14 FAIL=0 SKIP=0; `META=1 bash scripts/test_vm.sh` → 12/12 mutations caught.
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

### §3.15 — v1.0.14 clipboard copy-OUT physical proof + e2e stale-prereq fix + multi-host deploy (2026-05-22)

**Status:** COMPLETE (2026-05-22).

Triggering event: operator mandate (verbatim, 2026-05-22):
> "We can always copy / paste from and to the terminal window and
> current tmux (tmx) session! Using mouse or keyboard MUST WORK
> properly!!! Scrolling the content / history MUST NOT be broken or
> anything else! After all changes are done, covered with full
> validation and verification tests make sure we setup new version
> to current host (macOS) and nezha (nezha.local is back online).
> Once both hosts are updated with the latest versions and on both
> hosts all tests are executed with success with no failure and
> bringing real proofs of everything working as requested and
> expected (physical proofs) with no bluffs commit and push all
> Submodules and main repo to all upstreams and release new version
> with comprehensive in-depth version (change) log using GitHub and
> GitLab CLIs."

- **A35 clipboard copy-OUT physical proof** (Fixed.md A35):
  identified the §101 PASS-bluff hole — bindings existed and grepped
  fine, but no test ever read back the OS clipboard.
  - NEW `scripts/tests/44_clipboard_copy_out_physical.sh` —
    operator-path. Spawns `tmx new -s NAME -d`, prints a unique
    marker, enters copy-mode, search-backward + select-line, invokes
    `@clip` (T3 direct -X + T4 the literal `y` keystroke that
    triggers the bind table end-to-end), then reads the OS-native
    paste tool (T5 — `pbpaste` / `wl-paste -n` / `xclip -o` /
    `termux-clipboard-get`) and asserts the marker is there. T5
    SKIPs honestly with reason on headless Linux; T3/T4 binding-
    chain proof runs everywhere so the test is never inert. Pre-test
    save + post-test restore of the operator's clipboard.
  - PASS=7/0/0 this cycle (Darwin); T5 returned the marker via
    `pbpaste` — physical end-user evidence.
  - Layer-1 verify.sh static gate extended (4 new `_l1` checks for
    `@clip` + the three bindings).
  - Layer-3: `TMUX-CH-44` in `scripts/challenges/tmux.yaml`.
  - Layer-4: `M44` in `meta_test_false_positive_proof.sh` strips
    the `@clip` definition line — test 44 T1 catches universally
    (structural grep), T5 additionally catches where a clipboard
    tool is reachable. CAUGHT + RESTORED both directions.
- **A36 e2e stale podman-machine prerequisite** (Fixed.md A36):
  `scripts/test_e2e.sh` T1.2 still hard-required a running podman
  machine, a leftover from the pre-v1.0.7 SSH-bridge architecture.
  Fixed by probing for the native Mach-O binary FIRST and only
  falling back to the podman check for bridge-era installs. e2e
  GREEN after the fix.
- **B3 P5 escape transparency** (Issues.md B3): meta-test reported 2
  ESCAPES on Mistborn — P5-M20 (non-TTY guard) and P5-M21
  (cwd-capture hook). Nezha additionally reports M22 as an
  ENVIRONMENTAL escape (CodeGraph state). All three pre-exist this
  cycle. Investigation: P5-M20/M21 are layer-4 test-DESIGN gaps —
  the assertions cannot distinguish "guard fired" from "fallback
  fired", so a single-layer strip slips through. M22 is an
  environmental state-dependency on the CodeGraph index/config on
  nezha. Underlying features GREEN. Surfaced transparently in
  `Issues.md` B3 + the v1.0.14 CHANGELOG — anti-bluff disclosure per
  §11.4 / §101 / §11.4.6. Closure conditions documented; deferred
  to a future cycle.
- **Multi-host deploy** (this turn's operator ask, satisfied):
  Mistborn updated to v1.0.14 via `setup.sh --rebuild`. Nezha
  fetched gitlab/main, fast-forwarded to v1.0.14, rebuilt and
  installed. Both hosts run the same code; both gates GREEN; both
  e2e GREEN; clipboard physically proven on Mistborn (pbpaste) and
  binding-chain proven on nezha (tmux buffer, T5 honest-SKIP on
  headless).

### §3.14 — v1.0.8 uniform tmux UI recolouring (active border + clock + window-status-current) (2026-05-21)

**Status:** COMPLETE (2026-05-21T21:00Z).

Operator-driven follow-up to v1.0.7: "flying animated top decoration"
+ clarification "Do coloring of all UI tmux parts with proper color
we use instead of default green. Anything colored with that green
colors has to become the color we have assigned to the bottom view
we are coloring."

Pre-v1.0.8 `_apply_host_color()` set only `status-style bg=$color`.
Other default-green tmux surfaces (active pane border, clock face,
selected-window highlight) stayed green. v1.0.8 extends the wrapper
to apply the hostname-derived colour atomically to all four:
- `status-style              bg=$color`
- `pane-active-border-style  fg=$color`
- `clock-mode-colour         $color`
- `window-status-current-style bg=$color,fg=black`

`mode-style` + `message-style` deliberately untouched (default yellow,
not green; yellow provides best contrast against any palette bg).

NEW test 26 (`26_ui_color_uniformity.sh`) — operator-path session
spawn + live `show -gv` readback per surface — PASS=5/0/0 on Darwin.
NEW M24 paired mutation — regex-strips the three v1.0.8 set-lines
from the generated wrapper, asserts test 26 T2/T3/T4 FAILs. MUTATION
CAUGHT + FEATURE INTACT both directions.

Captured operator-path readback (Mistborn, this session):
- status-style: `bg=colour44`
- pane-active-border-style: `fg=colour44`
- clock-mode-colour: `colour44`
- window-status-current-style: `bg=colour44,fg=black`
→ All four surfaces uniformly turquoise (colour44 = RGB 0,215,215).

Verification (Darwin quintuple-fresh, 2026-05-21):
- setup.sh --verify-only → PASS=24 FAIL=0 SKIP=2
- meta-test → 36 caught / 0 escaped / 6 skipped
- e2e → PASS=9 FAIL=0 SKIP=0
- codegraph_validate → PASS=4 FAIL=0 SKIP=1

Released v1.0.8; setup.sh re-run as final install per operator
"Make sure we setup the new version once all done." directive.

### §3.13 — v1.0.7 cross-host portability + hostname-colour rebalance + Node-22 pin + release (2026-05-21)

**Status:** COMPLETE (2026-05-21T18:30Z).

Operator-driven cycle: tried to install on Nezha (Linux), 3 tests
FAILed → 6 fix rounds → Nezha GREEN → operator reported orange-color
collision (Nezha + Mistborn) → palette rebalanced + test 25 + M23
mutation → release v1.0.7.

Six fix rounds (all Nezha-driven; live forensic capture):
1. Initial 3-fix attempt (test 09 timing, test 17 ingestion race,
   test 21 codegraph bootstrap). Test 17 fixed; tests 09 + 21 had
   secondary defects.
2. Bash `-lt` fractional bug in round-1 poll-loop (silent fail);
   npm-prefix PATH augmentation for non-interactive shells.
3. CodeGraph init clobbers config.json on every version; auto-update
   wiring per §11.4.80 mandate ("ALWAYS latest").
4. cgroup.procs sweep (kill all PIDs not just first) + `stat -f
   '%z'` portability bug (Darwin vs Linux).
5. Test 09 T4.2 rewritten to verify the REAL containment invariant
   (cgroup.procs drained), not systemd's unit-state transition
   (which is sticky on systemd 258 / ALT 11 — verified live).
6. macOS Node 22 LTS pin: codegraph 0.8.0 refuses Node 25 per
   upstream issue #81. Operator authorised `brew install node@22 &&
   brew link --force --overwrite`. Updated .zshrc references.

Then the hostname-colour palette rebalance:
- Operator: "nezha and Mistborn both show orange". Palette had 7
  orange-family colours out of 27.
- Rebalanced to 27 entries spanning the hue spectrum; no two
  adjacent within RGB Euclidean distance 80.
- NEW test 25: T1 nezha+Mistborn distance ≥ 80 (post-fix: 332.7);
  T2 16-synthetic-hostname pairwise within pigeonhole tolerance;
  T3 palette adjacency check.
- NEW M23 mutation: revert palette → test 25 FAILs.

Verification (Darwin quintuple-fresh, 2026-05-21):
- setup.sh --verify-only → PASS=23 FAIL=0 SKIP=2
- meta-test → 34 caught / 0 escaped / 6 skipped
- e2e → PASS=9 FAIL=0 SKIP=0
- codegraph_validate → PASS=4 FAIL=0 SKIP=1
- codegraph_cadence_check → GREEN

Nezha verification: round-5 setup.sh full pipeline GREEN (after fix
rounds 1-5 landed). v1.0.7 includes all 6 rounds + palette + test 25.

Out-of-scope this cycle (logged honestly per §11.4.6):
- Auto-detection of Node version compatibility in setup.sh —
  deferred to v1.0.8.
- Pre-tag Nezha re-verify of v1.0.7 final → will run after tag push
  as deferred post-release smoke.

### §3.12 — v1.0.6 workable-items closure + §11.4.80 cadence + Containers/QWEN.md + release tag (2026-05-21)

**Status:** COMPLETE (2026-05-21T15:30Z).

Operator directive (verbatim): "Finish all workable items you have
presented here, rebuild and install again, retest fully and if fully
working as expected release new version!"

Closed (this cycle):
- **§11.4.80 automatic-trigger wiring** (was the one deferred item from
  v1.0.5 audit). New `scripts/codegraph_cadence_check.sh` + `scripts/
  codegraph_install_cadence.sh`. Darwin launchd plist installed +
  loaded (verified via `launchctl list`). Cross-platform git pre-push
  hook installed (warns on STALE; `CADENCE_MODE=block` available).
  Anti-bluff: cadence check reads STAMP CONTENT (regenerated_at +
  node_count), not just existence. §11.4.81 cross-platform-parity
  dispatch in the installer: Linux gets systemd user timer; Darwin
  gets launchd plist.
- **Containers/QWEN.md covenant gap** (was the second-to-last
  out-of-scope item from v1.0.5 — `Containers/QWEN.md create`).
  Containers commit `fbef9d6` pushed to github + gitlab. Parent
  pointer bumped `4ca5491` → `fbef9d6` in this cycle's commit.
- **Full rebuild + install** via `bash scripts/setup.sh` (not just
  --verify-only). ~/.tmux.conf installed; .bashrc + .zshrc snippets
  appended; tmx wrapper installed.
- **Quintuple-fresh verification** captured this session:
  setup.sh --verify-only → PASS=22/0/SKIP=2;
  meta-test → 32 caught / 0 escaped / 6 skipped;
  e2e → 9/0/0;
  codegraph_validate → 4/0/SKIP=1;
  codegraph_cadence_check → GREEN.

Still out of scope (logged honestly per §11.4.6):
- Cadence-script paired §1.1 mutation (backdate-stamp → cadence FAILs)
  — deferred to v1.0.7. The script's content-based read is already
  anti-bluff; the mutation would tighten regression protection.
- CodeGraph upstream `--include-submodules` — separate cycle per §11.4.74.
- Linux-host CI runner — would exercise the Linux systemd user timer
  install path + the Linux branches of tests 09/13/14.

Release `v1.0.6` tagged + pushed per §11.4.40 (complete fresh retest
preceded the tag; no spot-check shortcut).

### §3.11 — §11.4.81 cross-platform-parity + Darwin branches + constitution §11.4.81 (2026-05-21)

**Status:** COMPLETE (2026-05-21T07:30Z).

Triggering events (in arrival order):

- Operator (2026-05-21): "Any Linux-only blocker / issue we have MUST BE
  created macOS and other supported platforms equivalent! So, depending
  on platform proper implementation will be used for particular OS!
  EVERYTHING MUST BE PROPERLY EXTENDED AND UPDATED!"
- Operator (2026-05-21): "Add this OS / Platform details / rules /
  mandatory constraints into our root (constitution Submodule)
  Constitution.md, CLAUDE.md, AGENTS.md, QWEN.md and other constitution
  Submodule relevant files so all projects who inherit these in the
  future immidiately in such situations create proper missing
  implementations for particular platform / OS! Make sure you first
  fetch and pull the latest version of constitution Submodule. Once
  all done and extended properly commit and push constitution Submodule
  to all upstreams, then re-process and re-evaluate all rules and
  mandatory constraints..."
- (Power blackout mid-cycle — work resumed cleanly from working tree.)

Plan + execution captured at `docs/plans/v1.0.5.md`. Seven phases all
landed in one v1.0.5 commit per §11.4.42 iteration discipline.

- **§11.4.26 step 1+:** constitution submodule fetched + ff-merged from
  `7f738df` → `19ce1b1` (brought in §11.4.79 + §11.4.80 CodeGraph
  anchors).

- **§11.4.81 anchor LANDED in constitution submodule (pushed
  `6e164f3` to `origin` HelixDevelopment).** Universal cross-platform-
  parity mandate + mirror blocks in Constitution.md / CLAUDE.md /
  AGENTS.md / QWEN.md. Three sub-mandates: (A) per-OS implementation
  REQUIRED via runtime dispatch; (B) per-OS tests REQUIRED with
  positive captured evidence per branch; (C) honest kernel-gap
  citation + adjacent equivalent test REQUIRED where no equivalent
  exists. constitution/QWEN.md ALSO gained the verbatim 2026-04-28
  anti-bluff covenant quote (audit gap fix).

- **A26 — §11.4.79 compliance fix.** Removed `constitution/**` and
  `Containers/**` from `.codegraph/config.json` exclude (own-org MUST
  be INCLUDED); kept `tmux/**` excluded (third-party).
  `scripts/codegraph_validate.sh` NEW — 5 probes (V1 CLI version, V2
  node count, V3 §11.4.79 split, V4 honest-gap re submodule traversal,
  V5 MCP spawn). M22 paired mutation (re-exclude → V3 FAILs). Honest
  gap: CodeGraph 0.6.8 doesn't traverse submodules; config compliance
  met but practical cross-submodule indexing waits for upstream
  CodeGraph support.

- **A25 + A22 + A24 — Darwin branches for tests 09/13/14 + NEW test 24
  (per §11.4.81 just landed).** All four exercise the macOS POSIX
  rlimit primitives that are the kernel-enforced equivalents of the
  Linux cgroup primitives:
  - **Test 09 Darwin (PASS=6/0/0):** wrapper invokes `tmx-rlimit-
    wrapper.sh`, two operator-path sessions, distinct server PIDs,
    `ulimit -t`/`-u` readback inside each pane via send-keys +
    capture-pane, SIGKILL session A's server, session B survives
    with ORIGINAL PID (positive evidence per §11.4.5).
  - **Test 13 Darwin (PASS=2/0/0):** child bash lowers `ulimit -u 64`
    + fork-bombs; captures EAGAIN occurrences from stderr (`bash:
    fork: Resource temporarily unavailable`) = XNU kernel-enforced
    RLIMIT_NPROC.
  - **Test 14 Darwin (PASS=5/0/0):** 3 operator-path sessions; SIGKILL
    session A's server (macOS adjacent test for OOM-independence per
    §11.4.81 (C) — Darwin has no OOM killer); verify B+C survive with
    ORIGINAL PIDs + tmx ls still lists them.
  - **NEW Test 24 Darwin (PASS=2/0/0):** child bash sets `ulimit -t 2`
    + CPU-bound loop; verifies process killed by signal 24 (SIGXCPU)
    after ~3s wall (exit rc=152 = 128+24); also verifies
    `TMX_CPU_HARD_SEC=7200` propagates to `RLIMIT_CPU=7200` inside
    session. §11.4.81 (C) adjacent test for the XNU RLIMIT_AS gap.

- **A25 paired mutations refresh.** M7-M10 RETIRED (targeted dead
  `scripts/tmx-vm` VM-wrapper path, replaced by native dual-OS per
  Fixed.md A4-A8). M20 + M21 NEW for Darwin rlimit. M22 for §11.4.79
  codegraph exclude. Meta-test on Darwin: 32 caught / 0 escaped /
  6 skipped (M4/M5 topology-correct SKIP on Darwin; M7-M10
  retired-with-rationale SKIPs).

- **Constitution submodule pointer bumped** `19ce1b1` → `6e164f3` in
  this same project commit per §11.4.26 step 7.

Full gate this cycle (Darwin arm64, 2026-05-21): `setup.sh --verify-only`
PASS=22/0/SKIP=2, meta-test 32/0/SKIP=6 (all SKIPs §11.4.3
topology-correct or retired-with-rationale), e2e 9/0/0,
codegraph_validate PASS=4/0/SKIP=1.

Out-of-scope this cycle (honest tracking per §11.4.6):
- §11.4.80 automatic-trigger wiring (cron / git hook for the
  constitution-provided `codegraph_update.sh` + `codegraph_sync.sh`)
  — deferred. Manual invocation works today.
- CodeGraph upstream `--include-submodules` support — out of scope
  per §11.4.74.
- `Containers/QWEN.md` create — separate PR to
  `vasic-digital/Containers` per §11.4.28.
- Linux-host CI runner — would let us exercise the Linux branches of
  tests 09/13/14 alongside the Darwin branches running today.

### §3.10 — CodeGraph (§11.4.78) + verbatim covenant + AUDIT fixes + docs reorg (2026-05-21)

**Status:** COMPLETE (2026-05-21T05:30Z).

Triggering events (in arrival order):

- Operator (2026-05-21): create full working plan for tackling all
  these points completely; all existing tests + Challenges MUST work
  anti-bluff; covenant MUST be part of project + submodule
  Constitution / CLAUDE / AGENTS; HelixConstitution submodule is the
  root.
- Operator (2026-05-21): incorporate / install CodeGraph for Claude
  Code, OpenCode, Kimi CLI, Crush, Qwen Code; comprehensive anti-bluff
  tests.
- Operator (2026-05-21): full documentation + user guides + HTML + PDF
  exports.
- Operator (2026-05-21): do NOT modify constitution submodule, only
  keep it regularly updated.
- Operator (2026-05-21): documentation under context-named
  subdirectories per the constitution rule.

Plan + execution captured at `docs/plans/v1.0.4.md`. Eight phases all
landed in one v1.0.4 commit per §11.4.42 iteration discipline.

- **A18 CodeGraph integration (§11.4.78).** CLI v0.6.8 installed;
  `.codegraph/config.json` tracked with §11.4.10 secret exclusions +
  §11.4.28 owned-submodule paths; `.codegraph/codegraph.db`
  gitignored; §11.4.77 regen manifest + `scripts/codegraph_reindex.sh`.
  MCP wired for all 5 agents (Claude Code `.mcp.json` NEW; OpenCode +
  Kimi audited; Crush `.crush.json` NEW; Qwen Code `.qwen/settings.json`
  NEW). All configs reference bare `codegraph` on PATH. Comprehensive
  `docs/codegraph/README.md`. Tests 20/21/22, challenges CH-20/21/22,
  mutations M16/M17.

- **A19 verbatim covenant propagation.** §11.4 2026-04-28 user mandate
  now LITERALLY present in project `CLAUDE.md` + `AGENTS.md` +
  `QWEN.md` (was only in `Constitution.md`). Verify.sh Layer-1 gate
  added; test 19 PASS=7/0/0; CH-19; M15 (mutates a temp copy — real
  CLAUDE.md is never touched).

- **A20 AUDIT-1 fix.** M4/M5 meta-test mutations were silently
  SKIPping on Darwin for the wrong reason (BSD `sed -i` quirk). Real
  root cause: the mutations target Linux-only cgroup/systemd-run
  wrapper code unreachable on Darwin. Fix: explicit `uname -s`
  topology guard per §11.4.3 + portable `inplace_sed` for Linux runs.

- **A21 AUDIT-2 fix.** `tmx kill -t NAME` (documented friendly verb)
  was ambiguous because tmux only knows `kill-pane`/`kill-server`/
  `kill-session`/`kill-window`. Wrapper now translates the bare `kill`
  verb to `kill-session`. Test 23 PASS=5/0/0; CH-23; M19.

- **Docs reorganised** under context-named subdirectories per the
  operator's invocation of the constitution rule: 7 docs moved
  (GUIDE/SCROLLING/CODEGRAPH/CONTAINERIZATION_PLAN/NATIVE_DUAL_OS_PLAN/
  PER_SESSION_ISOLATION_PLAN/PLAN_v1.0.4). Every reference in
  governance + scripts updated atomically.

- **§11.4.65 universal-Markdown export.** New `scripts/export_docs.sh`
  (pandoc HTML + weasyprint PDF, idempotent, per-file timeout 60s)
  refreshed siblings for every consumer Markdown.

- **§11.4.71 pre-push.** Parent + `constitution/` + `Containers/` all
  at upstream tip; no divergent commits.

- **Honest gaps logged (§11.4.6) — out of scope this cycle:**
  - Upstream `constitution/QWEN.md` covenant insert → separate PR to
    `HelixDevelopment/HelixConstitution` (operator forbids modifying
    constitution from inside this project).
  - `Containers/QWEN.md` create + populate → separate PR to
    `vasic-digital/Containers` per §11.4.28.
  - Shell parser for CodeGraph (currently only the C file indexed,
    6 nodes) → upstream contribution to add tree-sitter shell.
  - Agent-driven unforgeable-challenge end-to-end test → classified
    `AUTONOMOUS_DESIGNED` per §11.4.52 carve-out (mechanical seam
    exists via test 22 T7; agent-driven layer lands when a headless
    agent harness is wired).

Full gate this cycle (Darwin arm64, 2026-05-21): `setup.sh --verify-only`
PASS=18/0/SKIP=5, meta-test 26/0/SKIP=6 (all SKIPs §11.4.3
topology-correct), e2e 9/0/0.

### §3.9 — Scrolling fix + HelixConstitution inheritance (2026-05-21)

**Status:** COMPLETE (2026-05-21).

Triggering event: operator research note — tmux scrolling (up/down of
terminal output, especially inside the Claude Code TUI) did not work;
requirement to scroll vertically from ANY computer or mobile phone
(Termux/Android). Plus the mandate to incorporate the HelixConstitution
submodule as the root of the Constitution / CLAUDE.md / AGENTS.md,
inherited further.

- **A16 scrolling fix** (`Fixed.md` A16): `scripts/tmux.conf.template`
  — history-limit 2000→50000, `mode-keys vi`, `WheelUp`/`WheelDown`
  overridden to always drive copy-mode scrollback (works on desktop
  mouse + trackpad + Termux touch-scroll), `allow-passthrough` +
  `extended-keys` + `terminal-features extkeys` for the Claude Code TUI,
  OS-adaptive `@clip` clipboard. NEW test 17 (operator-path, PASS=13/0/0),
  verify.sh Layer-1 static gate, `TMUX-CH-17`, M12 + M13 paired mutations.
- **A17 HelixConstitution** (`Fixed.md` A17): added the `constitution/`
  submodule (pinned `7f738df`). Full refactor of `Constitution.md` to the
  extends-template form (Project Articles §101–§109); `CLAUDE.md` /
  `AGENTS.md` inheritance pointers; new `QWEN.md`. NEW test 18
  (PASS=10/0/0), `TMUX-CH-18`, M14 + `CM-CONSTITUTION-INHERITANCE` paired
  mutations. The constitution mutation runs on a TEMP COPY — the real,
  decoupled `constitution/` submodule is never modified (operator
  directive).
- **Containers submodule**: adopted remote `4ca5491`, which already
  carries HelixConstitution recursive inheritance (`find_constitution.sh`,
  `QWEN.md`, all four governance docs). Parent gitlink bumped
  `b077f2c` → `4ca5491`.
- **Meta-test portability**: M1/M2/M3/M6 converted from GNU `sed -i` to a
  portable `inplace_sed` helper — they now run on macOS instead of
  silently skipping. Meta-test: 18 caught / 0 escaped / 6 skipped (was
  10/0/10).
- Full gate this cycle (Darwin arm64, 2026-05-21): `setup.sh --rebuild`
  GREEN, suite PASS=13/0/SKIP=5, meta-test 18/0/6, e2e 9/0/0.

## §4 — Recent commits

- (this commit, 2026-05-21) — **A16 scrolling fix + A17 HelixConstitution
  inheritance (v1.0.3 / versionCode 4).** `tmux.conf.template`:
  history-limit 50000, vi copy-mode, WheelUp/Down → copy-mode scrollback
  override, Claude Code passthrough, OS-adaptive clipboard.
  HelixConstitution submodule added at `constitution/`; `Constitution.md`
  refactored to the extends-template form (§101–§109); CLAUDE/AGENTS
  inheritance pointers + new `QWEN.md`. Tests 17 + 18, challenges
  CH-17/18, mutations M12–M14 + CM-CONSTITUTION-INHERITANCE; meta-test
  M1/M2/M3/M6 made portable. Containers gitlink → `4ca5491`. Gate:
  PASS=13/0/5, meta 18/0/6, e2e 9/0/0. See `Fixed.md` A16 + A17, §3.9.
- (this commit, 2026-05-16) — **A15 cosmetic .exe-strip cycle (v1.0.2 /
  versionCode 3).** Bottom-left status bar showed `claude.exe` because
  Claude Code v2.x ships its macOS native binary literally as
  `.../@anthropic-ai/claude-code/bin/claude.exe` (verified Mach-O 64-bit
  ARM64). Patched `scripts/tmux.conf.template` to set
  `automatic-rename-format "#{s/\\.exe$//:pane_current_command}"` —
  literal-dot-anchored, escape-verified-empirically. Added test 16
  (operator-path per §11.4.7, includes regression guard binary
  `t16_bashexe` to catch the unescaped-dot bug class), challenge
  TMUX-CH-16, M11 paired mutation. Live operator-path validation
  recorded: `pane_current_command='claude.exe'` → `#W='claude'`. Full
  gate: PASS=11 FAIL=0 SKIP=5 (same SKIP profile as v1.0.0). See
  Fixed.md A15.
- (commit before that, 2026-05-13) — Audit cycle: tmux submodule reverted from `3f651d9f` to `cc117b5` (3.6a tag) after silent pin-drift caught; README.md test-count + PASS/SKIP staleness fixed (8→14 tests, PASS=6→10, SKIP=2→4); CLAUDE.md + AGENTS.md gained project summary, cross-links, fresh-conversation workflow, `NN_*.sh` glob fix, named four layers, "Files to never edit directly"; Issues.md restored A/B/C/D/E section headers; CONTINUATION.md §3.8 + timestamp refresh per §12.10. See §3.8.
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
