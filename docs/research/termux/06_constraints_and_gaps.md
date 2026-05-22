# §06 — Honest Constraints and Gaps

**Revision:** 1
**Last modified:** 2026-05-22T07:20:02Z
**Authority:** vasic-digital tmux project (research-only)
**Maintainer:** milosvasic
**Scope:** What will NOT work, and what will work but with degradation, on Termux

---

Per §11.4.6 (no-guessing) and §11.4.81 (cross-platform-parity — honest gap citation), this file enumerates the things that DEMONSTRABLY do not work or degrade on Termux. Each item maps to a specific §11.4.3 topology SKIP-with-reason or to a documented user-action workaround. No speculation. No "should work" — only "verified works", "verified does not work", or `UNCONFIRMED:` with a resolution path.

## 1. WILL NOT WORK — full SKIP-with-reason

### 1.1 systemd-based gates
- **What:** Any test or gate that invokes `systemctl --user`, `systemd-run --user`, `loginctl`, `journalctl`, `systemd-cgls`, `systemd-cgtop`, or queries `/sys/fs/cgroup` writability.
- **Why:** Termux has no systemd. Android does not use it as init. Source: <https://github.com/termux/termux-packages/discussions/17585>.
- **Tests affected (existing suite):** anything that requires the `tmx-supported` classification path branched on systemd-availability. Currently tests 12-14 (the destructive ones) and the cgroup-verification ladder.
- **SKIP reason:** `topology_unsupported: termux-no-systemd`.

### 1.2 cgroup writes from unprivileged userspace
- **What:** writing to `/sys/fs/cgroup/.../cgroup.procs`, `cgroup.subtree_control`, `memory.max`, `cpu.max`, etc.
- **Why:** SELinux denies the write for the `untrusted_app` context that hosts Termux. Source: <https://dev.to/elenbit/unreliable-linux-containers-on-android-addressing-integration-networking-and-stability-for-2p5b>.
- **Workaround:** rooted-only opt-in path (Magisk + `su -c`). Out of scope for default support.
- **SKIP reason:** `topology_unsupported: termux-no-cgroup-write`.

### 1.3 `journalctl`-based diagnostics
- **What:** any check that queries `journalctl -u tmx-NAME.scope` for runtime state.
- **Why:** No systemd → no journal. Termux's analogue is `logcat` (Android's log buffer) or process stderr.
- **Replacement:** for Termux topology, diagnostic queries become `logcat -d -t 100 | grep tmx` or just `tail -n 100 ~/.tmx/log/$NAME.log` if we write a per-session log file.
- **SKIP reason for unconverted tests:** `topology_unsupported: termux-no-journal`.

### 1.4 Privileged port binding
- **What:** anything binding to ports < 1024 from Termux. The default sshd port 22 in our spec must become 8022 on Termux.
- **Why:** Android sandbox denies unprivileged port binding. Same as on Linux/macOS for non-root.
- **Workaround:** use port 8022 (Termux convention); document in operator guide.
- **Impact on `tmx-ssh-install.sh`:** add `--port 8022` flag with autodetect fallback.

### 1.5 setuid binaries
- **What:** any code path expecting a setuid helper. Notably we do NOT have one today — the `tmx-oom-set` helper on Linux is non-suid; it uses ambient capabilities. So no impact, but worth noting.
- **Why:** Android 9+ blocks `setuid()` via seccomp. Source: <https://github.com/termux/termux-packages/wiki/Common-porting-problems>.
- **SKIP reason for any new setuid feature:** `topology_unsupported: android-seccomp-blocks-setuid`.

### 1.6 systemd-style "service restart on failure"
- **What:** running the tmux server as a `--restart=on-failure` unit.
- **Why:** no systemd. Termux has `termux-services` (runit-based) as a packaged alternative — `pkg install termux-services`. That IS a viable path for autorestart, but would require explicit operator opt-in and is NOT what `setup.sh` does today.
- **Workaround:** document `termux-services` as optional power-user feature; default port doesn't include it.

## 2. WILL DEGRADE — partial functionality

### 2.1 OOM protection via `oom_score_adj`
- **What we do:** write `-500` to `/proc/$PID/oom_score_adj` so tmux survives memory pressure.
- **Status:** the FILE write succeeds on Termux (`/proc` is writable for own processes). BUT Android's lmkd maintains its OWN priority table keyed on Android UID, NOT on `oom_score_adj`. When lmkd kicks in (memory pressure), it can `SIGKILL` Termux regardless of our score adjustment.
- **Result:** the write is cosmetic. Real protection requires the operator to disable battery optimization AND grant Termux "high priority" via OEM settings (where available).
- **§11.4.81 honest-gap row:** "Termux: oom_score_adj writable but Android lmkd may override based on app priority."
- Source: <https://source.android.com/docs/core/perf/lmkd>.

### 2.2 Memory cap (`RLIMIT_AS`)
- **Status:** ACTUALLY WORKS on Termux (Linux kernel underneath). Better than macOS.
- **Caveat:** the cap is per-process, not per-cgroup. If tmux forks 100 panes, each can hit the cap independently. Total memory usage is `RLIMIT_AS × N_processes` worst case. On Linux's cgroup model, the cap is shared across all processes in the scope — true ceiling. We lose that.

### 2.3 CPU cap (`RLIMIT_CPU`)
- **Status:** works (CPU seconds, signal-driven, same as macOS).
- **Caveat:** measures cumulative CPU time, not real-time percentage. A long-running interactive session WILL eventually trip the cap and `SIGKILL`. Documented behaviour on macOS today (`TMX_CPU_HARD_SEC=86400` default = 24h). Same on Termux.

### 2.4 Background survival
- **Status:** degrades to "kept alive only with `termux-wake-lock` + battery-opt unrestricted".
- **Failure modes:**
  - Doze freezes CPU; sessions appear hung when screen off (<https://github.com/termux/termux-app/issues/377>).
  - Phantom Process Killer (Android 12+) kills child processes when count > 32 (<https://github.com/termux/termux-app/issues/2366>).
  - OEM-specific killers (MIUI, ColorOS, etc.) may override even Android settings.
- **Workarounds in §05** are user-actionable but cannot be enforced from our side.

### 2.5 OS-level shared `/tmp`
- **Status:** Termux's `/tmp` is `$PREFIX/tmp`, not `/tmp`. Code expecting `/tmp` hard-coded will fail.
- **Impact on us:** our existing code uses `${TMPDIR:-/tmp}` or the user's home for state. UNCONFIRMED — need grep audit of the codebase for raw `/tmp` references. Resolution: grep `/tmp/` literally in `scripts/`.
- **Termux-specific:** also `/tmp` is wiped on app restart (different lifecycle from Linux). Don't store persistent state there.

### 2.6 Phantom Process Killer's 32-child cap on Android 12+
- **What:** Android 12+ kills child processes when more than 32 are seen as "phantom" (children of an app whose parent has gone background). tmux with 6+ windows × 5+ panes = potential trip.
- **Workaround:** ADB toggle to disable, documented for operator. Cannot be set programmatically without root.
- **§11.4.81 honest-gap row:** "Termux on Android 12+: TasksMax is effectively 32 unless ADB-toggled higher".

### 2.7 Concurrent-session `RLIMIT_NPROC` sharing
- **What:** `RLIMIT_NPROC` is per-real-UID. Termux runs all sessions as the same UID. So per-session task caps are not actually isolated.
- **Status:** identical issue exists on macOS today. NOT a Termux regression vs current support matrix.

## 3. WORKS BUT REQUIRES ADAPTATION

### 3.1 tmux itself
- **Status:** works (Termux ships a maintained `tmux` package). Our hardened 3.6a build also compiles cleanly under Termux's bionic toolchain (Termux's recipe is proof).
- **Adaptation:** none for tmux core; potentially adjust `tmux.conf.template` to add Termux-specific keybindings (touch-friendly prefix). Not blocking.

### 3.2 The Go state daemon
- **Status:** works. Stdlib-only Go binary, atomic-file-write + flock, fsync — all are bionic-supported syscalls.
- **Adaptation:** build path (native build inside Termux via `pkg install golang`, OR NDK cross-compile from host per §02).

### 3.3 Shell-init script
- **Status:** works. POSIX-sh / bash 5.x. The `[ -t 0 ] && [ -t 1 ]` non-TTY guard works because sshd-without-PTY doesn't allocate one.
- **Adaptation:** none.

### 3.4 SSH dispatcher
- **Status:** works. Termux's OpenSSH 10.3p1 supports `command=` and propagates `SSH_ORIGINAL_COMMAND` identically to Linux/macOS. (See §04.)
- **Adaptation:** port number — `8022` not `22` — in `tmx-ssh-install.sh` config-block emitter.

### 3.5 Hostname-derived colour
- **Status:** works in principle. `hostname` command exists on Termux (provided by `inetutils` package). `scutil --get LocalHostName` does NOT exist (macOS-only).
- **Adaptation:** Termux branch in `_apply_host_color` should use `getprop net.hostname` or `getprop ro.product.model` as a phone-friendly identifier. Falls back to `$HOSTNAME` env var if neither.

## 4. UNCONFIRMED items requiring real-device verification

These are statements I have HIGH PRIOR CONFIDENCE in based on cited sources, but which I have not directly observed because this is a research-only mission. Each carries a resolution path:

| # | Claim | Resolution |
|---|---|---|
| U1 | `bash -l` follows Termux's documented login chain (`$PREFIX/etc/bash.bashrc` → `~/.bashrc`) | Run `bash -lc 'env | grep TERMUX'` inside Termux after a port lands |
| U2 | `termux-services` (runit) is a viable supervisor for `sshd` autorestart | Operator-side test: `sv up sshd` and observe restart on `pkill sshd` |
| U3 | Build time for our deps on a Snapdragon 8 Gen 2 is in the 5-8 min range | Stopwatch a real on-device build of our setup.sh |
| U4 | Battery drain figures (5-15%/hr active, 2-5%/hr wake-lock-only) | Plug in a phone for 24 hr, run a tmux session with measured workload |
| U5 | `hostname_color.sh` contrast is acceptable against Termux default colours for every hostname hash | Visual check + perhaps an automated contrast-ratio test |
| U6 | OpenSSH's `no-port-forwarding,no-X11-forwarding,no-agent-forwarding` restrictions are honoured by Termux's build | Add explicit restriction-bypass-attempt tests to test 22 |
| U7 | Disk usage post-install is ~600-700 MB | `du -sh ~` after install |
| U8 | The `hostname` command (from `inetutils`) is reliably present on Termux base install | Audit: is it default or does it need `pkg install inetutils`? |
| U9 | Whether the existing scrolling fix (Applied Fix A16) actually works under Termux in 2026 (file was originally noted as "mobile/Termux" compatible) | Run scripts/tests/17_*.sh under Termux |
| U10 | Exact behaviour of `tmx-state-bin`'s `flock` calls on Android tmpfs vs ext4 — should be identical but unverified | flock-contention smoke test on the actual device |

## 5. Carve-outs from existing §11.4.81 cross-platform-parity invariant

For each existing gate test that depends on a Linux primitive, the Termux branch is documented above. Summary of NEW SKIP-with-reasons:

- `topology_unsupported: termux-no-systemd` (for systemd gates)
- `topology_unsupported: termux-no-cgroup-write` (for cgroup-controller gates)
- `topology_unsupported: termux-no-journal` (for journalctl-based diagnostics)
- `feature_disabled_by_config: termux-phantom-killer-active` (test 24-equivalent stress test)

Tests using NEW Termux primitives:
- Add tests for `RLIMIT_AS` actually capping memory (this is a NEW capability vs macOS).
- Add tests for `termux-wake-lock` being held during `tmx new` (operator-facing notice path).

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Android API breakage between major versions (12→13→14→15→16) | Medium | Per-version test breakage | Maintain compatibility matrix, run tests on at least two Android versions |
| Termux maintainer abandonment (less active than 2019-2022) | Low-Medium | Have to maintain our own packages | Path (c) hybrid: rely on `pkg install tmux` for the base, ship our wrapper only |
| F-Droid policy changes blocking Termux distribution | Low | Catastrophic for entire community | Out of our control; would affect everyone, not just us |
| OEM lock-down increasing (Samsung Knox, Google Play Integrity) | Medium | Termux refused or restricted on certain devices | Document supported-device list; provide fallback via cellular SSH-only mode |
| KernelSU / Magisk policy changes affecting rooted opt-in path | Low | Power-user feature degraded | Power-user path is opt-in; degrading it doesn't affect default operator |

## Sources

- <https://github.com/termux/termux-packages/discussions/17585> (systemd absence)
- <https://dev.to/elenbit/unreliable-linux-containers-on-android-addressing-integration-networking-and-stability-for-2p5b> (cgroup access)
- <https://source.android.com/docs/core/perf/lmkd> (lmkd overrides oom_score_adj)
- <https://github.com/termux/termux-app/issues/377> (Doze)
- <https://github.com/termux/termux-app/issues/2366> (Phantom Process Killer)
- <https://maheshtechnicals.com/fix-termux-error-process-completed-signal-9-disable-phantom-process-killer-in-android-12-13/>
- <https://github.com/termux/termux-packages/wiki/Common-porting-problems> (setuid blocked since Android 9)
