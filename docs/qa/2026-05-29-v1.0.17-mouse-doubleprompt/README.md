# QA evidence — v1.0.17 mouse-copy + double-prompt fixes (2026-05-29)

**Revision:** 1
**Last modified:** 2026-05-29T11:30:00Z

Captured runtime evidence (§11.4.83) for the two user-reported bug fixes
and the B3 closure. Source mandate (operator, 2026-05-29): mouse
select/copy unusable in tmx panes especially under Claude Code; double
session-name prompt on new bash-login terminals.

| Artefact | Proves |
|---|---|
| `metatest_45caught_0escaped.log` | Paired-mutation harness: 45 CAUGHT / 0 ESCAPED. `M-DBLPROMPT` (double-prompt guard) CAUGHT; `M-MOUSETOGGLE` validated (SKIP on dirty template pre-commit; runs clean post-commit). P5-M20/M21/M22 all CAUGHT (B3 closed). |
| `full_suite_51pass_0fail.log` | `run_all.sh` (correct `TMUX_BIN`): PASS=51 FAIL=0 SKIP=4. Tests 49/50 PASS; test 54 (double-prompt) PASS; test 55 (mouse toggle) PASS; test 56 (real-mouse) honest §11.4.3 SKIP. |
| `iterm2_single_prompt_capture.txt` | Real iTerm2 capture: blank Enter → bare shell, exactly ONE prompt (post-fix single-source behaviour preserved). |

**Reproduction facts (no guessing, §11.4.6):**
- Double-prompt: nezha `bash -l -i` → PROMPT_COUNT=2 (pre-fix), 1 (post-fix). macOS zsh → 1 always.
- Mouse: live Herald server had `mouse on` + M-/S- overrides + working `@clip`→pbcopy; defect was discoverability (tracking-app plain-drag forwarded; iTerm2 `Option Key Sends=Normal` eats Alt-drag).

Tests: `scripts/tests/54_double_prompt_idempotent.sh`,
`55_mouse_toggle_and_copy.sh`, `56_real_mouse_drag_copy.sh`.
Mutations: `M-DBLPROMPT`, `M-MOUSETOGGLE` in
`scripts/tests/meta_test_false_positive_proof.sh`.
