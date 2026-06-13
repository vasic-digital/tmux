# QA transcript — copy/paste: terminal owns the mouse by default (v1.0.21)

**Revision:** 1
**Last modified:** 2026-06-13T12:40:00Z
**Run-id:** 2026-06-13-mouse-off-default
**Feature shipped:** `scripts/tmux.conf.template` default `set -g mouse off` —
native terminal selection (multi-line), right-click→Copy, and native scroll
work everywhere (Linux + macOS); tmux mouse on demand via `prefix m`.
**Anti-bluff authority:** §11.4 / §11.4.2 / §11.4.5 / §11.4.50 / §11.4.69 / §11.4.83.

This is the captured runtime evidence that the shipped feature works for the end
user — not metadata, not config-only. Closure entry: `Fixed.md` A43.

---

## 1. Root cause proven at the wire level (the discriminator)

On attach, `mouse on` makes tmux emit mouse-tracking DECSET *enables* to the
outer terminal, which suppresses the terminal's native selection + right-click→
Copy. `mouse off` emits none. Captured over a real PTY attach:

```
mouse on  -> mouse_decset_seen: [('1000','h'), ('1000','l'), ('1002','h'),
             ('1002','l'), ('1003','l'), ('1006','h'), ('1006','l')]   # 3 ENABLES
mouse off -> mouse_decset_seen: [('1000','l'), ('1002','l'), ('1003','l'),
             ('1006','l')]                                             # 0 ENABLES
```

No tmux binding can intercept a terminal's right-click→Copy menu; letting the
terminal own the mouse is the only way select/copy "always" works.

## 2. Layer-3 wire-level test (scripts/tests/59_native_mouse_unobstructed.sh)

Captured PASS (real PTY attach):

```
EVIDENCE: shipped conf default is 'set -g mouse off' (terminal owns the mouse)
EVIDENCE: default attach emitted 0 mouse-enable DECSET (?1000h/?1002h/?1006h) — native selection + right-click->Copy + native scroll UNOBSTRUCTED
EVIDENCE: after 'prefix m' tmux emitted 3 mouse-enable DECSET — tmux scrollback + drag-copy available on demand
PASS: 59 native terminal mouse is unobstructed by default (select + right-click->Copy + scroll), tmux mouse on demand via prefix m
```

RED→GREEN confirmed: against the prior `mouse on` default the same test reported
`default attach emitted 6 mouse-enable DECSET … tmux is capturing the mouse and
suppressing native selection` and FAILed all three contracts.

## 3. Determinism (§11.4.50) — test 57 (reload+select+copy+paste), the test hardened this cycle

```
CLEAN (real sequential suite condition):       57 PASS=10/10 FAIL=0
HOSTILE (continuous adversarial pbcopy noise): 57 PASS=8/8  FAIL=0  (part-D honestly SKIP-layer'd 2× on detected clipboard contention)
```

Never false-PASS (PASS requires the real OS-clipboard token paste); never
false-FAIL (foreign clipboard overwrite → §11.4.3 SKIP-layer, not FAIL).

## 4. Full verification gate (scripts/setup.sh → scripts/verify.sh)

```
SUMMARY: PASS=53  FAIL=0  SKIP=5
  ✓ ~/.tmux.conf installed
```

Includes test 59 PASS and test 17 `T2.3: live server mouse = off by default`.
The gate exposed the binary (PATH-export) only after GREEN — the anti-bluff
covenant in action (the prior run with FAIL=1 correctly REFUSED to install).

## 5. Collateral-regression sweep (§11.4.92 Pass 2)

Tests 01–43, 47, 48 run twice, identical verdicts: **41 PASS / 4 SKIP / 0 FAIL**.
No collateral regression from the mouse-off change. Hostname-color (10/11/25/26)
and cross-platform parity (40) all PASS.

## 6. 4-layer coverage (§103)

| Layer | Artifact | Result |
|---|---|---|
| 1 source gate | `verify.sh` `mouse off (terminal default)` (`^set -g mouse off`) | ✓ present + green |
| 3 runtime | `scripts/tests/59_native_mouse_unobstructed.sh` | ✓ PASS (wire-level) |
| 4 paired mutation | `M-MOUSEDEFAULT` (flip default → `on`) | catches via test 59 (validated post-commit on clean tree) |
| regression | tests 56/57/58 (on-demand path) + 17 + TMUX-CH-17 | ✓ green |

## Sources verified 2026-06-13

- tmux manual `set-clipboard` / `mouse` option semantics: <https://man.openbsd.org/tmux.1> (re-fetched 2026-06-13).
