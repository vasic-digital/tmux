# Termux Port Feasibility Research — Index

**Revision:** 1
**Last modified:** 2026-05-22T07:20:02Z
**Authority:** vasic-digital tmux project (research-only deliverable, no code changes)
**Maintainer:** milosvasic
**Scope:** Investigate the feasibility of porting the vasic-digital hardened tmux build + `tmx` wrapper + v1.0.9 shell-init / Go state daemon / SSH dispatch features to **Android via Termux**. No implementation work is performed here — this is a future-port planning artefact.

## Why this exists

Today the project supports Linux (cgroup-v2 transient scopes via `systemd-run --user --scope`) and macOS (POSIX `setrlimit` wrapper). Mobile shells via Termux are a recurring operator ask; before we commit engineering effort, §11.4.6 (no-guessing) demands deep web research with cited evidence rather than gut-feel estimation.

Per §11.4.81 (cross-platform-parity) any new platform becomes a first-class citizen with its own honest-gap citation table — this research lays the groundwork.

## Files

| # | File | Topic | Approx. lines |
|---|---|---|---|
| 1 | [`01_environment_overview.md`](01_environment_overview.md) | What Termux is + Android userland constraints | 150 |
| 2 | [`02_build_toolchain.md`](02_build_toolchain.md) | How to produce native binaries (in-Termux build vs NDK cross-compile vs `termux-packages`) | 200 |
| 3 | [`03_runtime_isolation.md`](03_runtime_isolation.md) | The key question — what replaces `systemd-run --user --scope`? (rlimit + honest gap citation) | 250 |
| 4 | [`04_ssh_in_termux.md`](04_ssh_in_termux.md) | Termux's OpenSSH on port 8022 — `command=` directive + `tmx-ssh-dispatch` portability | 150 |
| 5 | [`05_user_experience.md`](05_user_experience.md) | Touch keyboard, wake-lock, F-Droid install, end-user setup | 150 |
| 6 | [`06_constraints_and_gaps.md`](06_constraints_and_gaps.md) | Honest enumeration of WILL-NOT-WORK and WILL-DEGRADE features | 150 |
| 7 | [`07_test_strategy.md`](07_test_strategy.md) | Anti-bluff testing on Android + §11.4.81 four-platform parity table | 150 |
| 8 | [`08_recommendation.md`](08_recommendation.md) | Synthesis: yes / no / conditional + effort estimate | 100 |

Read them in order — each builds on the previous one. §06 + §08 are the operator-actionable summaries.

## Citations

Every non-obvious claim carries a URL. Where verification was incomplete the claim is marked `UNCONFIRMED:` per §11.4.6 (no-guessing mandate).

## Exports

Per §11.4.65, each `.md` file has `.html` + `.pdf` siblings produced by `scripts/export_docs.sh`. If you do not see them next to a file, the export pipeline has not yet been run since that file's last modification — re-run `bash scripts/export_docs.sh` to refresh.
