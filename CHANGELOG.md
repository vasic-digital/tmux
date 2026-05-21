# Changelog — vasic-digital/tmux

All releases use [Semantic Versioning](https://semver.org/). Every release
carries a positive-runtime-evidence verification record per the project's
anti-bluff covenant (Constitution §101 / universal §11.4).

---

## [v1.0.6] — 2026-05-21

**Workable-items closure cycle: §11.4.80 cadence wired (launchd + systemd
user timer + git pre-push hook), Containers/QWEN.md covenant gap closed
+ pushed to Containers remotes (`fbef9d6`). Full rebuild + install +
quintuple verification GREEN. Release tag per §11.4.40.**

### Added (project)

- **`scripts/codegraph_cadence_check.sh`** — §11.4.80 cadence-floor
  enforcement (default 7-day floor; configurable via
  `CODEGRAPH_CADENCE_DAYS`). Parses `.gitignore-meta/.regenerated/
  codegraph-db.ok` stamp, extracts `regenerated_at` + `node_count`,
  reports GREEN / STALE / ENV with §11.4.6 honest reasons. Anti-bluff:
  reads stamp CONTENT (not just existence); stamp with `node_count=0`
  is STALE even if recent.

- **`scripts/codegraph_install_cadence.sh`** — §11.4.81 cross-platform
  cadence-trigger installer. Darwin path: writes a launchd plist at
  `~/Library/LaunchAgents/digital.vasic.tmux.codegraph-cadence.plist`
  with `StartInterval=604800` (7 days). Linux path: writes a systemd
  user timer + service unit at `~/.config/systemd/user/`. Cross-
  platform: writes git pre-push hook at `.git/hooks/pre-push` calling
  `codegraph_cadence_check.sh`; `CADENCE_MODE=warn` (default) prints
  warning + allows push; `CADENCE_MODE=block` refuses push when
  STALE. Idempotent install + clean `--uninstall` path.

### Fixed (project + Containers submodule)

- **Containers/QWEN.md covenant gap** (`fbef9d6` pushed to Containers
  github + gitlab). Inserted the verbatim 2026-04-28 user-mandate
  quote + §11.4.81 cross-platform-parity reference into the
  consumer-layer QWEN.md (the other Containers governance files —
  CLAUDE.md, AGENTS.md, CONSTITUTION.md, Constitution.md — already
  carried the covenant; QWEN.md was the only gap). Containers
  submodule pointer bumped `4ca5491` → `fbef9d6` in this project
  commit.

### Verification (this cycle, captured 2026-05-21 on Darwin arm64)

- `bash scripts/setup.sh` (full rebuild + install) → GREEN.
  ~/.tmux.conf installed; snippet appended to ~/.bashrc + ~/.zshrc;
  tmx wrapper installed; PATH propagation verified.
- `bash scripts/setup.sh --verify-only` → SUMMARY `PASS=22 FAIL=0
  SKIP=2` GREEN.
- `bash scripts/tests/meta_test_false_positive_proof.sh` →
  `32 caught / 0 escaped / 6 skipped` GREEN.
- `bash scripts/test_e2e.sh` → `PASS=9 FAIL=0 SKIP=0` GREEN.
- `bash scripts/codegraph_validate.sh` → `PASS=4 FAIL=0 SKIP=1`
  (V4 honest gap re submodule traversal — same as v1.0.5).
- `bash scripts/codegraph_cadence_check.sh` → GREEN (0.2d ago,
  6 nodes, within 7d cadence floor).
- `zsh -ic 'which tmx; tmx -V'` → `/Users/milosvasic/Projects/tmux/
  scripts/tmx` + `tmux 3.6a` (operator-path live confirmation).
- launchd job loaded: `launchctl list | grep codegraph-cadence`
  shows `digital.vasic.tmux.codegraph-cadence`.
- git pre-push hook installed + executable: `.git/hooks/pre-push`.

### Hardened (4-layer regression protection per §103)

- **Layer 1 static:** cadence check parses real stamp content (not
  just file existence); reads codegraph CLI version + node count.
- **Layer 2 runtime:** `codegraph_cadence_check.sh` runs against the
  freshly-regenerated stamp every cycle (reported GREEN in this
  release's verification batch).
- **Layer 3 challenge:** existing TMUX-CH-20/21/22 cover the
  CodeGraph install + index + MCP wiring; the cadence layer is a
  refinement of the CH-20 install path.
- **Layer 4 mutations:** (deferred — cadence-script paired mutation
  is a §11.4.6 honest-tracked TODO for v1.0.7; the cadence script
  itself uses captured-evidence reads per §11.4.5).

### §11.4.40 release-tag discipline

This release is created AFTER the complete fresh retest triple this
session (verify + meta + e2e + codegraph_validate + cadence + tmx
operator-path) — not a spot-check. All five GREEN. Tag `v1.0.6`
created post-commit, pushed to github + gitlab.

### §11.4.71 pre-push integrity

- Parent: at upstream tip; no divergent commits.
- `constitution/` submodule: at upstream tip (`6e164f3`); pulled in
  v1.0.5; no new commits this cycle.
- `Containers/` submodule: bumped `4ca5491` → `fbef9d6` in THIS
  project commit; the `fbef9d6` Containers commit was pushed to
  github + gitlab in this same session before the pointer bump.

### Out-of-scope (honest tracking per §11.4.6)

- Cadence-script paired §1.1 mutation — deferred to v1.0.7. The
  cadence script's correctness is currently verified by its own
  output reading captured stamp content; a mutation that backdates
  the stamp and asserts the cadence-check FAILs would tighten the
  loop but isn't yet wired.
- CodeGraph upstream `--include-submodules` — out of scope per
  §11.4.74.
- Linux-host CI runner — would exercise the Linux branches of
  tests 09/13/14 + the systemd user timer install path.

---

## [v1.0.5] — 2026-05-21

**§11.4.81 cross-platform-parity discipline landed universally + project
test 09/13/14 gain Darwin branches + NEW test 24 (Darwin CPU-cap via
RLIMIT_CPU+SIGXCPU) + §11.4.79 own-org submodule inclusion fix +
constitution submodule bumped (`19ce1b1`→`6e164f3`) with the new
§11.4.81 anchor universal across every consuming project.**

### Added (constitution submodule, pushed `6e164f3`)

- **§11.4.81 — Cross-platform-parity mandate.** Universal anchor + mirror
  blocks in `Constitution.md`, `CLAUDE.md`, `AGENTS.md`, `QWEN.md`.
  Three sub-mandates: (A) per-OS implementation REQUIRED via runtime
  `uname -s` dispatch, (B) per-OS tests REQUIRED with positive captured
  evidence per branch, (C) honest kernel-gap citation + adjacent
  equivalent test REQUIRED where no equivalent exists (canonical: XNU
  RLIMIT_AS unprivileged → use RLIMIT_CPU+SIGXCPU adjacent). Per-OS
  equivalence catalogue listed. Composes with §11.4.1/2/3/4/5/6/20/27/
  69/70 + §107. Pre-build gate `CM-CROSS-PLATFORM-PARITY` planned;
  paired §1.1 mutation: strip a Darwin branch → gate FAILs.

- **Constitution submodule QWEN.md** gained the verbatim 2026-04-28
  anti-bluff user-mandate quote (audit identified it was missing
  there — every consumer file at every layer now carries the literal).

### Added (project)

- **NEW `scripts/tests/24_cpu_cap_enforcement.sh`** — Darwin
  RLIMIT_CPU + SIGXCPU enforcement test. Per §11.4.81 (C) the
  adjacent test for what Linux tests via cgroup MemoryMax (test 12).
  Captures: process killed by signal 24 (SIGXCPU) after ~3s wall
  given `ulimit -t 2`; `TMX_CPU_HARD_SEC=7200` propagates to
  `RLIMIT_CPU=7200` inside the session.

- **NEW `scripts/codegraph_validate.sh`** — §11.4.78 step 4 + §11.4.79
  validate-probe + §11.4.80 sync-script callee. 5 probes: V1 CLI
  version, V2 node count > 0, V3 §11.4.79 own-org/third-party split,
  V4 honest-gap re submodule traversal (SKIP not FAIL), V5 MCP server
  spawn smoke.

### Fixed (project — §11.4.79 + cross-platform parity)

- **A26 — §11.4.79 compliance: own-org submodules removed from
  CodeGraph exclude.** v1.0.4's `.codegraph/config.json` was a §11.4.79
  violation: `constitution/**` + `Containers/**` were excluded. v1.0.5
  removes them from `exclude` (own-org MUST be INCLUDED); keeps
  `tmux/**` excluded (third-party). Honest gap: CodeGraph 0.6.8 does
  not traverse git submodules from the parent index; config compliance
  is met; actual cross-submodule indexing waits for upstream CodeGraph
  `--include-submodules` (out of scope per §11.4.74).

- **A25 — Darwin branches for Linux-only tests (§11.4.81 fix).** Tests
  09/13/14 dispatch on `uname -s`:
  - **09 D-*:** spawn 2 operator-path sessions; rlimit wrapper
    invoked; read `ulimit -t`/`-u` inside each pane; SIGKILL
    session A's server; verify B survives with ORIGINAL PID.
    PASS=6/0/0.
  - **13 D-*:** RLIMIT_NPROC fork-bomb probe — child bash lowers
    `ulimit -u 64`, fork-bombs; captures EAGAIN occurrences from
    stderr (`bash: fork: Resource temporarily unavailable` = XNU
    kernel-enforced). PASS=2/0/0.
  - **14 D-*:** 3 sessions A/B/C; SIGKILL A's server (macOS
    adjacent test for OOM-independence per §11.4.81 (C)); verify
    B+C survive with ORIGINAL PIDs + tmx ls still lists them.
    PASS=5/0/0.

- **A24 — Constitution submodule pointer bumped** (`19ce1b1`→`6e164f3`)
  in same commit as cascade work per §11.4.26 step 7.

### Hardened (4-layer regression protection per §103)

- **Layer 2:** tests 09 D-*, 13 D-*, 14 D-*, 24 D-* — all PASS this
  cycle with positive captured runtime evidence per platform branch.
  Suite total this cycle: PASS=22 SKIP=2 (was 18 PASS / 5 SKIP in
  v1.0.4). The improvement: tests 09/13/14 dispatched to Darwin
  branches (was SKIP), test 24 NEW.
- **Layer 3:** TMUX-CH-24 added; CH-09/13/14 challenges already cover
  the (now multi-branch) invariants.
- **Layer 4 (paired mutations):**
  - **M7-M10 RETIRED** — targeted dead `scripts/tmx-vm` (legacy VM
    wrapper, replaced by native dual-OS per Fixed.md A4-A8). Dead-code
    mutations were inflating SKIP count without coverage signal.
  - **M20 (NEW)** — strip `ulimit -t` from Darwin rlimit wrapper →
    test 15 T5 FAILs. Topology-guarded: Linux uses cgroup (covered
    by M5).
  - **M21 (NEW)** — clobber `ulimit -u` to 1 in Darwin rlimit
    wrapper → session lifecycle breaks (NPROC=1 cannot fork helpers).
    Honest §11.4.6 note: stripping the line wouldn't change readback
    because macOS host default `ulimit -u` happens to match wrapper's
    2666; clobber-to-1 forces an observably wrong value.
  - **M22 (NEW)** — re-exclude `Containers/**` from
    `.codegraph/config.json` → `codegraph_validate.sh` V3 FAILs
    (§11.4.79 violation detected). Caught + restored both directions.

  Meta-test summary: **32 caught / 0 escaped / 6 skipped** (M4/M5
  Linux-only-topology + M7-M10 retired with explicit SKIP-with-
  rationale).

### Verification (this cycle, captured 2026-05-21 on Darwin arm64)

- `bash scripts/setup.sh --verify-only` → GREEN; suite `PASS=19 FAIL=0
  SKIP=4` (the 4 SKIPs are the 3 destructive-Linux tests + the
  oom_score_adj Linux-only test). Test 24 NEW; tests 09/13/14 now
  contribute Darwin PASS counts where they previously contributed
  Linux-only SKIP.
- `bash scripts/tests/meta_test_false_positive_proof.sh` →
  **32 caught / 0 escaped / 6 skipped GREEN**.
- `bash scripts/test_e2e.sh` → GREEN.
- `bash scripts/codegraph_validate.sh` → 4 PASS / 0 FAIL / 1 SKIP
  (the SKIP is V4 honest-gap on submodule traversal).
- `bash scripts/codegraph_reindex.sh` → 6 nodes, stamp written.
- §11.4.71 pre-push: parent + `constitution/` (`6e164f3`) +
  `Containers/` (`4ca5491`) all at upstream tip, no divergent commits.

### Out-of-scope this cycle (honest tracking per §11.4.6)

- §11.4.80 automatic-trigger wiring (cron / git hook for the constitution-
  provided `codegraph_update.sh` + `codegraph_sync.sh`) — deferred to
  next cycle. Manual invocation works today.
- CodeGraph upstream support for `--include-submodules` — out of scope
  per §11.4.74.
- `Containers/QWEN.md` create — separate PR to `vasic-digital/Containers`
  per §11.4.28 owned-submodule equal-codebase mandate.
- Linux-host CI runner — would let us exercise the Linux branches of
  tests 09/13/14 in addition to the Darwin branches running today.

---

## [v1.0.4] — 2026-05-21

**CodeGraph code-intelligence integration (§11.4.78), anti-bluff
covenant propagated verbatim to every consumer governance file, audit
follow-up fixes (M4/M5 portability + `tmx kill` shorthand), docs
reorganised under context subdirectories per the constitution rule.**

### Added

- **A18 — CodeGraph integration (§11.4.78).** Installed
  `@colbymchenry/codegraph` v0.6.8 globally (npm prefix user-writable;
  no sudo per §11.4.78). `codegraph init` + indexed; config tracked
  (`.codegraph/config.json`), DB gitignored (`.codegraph/codegraph.db`).
  §11.4.10 secret-exclusion patterns + §11.4.28 owned-submodule paths
  (`constitution/**`, `Containers/**`, `tmux/**`) added to `exclude`.
  §11.4.77 regeneration mechanism at `.gitignore-meta/codegraph-db.yaml`
  + executable `scripts/codegraph_reindex.sh`. MCP wired for 5 CLI
  agents:
  - Claude Code (project-scoped `.mcp.json`, NEW)
  - OpenCode (`~/.config/opencode/opencode.json`, pre-existing — audited)
  - Kimi CLI (`~/.kimi/mcp.json`, pre-existing — audited)
  - Crush (`.crush.json`, NEW)
  - Qwen Code (`.qwen/settings.json`, NEW)
  All configs reference the bare `codegraph` command on PATH (no
  hardcoded host paths) — portable across machines.

- **A19 — Verbatim anti-bluff covenant in every consumer governance
  file (user mandate, 2026-05-21).** Inserted the literal 2026-04-28
  user-mandate quote into project `CLAUDE.md`, `AGENTS.md`, and
  `QWEN.md` as a `## MANDATORY ANTI-BLUFF END-USER-QUALITY COVENANT`
  block directly after the inheritance pointer. Project
  `Constitution.md` already had it. Tools that don't expand `@imports`
  now still read the covenant.

- **`docs/codegraph/README.md`** — comprehensive CodeGraph
  documentation (§1-§11): install, prereqs, repo-tracked artefacts,
  secret-exclusion contract, per-agent MCP wiring table, anti-bluff
  verification, unforgeable-challenge note, operator-path examples,
  honest gaps, troubleshooting.

- **`docs/plans/v1.0.4.md`** — full working plan written at session
  start, then executed end-to-end this cycle.

- **`scripts/export_docs.sh`** — idempotent §11.4.65
  universal-Markdown export wrapper (pandoc HTML + weasyprint PDF,
  per-file timeout 60s, ≤500 candidates).

### Fixed

- **A20 — M4/M5 paired mutations honest topology dispatch (AUDIT-1).**
  Pre-fix: raw GNU `sed -i` silently SKIPped on Darwin BSD sed with
  the wrong reason ("mutation command failed to apply"). Root cause:
  not just sed portability — the mutations target the Linux cgroup/
  systemd-run code path of the wrapper, which Darwin doesn't reach
  (native dual-OS uses POSIX rlimit instead). Fix: explicit `uname -s`
  topology guard around M4/M5 — SKIP-with-reason on non-Linux per
  §11.4.3; portable `inplace_sed` on Linux.

- **A21 — `tmx kill` shorthand resolves to `kill-session` (AUDIT-2).**
  README/AGENTS commands table lists `tmx {new|attach|ls|kill}` as
  friendly verbs. Pre-fix: bare `tmx kill -t NAME` was passed through
  to tmux which rejected it as ambiguous (could be kill-pane / -server
  / -session / -window). Fix: SUBCMD-translation hook in
  `scripts/tmx.template` detects bare `kill` and rewrites `"$@"` to
  use `kill-session`.

### Hardened (4-layer regression protection per §103)

- **Layer 1 (static gate):** `scripts/verify.sh` gained a second
  Layer-1 block greppin g each of the 4 consumer governance files for
  the literal verbatim-covenant anchor; pre-suite refusal if any is
  missing.
- **Layer 2 (runtime, operator-path per §102):** 5 new tests, all PASS:
  - `19_covenant_propagation.sh` (PASS=7/0/0)
  - `20_codegraph_installed.sh` (PASS=5/0/0)
  - `21_codegraph_index_present.sh` (PASS=4/0/0)
  - `22_codegraph_mcp_wired.sh` (PASS=7/0/0)
  - `23_tmx_kill_shorthand.sh` (PASS=5/0/0)
- **Layer 3 (Challenges):** `TMUX-CH-19` through `TMUX-CH-23` in
  `scripts/challenges/tmux.yaml`.
- **Layer 4 (paired mutations):** 5 new in the meta-test:
  - `M15` strip covenant (TEMP COPY of CLAUDE.md — real file untouched)
  - `M16` strip `**/*.pem` from `.codegraph/config.json`
  - `M17` strip codegraph from `.mcp.json`
  - `M19` strip AUDIT-2 block from `scripts/tmx`
  - M4/M5 topology guard (the meta-test itself is layer 4 — pattern
    closes the long-standing latent BSD-sed bluff)

### Reorganised

Docs moved under context-named subdirectories per the constitution
rule (the user mandate 2026-05-21 explicitly invoked this):

- `docs/GUIDE.md` → `docs/guide/README.md`
- `docs/SCROLLING.md` → `docs/scrolling/README.md`
- `docs/CODEGRAPH.md` → `docs/codegraph/README.md`
- `docs/CONTAINERIZATION_PLAN.md` → `docs/plans/containerization.md`
- `docs/NATIVE_DUAL_OS_PLAN.md` → `docs/plans/native-dual-os.md`
- `docs/PER_SESSION_ISOLATION_PLAN.md` → `docs/plans/per-session-isolation.md`
- `docs/PLAN_v1.0.4.md` → `docs/plans/v1.0.4.md`

Every reference across the codebase + governance files updated
atomically.

### Verification (this cycle, captured 2026-05-21 on Darwin arm64)

- `bash scripts/setup.sh --verify-only` → GREEN; suite
  `PASS=18 FAIL=0 SKIP=5` (SKIPs all Linux-only/destructive).
- `bash scripts/tests/meta_test_false_positive_proof.sh` →
  `26 caught / 0 escaped / 6 skipped` GREEN. The 6 SKIPs are §11.4.3
  topology-correct (M4/M5/M7/M8/M9/M10 — Linux-only mutations).
- `bash scripts/test_e2e.sh` → GREEN.
- `bash scripts/codegraph_reindex.sh` → 6 nodes, stamp written.
- §11.4.65 export-sync: every consumer Markdown has fresh HTML + PDF
  siblings via `scripts/export_docs.sh`.
- §11.4.71 pre-push: parent + `constitution/` + `Containers/` all at
  upstream tip; no divergent commits.

### Out-of-scope this cycle (honest tracking per §11.4.6)

- Upstream `constitution/QWEN.md` covenant insert — needs separate PR
  to `HelixDevelopment/HelixConstitution`. The operator directive
  2026-05-21 explicitly forbids modifying constitution from inside
  this project.
- `Containers/QWEN.md` create — needs separate PR to
  `vasic-digital/Containers` (its own §11.4.28 owned-submodule cycle).
- Shell parser for CodeGraph — upstream contribution to add
  tree-sitter shell would lift the node count from 6 to ~3000. Out
  of scope per §11.4.74; tracked at the upstream project.
- Agent-driven unforgeable-challenge end-to-end test — classified
  `AUTONOMOUS_DESIGNED` per §11.4.52 carve-out (mechanical seam exists
  via test 22 T7; agent-driven layer lands when a headless agent
  harness is wired).

---

## [v1.0.3] — 2026-05-21

**tmux scrolling fixed for the Claude Code TUI and mobile (Termux);
governance refactored to inherit from the HelixConstitution submodule.**

### Fixed

- **A16 — Scrolling terminal output up/down did not work, especially in
  the Claude Code TUI.** Two root causes: (1) the `history-limit`
  default (2000) was too small, and (2) tmux's default `WheelUpPane`
  binding forwards the wheel to applications that request mouse
  reporting (Claude Code, vim, less) — so the wheel never reached
  tmux's own scrollback buffer. `scripts/tmux.conf.template` now:
  - bumps `history-limit` to **50000**;
  - sets `mode-keys vi` for vi-style copy-mode navigation;
  - overrides `WheelUpPane` / `WheelDownPane` so the wheel and
    touch-scroll **always** drive tmux copy-mode scrollback — working
    identically on a desktop mouse, a trackpad, and a phone
    (Termux/Android touch-scroll → wheel events);
  - adds the official Claude Code passthrough settings
    (`allow-passthrough on`, `extended-keys on`,
    `terminal-features 'xterm*:extkeys'`) so Shift+Enter and escape
    sequences reach the application;
  - adds OS-adaptive clipboard routing (pbcopy / wl-copy / xclip /
    termux-clipboard-set, detected at copy time) plus OSC-52.

### Added

- **A17 — HelixConstitution governance submodule + verified inheritance.**
  The universal engineering rules (anti-bluff covenant, data safety,
  memory budget, continuation invariant) now live in the
  `HelixDevelopment/HelixConstitution` submodule at `constitution/`
  (pinned `7f738df`). The project's `Constitution.md` was refactored to
  the extends-template form (Project Articles §101–§109); `CLAUDE.md` /
  `AGENTS.md` gained INHERITED-FROM pointer blocks; a new `QWEN.md` was
  added for the Qwen Code CLI agent. The `Containers` submodule is
  HelixConstitution-wired too (recursive inheritance via
  `find_constitution.sh`).

### Hardened (4-layer regression protection per Constitution §103)

- **Layer 1 (static gate):** `scripts/verify.sh` gained a pre-suite
  static gate that greps `tmux.conf.template` for every scroll setting;
  RED if any is missing.
- **Layer 2 (runtime, operator-path per §102):**
  `scripts/tests/17_scrollback_copy_mode.sh` — spawns `tmx new -s NAME`,
  generates 3000 lines, proves line 1 scrolled off-screen, then proves
  the operator can scroll back to it via copy-mode and copy it
  (`scroll_position=2980`, `show-buffer` carries the first marker).
  PASS=13/0/0. `scripts/tests/18_constitution_inheritance.sh` verifies
  the submodule + the §11.4 anchor + every project doc's pointer.
  PASS=10/0/0.
- **Layer 3 (Challenges):** `TMUX-CH-17` and `TMUX-CH-18` in
  `scripts/challenges/tmux.yaml`.
- **Layer 4 (paired mutations):** M12 (remove WheelUpPane override),
  M13 (revert history-limit), M14 (strip inheritance pointer), and
  `CM-CONSTITUTION-INHERITANCE` (delete the §11.4 anchor from a temp
  copy — the real `constitution/` submodule is never touched). Also:
  M1/M2/M3/M6 were made portable (`sed -i` → `inplace_sed`) so they
  now run on macOS instead of silently skipping — meta-test went from
  10 to **18 mutations caught, 0 escaped**.

### Verification (this cycle, captured 2026-05-21 on Darwin arm64)

- `bash scripts/setup.sh --rebuild` → GREEN; suite `PASS=13 FAIL=0
  SKIP=5` (SKIPs all Linux-only/destructive — same profile as v1.0.0).
- `bash scripts/tests/meta_test_false_positive_proof.sh` →
  `18 caught / 0 escaped / 6 skipped` GREEN.
- `bash scripts/test_e2e.sh` → `PASS=9 FAIL=0 SKIP=0` GREEN.

---

## [v1.0.2] — 2026-05-16

**Cosmetic: window-name strips `.exe` suffix from `pane_current_command`.**

### Fixed

- **A15 — Bottom-left status-bar showed `claude.exe` instead of `claude`**
  (operator-reported, 2026-05-16). Claude Code v2.x ships its macOS
  native binary literally as
  `lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`
  (a real Mach-O 64-bit ARM64 executable). The kernel `comm` field
  carries the on-disk basename, so tmux's `#{pane_current_command}`
  returned `claude.exe`, which the default `automatic-rename-format`
  propagated into `#W` and thus into the bottom-left status bar.
  `scripts/tmux.conf.template` now sets a literal-dot-anchored
  `.exe` strip in `automatic-rename-format`. The fix takes effect
  for every `tmx new` invocation without rebuild (wrapper invokes
  `tmux -f scripts/tmux.conf.template` directly). See `Fixed.md` A15
  for the full forensic record.

### Hardened (4-layer regression protection per §11.4.4)

- **Layer 1 (static gate):** `scripts/tests/16_window_name_strips_exe.sh`
  T1 — greps the conf-template for the literal-dot-anchored form.
- **Layer 2 (runtime, operator-path per §11.4.7):** same test, T2/T3 —
  spawns `tmx new -s NAME`, compiles an in-test `.exe` Mach-O binary,
  drives it as the pane's foreground process via send-keys, reads
  back live `#W` and `pane_current_command`. PASS=6 FAIL=0 SKIP=0.
  Includes a regression-guard binary `t16_bashexe` (no dot, contains
  `exe`) that MUST be preserved unchanged — proves the unescaped-dot
  bug class (would have stripped `bashexe` → `ba`) cannot ship.
- **Layer 3 (Challenge):** `TMUX-CH-16` in `scripts/challenges/tmux.yaml`.
- **Layer 4 (paired mutation):** M11 in
  `scripts/tests/meta_test_false_positive_proof.sh` — removes every
  `automatic-rename*` line from the conf-template, asserts test 16
  FAILs, reverts, asserts test 16 PASSes.

### Verified live (positive runtime evidence, this release cycle)

```
# operator-path validation with real claude binary
tmx new -s tmx_live_5198 -d  +  send-keys "exec .../claude"
→ pane_current_command='claude.exe'   #W='claude'
  ✓ defect surface reached (kernel comm reports 'claude.exe')
  ✓ #W stripped to 'claude' (fix doing the work)

# full verify gate
bash scripts/setup.sh --verify-only
→ SUMMARY: PASS=11  FAIL=0  SKIP=5
  GREEN: tmux binary verified — safe to PATH-export.
  (5 SKIPs = pre-existing Linux-only/destructive: 08, 09, 12, 13, 14.)
```

---

## [v1.0.0] — 2026-05-13

**Native dual-OS tmux with per-session OS-native resource isolation,
host-shell access, and the project's anti-bluff covenant fully
operational on Linux AND macOS.**

This is the initial public release.

### Highlights

- **Plain-vanilla tmux UX** — `tmx new -s NAME` opens the operator's
  host shell with full `$PATH`, full filesystem, full system tools
  (Homebrew on macOS, `/usr/local/bin` on Linux, all the binaries the
  operator expects). No VM, no SSH bridge, no `core@localhost`. The
  session shell IS the operator's host shell.
- **Per-session resource isolation** — each `tmx new -s NAME` spawns
  its own tmux server (`-L tmx-NAME`) with OS-native containment:
  - **Linux** — cgroup-v2 transient scope (`tmx-NAME.scope`) via
    `systemd-run --user --scope`. Kernel-enforced `MemoryMax`,
    `CPUQuota`, `TasksMax`, `Delegate=yes`. OOM in one scope kills
    only that scope; `user.slice` survives.
  - **macOS (Darwin)** — POSIX rlimit wrapper applied as session
    `default-command`. Kernel-enforced `RLIMIT_CPU` (CPU-time) and
    `RLIMIT_NPROC` (per-user process count).
- **Verified hardened tmux 3.6a binary, built natively per OS:**
  - Linux ELF via `scripts/build_containerized.sh` (podman/docker)
    or `scripts/build_native.sh`.
  - macOS Mach-O via `scripts/build_native.sh` (Homebrew deps).
  - Compile flags: `-O2 -DNDEBUG -fstack-protector-strong
    -D_FORTIFY_SOURCE=2`; jemalloc linked at the binary level
    (`DT_NEEDED` on Linux, `LC_LOAD_DYLIB` on Mach-O); RELRO + bind-
    at-load (Linux) / `-Wl,-search_paths_first` (Mach-O).
- **Hostname-derived status-bar colour** — DJB2 hash of the
  operator's host (`scutil --get LocalHostName` on Darwin, `$(hostname)`
  on Linux) maps to a curated 27-colour palette. Same host always
  produces the same colour across every session (proven by Test 11);
  different hosts produce visibly distinct colours (16/16 unique in
  Test 10 T3).
- **14-test verification gate with positive runtime evidence per
  §11.4.2** — `scripts/verify.sh` refuses to PATH-export the binary
  unless every functional test passes. Tests read `/proc/PID/maps`,
  `/sys/fs/cgroup/.../memory.max`, `tmux show -g status-style`,
  `tmux capture-pane -p`, and similar live state. Zero tests close
  on "exit code 0" alone.
- **§11.4.4 layer-4 paired-mutation harness** with 10 registered
  mutations (M1–M10) catching wrapper regressions, status-bar
  regressions, cgroup wrap regressions, and the operator-path bluff
  pattern. `bash scripts/tests/meta_test_false_positive_proof.sh`
  reports 20 PASS / 0 FAIL on Linux.
- **End-to-end automation** — `bash scripts/test_e2e.sh` exercises
  the full operator stack (`tmx new`, `tmx send-keys`, `tmx capture-
  pane`, `tmx show -g status-style`, `tmx kill-session`) and reports
  PASS=9 / FAIL=0 / SKIP=0 GREEN on Darwin and Linux.
- **OS-aware install** — `bash scripts/setup.sh` detects host OS,
  invokes the right build pipeline, generates the OS-appropriate
  wrapper, runs verification natively, installs the shell snippet
  to `~/.bashrc` AND `~/.zshrc`. Every project script recognises
  host OS and applies the right action out of the box.

### Anti-bluff covenant (Constitution §1, §11.4.x)

This release ships under the verbatim user mandate:

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features
> does not work and can't be used! This MUST NOT be the case and
> execution of tests and Challenges MUST guarantee the quality, the
> completion and full usability by end users of the product!"

Every test in `scripts/tests/` carries positive runtime evidence
(`/proc`, `/sys/fs/cgroup`, `vmmap`, `ps -o rss=`, `tmux capture-
pane`, `systemctl is-active`, `display-message`, kernel log lines).
Every Challenge in `scripts/challenges/tmux.yaml` specifies real
runtime state as `evidence:`. Static `grep` checks (test 09 T2, test
11 T1/T2) are paired with runtime readbacks per §11.4.7.

Covenant text propagated to root `Constitution.md`, `CLAUDE.md`,
`AGENTS.md`, and the `Containers` submodule's `CONSTITUTION.md`,
`CLAUDE.md`, `AGENTS.md`.

### Architecture overview

```
                    ┌────────────────────────────────────┐
                    │        OPERATOR SHELL              │
                    │   $ tmx new -s mywork              │
                    │   $ tmx new -s build  ← own scope! │
                    └──────────────────┬─────────────────┘
                                       │
                                       │  scripts/tmx (host-native, OS-aware dispatch)
                                       ▼
            ┌──────────────────────────┴──────────────────────────┐
            │                                                     │
       Linux host                                          macOS host (Darwin)
            │                                                     │
            │ systemd-run --user --scope                          │ tmx-rlimit-wrapper.sh
            │   --unit=tmx-NAME.scope                             │   ulimit -t (RLIMIT_CPU)
            │   -p MemoryMax=… CPUQuota=200%                      │   ulimit -u (RLIMIT_NPROC)
            │   TasksMax=4096 Delegate=yes                        │   exec $SHELL -l
            │   tmux -L tmx-NAME new -s NAME -d                   │
            ▼                                                     ▼
   cgroup-v2 transient scope                            POSIX rlimit wrapper
   (per-group, kernel-enforced)                         (per-process, kernel-enforced)
```

### Forensic transparency

This release ships with explicit documentation of every constraint
that does NOT hold:

- **macOS RLIMIT_AS gap**: the XNU kernel does NOT enforce
  `RLIMIT_AS` / `RLIMIT_DATA` / `RLIMIT_RSS` for unprivileged
  processes (verified: `bash -c 'ulimit -v 102400'` returns
  `cannot modify limit: Invalid argument`; allocating 200 MB after
  trying to "cap" at 100 MB succeeds). The wrapper applies only
  what's enforced (`RLIMIT_CPU`, `RLIMIT_NPROC`). Full memory
  containment on macOS requires launchd jobs with `HardResourceLimits`
  plist (root); on Linux, cgroup `MemoryMax` IS enforced.
- **Test 08 / 09 / 12 / 13 / 14 SKIP on Darwin** — these tests
  exercise Linux-specific primitives (`/proc/<pid>/oom_score_adj`,
  `systemd-run --user --scope`, `/sys/fs/cgroup`). SKIP-with-reason
  per Constitution §11.4.3 (per-host-topology test dispatch).

See `docs/guide/README.md` §5.6 for the full strength-gap table.

### Bluffs caught and fixed during the development cycle

Documented in `Fixed.md`. 24 distinct §1 / §11.4.x bluffs were caught
and remediated before this release, including:

- A1: META-MUT-001 paired-mutation harness landed
- A4: Build pipeline three-defect fix (Dockerfile GID-20 collision,
  jemalloc not actually linked, make-clean missing)
- A6: Install-mechanism side-by-side bluffs (phantom directory path,
  `alias tmux='tmx'` shadowing system tmux, stale ATMOSphere branding)
- A8: macOS bridge + side-by-side coexistence (later superseded by
  native dual-OS in this release)
- A10: Status-bar colour silently defaulted to green; bridge ignored
  macOS hostname
- A11: Triple-layer regression protection so A10 cannot re-occur
- A12: Constitution §11.4.7 — operator-path test coverage rule (every
  gate test MUST exercise the same entry point an end-user invokes)
- A13: Per-session cgroup isolation (each `tmx new -s X` in its own
  scope, OOM in one doesn't kill others)
- A14: This-release verification cycle — fresh runtime evidence
  captured for every claim

### Install

**macOS** (Darwin Apple Silicon or Intel):

```bash
brew install podman  # optional, for build_containerized.sh
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
bash scripts/setup.sh
```

**Linux**:

```bash
git clone --recurse-submodules git@github.com:vasic-digital/tmux.git ~/Projects/tmux
cd ~/Projects/tmux
sudo bash scripts/install_deps.sh
bash scripts/setup.sh
```

After `setup.sh` reports GREEN: open a new shell (`source ~/.zshrc`
or `source ~/.bashrc`). Then `tmx new -s anything` drops you into a
session as your host user with the full host environment and
kernel-enforced resource caps.

### Usage

```bash
tmx new -s mywork             # interactive — attaches
tmx new -s build -d            # detached
tmx ls                         # list all your sessions
tmx attach -t mywork           # re-attach
tmx send-keys -t mywork "echo hello" Enter
tmx capture-pane -t mywork -p
tmx kill-session -t mywork
tmx kill-server                # nuke all our sessions
```

Per-session resource overrides:

```bash
TMX_MEM=8G tmx new -s heavy            # 8 GB MemoryMax (Linux)
TMX_CPU=400 tmx new -s build           # 400% CPUQuota (Linux)
TMX_CPU_HARD_SEC=3600 tmx new -s timeboxed  # 1-hour RLIMIT_CPU (Darwin)
```

### Verification commands

Operators can confirm anti-bluff covenant compliance at any time:

```bash
bash scripts/setup.sh --verify-only   # full 14-test gate → expect GREEN
bash scripts/test_e2e.sh              # end-to-end → expect PASS=9/0/0
TMX_TEST_DESTRUCTIVE=1 bash scripts/test_vm.sh   # Linux destructive suite
META=1 bash scripts/test_vm.sh        # paired-mutation harness
```

### Coexistence with system tmux

`tmx` and the system `tmux` (Homebrew on macOS, distro package on
Linux) coexist side-by-side. The bashrc/zshrc snippet PATH-prepends
`scripts/` so `tmx` is the project's wrapper; `tmux` resolves to
whatever was on PATH before. No alias shadowing.

### Submodules

- `tmux/` — upstream `tmux/tmux` pinned to tag `3.6a` (do not modify).
- `Containers/` — `vasic-digital/Containers` Go module providing
  generic container orchestration primitives. Anti-bluff covenant
  + §11.4.7 propagated. Tag: `b077f2c` at release time.

### Known limitations

- macOS memory cap is per-process via launchd-bsd-style limits
  (informational only — Darwin doesn't enforce `RLIMIT_AS`). For true
  per-session memory containment, run on Linux.
- The destructive test suite (tests 12 / 13 / 14) requires
  `TMX_TEST_DESTRUCTIVE=1` and is Linux-only; on Darwin these SKIP
  per topology dispatch.

### Acknowledgements

Built on the shoulders of:
- `tmux/tmux` upstream (3.6a tag)
- jemalloc (linked at build time)
- libevent + ncurses + utf8proc (Mach-O), libtinfo + libevent_core (ELF)
- systemd-run + cgroup-v2 (Linux isolation primitive)
- Homebrew (macOS dependency provider)

Released under Apache 2.0 (see `LICENSE`).

---

## [v1.0.1] — Unreleased

Post-release development cycle following the v1.0.0 cut.

- VERSION bumped to `1.0.1` / `versionCode=2` to satisfy the operator's
  strictly-increasing-version-code mandate immediately after a release.
- `released=` intentionally blank until the next tag is cut (gate value
  for "not-yet-released"; CI / package builders MUST refuse to publish
  unless `released=` is populated with the cut date).
- No functional code changes in this entry — this is the post-release
  bump itself. Subsequent fixes, refactors, and new features will append
  bullets above this paragraph.
