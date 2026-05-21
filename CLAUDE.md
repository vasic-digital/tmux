# vasic-digital tmux — CLAUDE.md

## INHERITED FROM constitution/CLAUDE.md

All rules in `constitution/CLAUDE.md` and the
`constitution/Constitution.md` it references apply **unconditionally** to
this project. Project-specific rules below **extend** them — they do NOT
weaken or override any universal clause. When this file disagrees with
the constitution submodule, **the constitution wins**.

@constitution/CLAUDE.md

## MANDATORY ANTI-BLUFF END-USER-QUALITY COVENANT

**Forensic anchor — verbatim user mandate (2026-04-28, reasserted
2026-05-21):**

> "We had been in position that all tests do execute with success and
> all Challenges as well, but in reality the most of the features does
> not work and can't be used! This MUST NOT be the case and execution
> of tests and Challenges MUST guarantee the quality, the completion
> and full usability by end users of the product!"

**Operative rule.** The bar for shipping is **not** "tests pass" but
**"end users can actually use the feature."** Every PASS — test OR
HelixQA Challenge — MUST carry positive captured runtime evidence that
the feature works for the end user. Metadata-only PASS, configuration-
only PASS, "absence-of-error" PASS, and grep-without-runtime PASS are
all critical defects regardless of how green the summary line looks.
Tests and Challenges are bound EQUALLY.

This covenant is restated verbatim in every governance file at the
consumer layer (`CLAUDE.md`, `AGENTS.md`, `QWEN.md`) so any tool that
does not expand `@imports` still reads it. The same verbatim block lives
upstream at `constitution/Constitution.md` §11.4, `constitution/CLAUDE.md`,
and `constitution/AGENTS.md`. Removing or weakening this block is a
§11.4-class release blocker.

Canonical authority: `constitution/Constitution.md` §11.4 and its
sub-anchors §11.4.1 through §11.4.78. Project anchor:
[`Constitution.md`](Constitution.md) §101.

Non-compliance is a release blocker regardless of context.

> **Read first on a fresh conversation:** `CONTINUATION.md` (§0/§3/§8 are
> mandatory), then `Issues.md` for OPEN/PARTIAL/BLOCKED/RUNNING items.
> Canonical project authority: [`Constitution.md`](Constitution.md)
> (Project Articles §101–§109) which extends `constitution/Constitution.md`.

---

## Project overview

Verified hardened tmux 3.6a build with jemalloc, OOM protection, and
per-session isolation via the `tmx` wrapper. Built around a hard
verification gate that refuses to expose the binary unless functional
tests pass. **Native dual-OS** (since 2026-05-13): runs as a host
process on Linux AND macOS — no VM in the daily-use path. Each
`tmx new -s NAME` creates its own tmux server with OS-native isolation:
cgroup-v2 transient scope (`systemd-run --user --scope`) on Linux; POSIX
rlimit wrapper (`RLIMIT_CPU` + `RLIMIT_NPROC`) on macOS. The session
shell is the operator's host shell with full `$PATH`. Honest gap:
`RLIMIT_AS` (memory) is NOT enforced by XNU for unprivileged processes
— see `docs/guide/README.md` §5.6.

## Critical base rules restated (for sessions that don't expand @imports)

- **No bluffing.** Every PASS — test OR HelixQA Challenge — carries
  positive runtime evidence (cgroup/`/proc` file *content*, `capture-pane`
  output, kernel log lines), never just an exit code. Universal §11.4 /
  Project §101.
- **FAIL-bluffs equally forbidden.** A test that exits FAIL for a
  script bug (not a product defect) is fixed at the source layer, never
  at call sites. Universal §11.4.1.
- **No-guessing.** Never use `likely`/`probably`/`maybe`/`seems`/`appears`
  in cause descriptions — prove with forensic evidence or mark
  `UNCONFIRMED:` / `PENDING_FORENSICS:`. Universal §11.4.6.
- **Operator-path coverage.** Every gate test exercises the SAME entry
  point an end-user invokes (`tmx new -s X`, not hand-spawned
  equivalents). Project §102.
- **Four-layer coverage.** Every defect lands all four layers before the
  cycle closes. Project §103.
- **CONTINUATION.md** updated in the SAME commit as any non-trivial
  state change. Universal §12.10.
- **commit_all.sh only.** Never `git push` directly on the main repo.

## Commands (exact)

| Step | Command |
|---|---|
| Install build deps (one-time; Linux needs root, macOS uses brew) | `bash scripts/install_deps.sh` |
| Full pipeline | `bash scripts/setup.sh` |
| Build only | `bash scripts/setup.sh --build-only` |
| Verify only | `bash scripts/setup.sh --verify-only` |
| Verification gate | `bash scripts/verify.sh` |
| Run all tests | `bash scripts/tests/run_all.sh` |
| Single test | `bash scripts/tests/NN_*.sh` (zero-padded, 01..17) |
| Constitution inheritance gate | `bash scripts/tests/test_constitution_inheritance.sh` |
| Meta-test (paired mutation) | `bash scripts/tests/meta_test_false_positive_proof.sh` |
| Containerized test run (bounded subset) | `bash scripts/test_containerized.sh` |
| VM test run (full suite) | `bash scripts/test_vm.sh` (`TMX_TEST_DESTRUCTIVE=1` for tests 12/13/14; `META=1` for meta-test) |
| End-to-end automation | `bash scripts/test_e2e.sh` |
| Commit + push (github+gitlab) | `bash commit_all.sh "message"` |
| Per-session wrapper | `tmx {new\|attach\|ls\|kill}` |

Never `git push` directly — use `commit_all.sh`.

## Structure

| Path | Role |
|---|---|
| `constitution/` | HelixConstitution submodule — universal governance (pinned `7f738df`) — **do not modify** |
| `tmux/` | upstream submodule (tag `3.6a`) — **do not modify** |
| `Containers/` | vasic-digital cgroup helpers submodule |
| `tmux/build*/` | build output (`.gitignore`'d) |
| `scripts/` | build, verify, install, 17 tests + inheritance gate, challenges, wrapper + conf templates |
| `scripts/tmx` | generated dispatcher (`.gitignore`'d) — from `tmx.template` (Linux) or `tmx-mac.template` (macOS bridge) |
| `scripts/tmux.conf.template` | the tmux config template (scrollback, copy-mode, Claude-Code TUI passthrough, clipboard) |
| `scripts/tests/meta_test_false_positive_proof.sh` | §103 layer-4 paired-mutation harness |
| `scripts/challenges/tmux.yaml` | HelixQA Challenge specs |
| `commit_all.sh` | only allowed push mechanism |
| `Constitution.md` | project authority — Project Articles §101–§109 (extends `constitution/`) |
| `Issues.md` | OPEN / PARTIAL / BLOCKED / RUNNING only |
| `Fixed.md` | RESOLVED items with closure SHA + evidence |
| `CONTINUATION.md` | live handoff state (must stay fresh) |

## Project-specific MANDATORY constraints

### Build / packaging

- `scripts/setup.sh` detects host OS and invokes the right build
  pipeline (Linux ELF / macOS Mach-O) — Project §108.
- `scripts/tmux.conf.template` is the source for the generated tmux
  config; `setup.sh` substitutes OS-specific placeholders (clipboard
  command). Never hand-edit the generated `~/.tmux.conf` / wrapper.

### Test / verification

- **Test-interrupt-on-discovery** (§103): any defect found during a
  test cycle STOPS the cycle. Fix at root cause + land all four layers
  (pre-build gate / runtime test / HelixQA Challenge / paired mutation)
  + rebuild + repeat from the beginning.
- **Operator-path coverage** (§102): gate tests use `tmx new -s X`.
- **Topology dispatch** (§104): tests detect topology and SKIP-with-
  reason — never silently degrade.
- **Destructive tests** (tests 12/13/14): require `TMX_TEST_DESTRUCTIVE=1`
  — run only on dedicated test hosts.
- **Constitution inheritance** is itself gated:
  `scripts/tests/test_constitution_inheritance.sh` + the
  `CM-CONSTITUTION-INHERITANCE` paired mutation.

### Deployment / release

- `bash commit_all.sh "<msg>"` is the ONLY push mechanism — pushes to
  `github` + `gitlab`.
- `VERSION` is the single source of truth (`version=` semver +
  `versionCode=` monotonic). Both bump together with a `CHANGELOG.md`
  entry on every release.

### Project-specific Applied Fixes Reference

| # | Fix | Key files |
|---|---|---|
| A13 | Per-session cgroup isolation (OOM contained per scope) | `scripts/tmx.template` |
| A15 | Status bar showed `claude.exe` — strip `.exe` from window name | `scripts/tmux.conf.template` |
| A16 | tmux scrolling fix for Claude Code TUI + mobile/Termux | `scripts/tmux.conf.template`, `scripts/tests/17_*.sh` |
| A17 | HelixConstitution submodule + verified governance inheritance | `constitution/`, `scripts/tests/test_constitution_inheritance.sh` |

Full forensic detail: `Fixed.md`.

## Files to never edit directly

- `scripts/tmx` — generated by `setup.sh` from `scripts/tmx.template`
- `tmux/build*/` — build output (in `.gitignore`)
- `tmux/` — upstream submodule pinned to tag `3.6a`
- `constitution/` — HelixConstitution submodule (governance authority)

---

## Project overrides of universal rules

None. This project introduces no override of any universal clause.
