# F1 / A45 — "HelixCode session crashes the whole terminal" — RESOLUTION

**Revision:** 1
**Last modified:** 2026-06-13T18:30:00Z
**Status:** RESOLVED (operator-confirmed "works now", 2026-06-13). Closed to `Fixed.md` A45.

## Root cause (REPRODUCED, not guessed — §11.4.6/§11.4.123)

The installed/generated wrapper `scripts/tmx` had:

```
TMUX_BIN="/Users/milosvasic/Projects/tmux/tmux/build-darwin/bin/tmux"
```

— a path from a PRIOR checkout location that **does not exist** on the live
host (the live checkout is `/Volumes/T7/Projects/tmux`).

The operator's shell-init runs the operator path:

```
exec sh -c 'tmx attach -t HelixCode 2>/dev/null || exec tmx new -s HelixCode'
```

`tmx new -s HelixCode` reaches `exec "$TMUX_BIN" …` (`scripts/tmx.template`
lines 396 / 430) on the MISSING binary → `exec` fails with exit 127 →
the operator's **login shell** (which had `exec`'d into the wrapper chain) is
replaced by the failed exec and **dies** → the terminal window closes =
"crashes the whole terminal." It is the shell dying, so it reproduces
identically on every emulator (iTerm2 / Terminal.app / Linux / WezTerm),
matching the operator's all-emulators report.

## Captured proof (real PTY, this host)

```
$ # current wrapper after v1.0.22 setup.sh
TMUX_BIN="/Volumes/T7/Projects/tmux/tmux/build-darwin/bin/tmux"   exists? YES

$ # bad-TMUX_BIN wrapper driven through the EXACT operator path over a PTY:
PTY EOF — controlling shell DIED (terminal would close = the crash)
child exit status: 127
captured: ".../tmx: line 396: /Users/milosvasic/Projects/tmux/tmux/build-darwin/bin/tmux: No such file or directory"
```

## Why the earlier headless forensics did not catch it

A *fresh* `tmx new -s HelixCode` on THIS checkout (correct `TMUX_BIN`) created +
attached cleanly. The 5 tmux/config-layer crash vectors (passthrough,
extended-keys, attach-reload, rename-format, stale socket) were correctly
DISPROVEN (see `forensic.md`). The defect lived in the **wrapper-generation
layer** (stale `TMUX_BIN`), present in the operator's environment but not on the
fresh checkout the headless tests used.

## Fix

`scripts/setup.sh` regenerates `scripts/tmx` from `scripts/tmx.template`,
substituting the correct `__TMUX_BIN__` for the live checkout. Running v1.0.22
`setup.sh` rewrote the operator's wrapper with the valid path → `exec` succeeds
→ no crash. **Operator-confirmed: "works now."**

## Regression guard (4-layer, §103 / §11.4.135) — so it can NEVER recur silently

| Layer | Artifact | What it catches |
|---|---|---|
| 1 source gate | `verify.sh` `CM-TMX-WRAPPER-TMUXBIN-VALID` | a present `scripts/tmx` whose `TMUX_BIN` path is missing/non-exec → verify/setup REFUSE to bless it |
| 3 runtime | `scripts/tests/60_wrapper_tmux_bin_valid.sh` | T1 static valid; T2 RED reproduces the missing-binary exec failure via the operator path; T3 GREEN valid wrapper creates the session. PASS=3/0/0 ×3 |
| 4 paired mutation | `M-WRAPPER-TMUXBIN` (meta) | rewrite `scripts/tmx` `TMUX_BIN` → missing → test 60 FAILs (CAUGHT). Meta sweep 52/0/8 GREEN |

## Sources verified 2026-06-13

- Reproduced on host (macOS 15.5 / arm64); evidence captured this session.
