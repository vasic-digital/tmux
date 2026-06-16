# QA evidence — v1.0.23 libtinfo cross-distro fix + test-determinism hardening

**Run-id:** 2026-06-16-libtinfo-crossdistro
**Captured:** 2026-06-16
**Hosts:** nezha.local (ALT Linux 6.12 x86_64) · Mistborn (Darwin arm64)
**Authority:** §11.4 anti-bluff covenant — every PASS below carries real captured runtime output.

---

## 1. Root cause (FACT, not guess — §11.4.6)

The Linux ELF (built in `ubuntu:22.04`) requires versioned terminfo symbols;
the ALT Linux host `libtinfo` has none:

```
# objdump -T tmux  (pre-fix, requires versioned symbols)
(NCURSES6_TINFO_5.0.19991023) setupterm
(NCURSES6_TINFO_5.8.20110226) tiparm
# objdump -T /lib64/libtinfo.so.6  (ALT host — zero NCURSES version nodes)
<empty>
# ldd tmux  (pre-fix) → warning on EVERY invocation:
tmux/build/bin/tmux: /lib64/libtinfo.so.6: no version information available (required by tmux)
```

## 2. Fix proof — nezha (rebuilt binary, post-fix)

```
# ldd tmux/build/bin/tmux   (DT_NEEDED — libtinfo ABSENT, jemalloc PRESENT)
  libjemalloc.so.2 => /lib/x86_64-linux-gnu/libjemalloc.so.2
  libevent_core-2.1.so.7 => ...
  libm.so.6 / libresolv.so.2 / libc.so.6 / libstdc++.so.6 / libgcc_s.so.1
# (no libtinfo.so)

# tmux -V  (UNFILTERED stdout+stderr)
tmux 3.6a
# warning lines: 0           ← was 1 per invocation
# ldd | grep -c libtinfo: 0
```

### Test 61 (regression guard) — nezha
```
PASS: T1 — binary emits no dynamic-loader version/compat warning (Linux)
PASS: T2 — tinfo is statically linked (no host libtinfo.so dependency)
PASS: T3 — jemalloc dynamic linkage preserved (static-tinfo fix did not regress it)
  Tests: PASS=3  FAIL=0  SKIP=0
```

### Test 61 — macOS (Mach-O)
```
PASS: T1 — binary emits no dynamic-loader version/compat warning (Darwin)
SKIP: T2 — libtinfo/ELF symbol-versioning is a Linux-only mechanism (§11.4.81(C))
SKIP: T3 — jemalloc build-time DT_NEEDED check is Linux-ELF-specific
```

### verify.sh gate teeth (CM-NO-DYNAMIC-LIBTINFO)
```
real binary libtinfo deps (PASS): 0
system /bin/tmux libtinfo deps (would FAIL): 1
[PASS] CM-NO-DYNAMIC-LIBTINFO (0 dynamic libtinfo deps — tinfo statically linked)
```

## 3. Full dual-host validation

### nezha — final verify.sh (TMX_TEST_DESTRUCTIVE=1)
```
verify EXIT=0
  SUMMARY: PASS=49  FAIL=0  SKIP=11
  GREEN: tmux binary verified — safe to PATH-export.
```
Tests 12 & 14 RAN (not skipped) with real OOM evidence:
```
PASS: T5.1: kernel OOM-kill detected in dmesg (positive evidence)
PASS: T8.1: kernel OOM-kill detected (positive evidence: memory cgroup out of memory)
```

### nezha — determinism (§11.4.50), tests 12 & 14 ×5
```
12 run1..5: PASS=3 FAIL=0 SKIP=0   (kernel OOM-kill detected every run)
14 run1..5: PASS=8 FAIL=0 SKIP=0   (scopes B/C survived A's OOM, MainPID unchanged)
```

### nezha — meta-test paired-mutation sweep
```
  MUTATIONS CAUGHT (PASS): 52
  MUTATIONS ESCAPED (FAIL): 0
  MUTATIONS SKIPPED:       8
```

### Mistborn (macOS) — full suite (isolated TMPDIR, Mach-O binary)
```
EXIT=0
  SUMMARY: PASS=55  FAIL=0  SKIP=5
  SKIPped: 08_oom_score_adj 12_memory_pressure_under_cap 32_ssh_dispatch_remote_nezha
           56_real_mouse_drag_copy 61_no_libtinfo_version_warning
```

## 4. Test-determinism fixes (RED→GREEN, §11.4.1 / §11.4.43)

| Test | RED (pre-fix) | Cause (FACT) | GREEN (post-fix) |
|---|---|---|---|
| 27 state-persistence (macOS) | FAIL 3/3 — recall returned stale `-target-` path | `sleep 0.4` raced macOS ~1.5 s cwd-update lag after `send-keys cd` | poll until cd reflected → PASS 3/3 |
| 12 memory-pressure (nezha) | FAIL under load — "no OOM-kill in dmesg" | fixed `sleep 2` raced async OOM + `journalctl -k` ingestion lag (dmesg_restrict=1) | poll kernel ring up to ~16 s → PASS 5/5 |
| 14 concurrent-OOM (nezha) | FAIL under load — "no OOM-kill detected" | same async/ingestion race (`sleep 10`) | poll up to ~22 s → PASS 5/5 |

All three are §11.4.1 test-harness timing races (the product worked; the test
sampled too early). Assertions unchanged — a genuinely broken feature still
FAILs after the full timeout.
