// validate_identity_duplicate_test.go — §11.4.115 RED-first guard for two
// defects in markdownBlockOwners (validate_identity.go), both surfaced by
// forensic investigation on 2026-09-01, PLUS the output-level guard proving the
// finding those defects feed actually reaches ValidateBlockIdentity's callers.
//
// DEFECT 1 — FIRST-DECLARER-WINS SILENTLY DISCARDS AN OWNERSHIP ASSERTION.
// markdownBlockOwners records only the first `**TMX-ID:**` seen for a block
// code (`if _, seen := owners[cur]; !seen`). When two blocks in the SAME file
// carry the same code and both declare an id, the second assertion is dropped
// with no finding and no trace. Measured on the live corpus when the defect
// was found (2026-09-01): Fixed.md had 25 blocks declaring a TMX-ID while the
// owner map held only 24 keys — owners["A52"] = TMX-062, and TMX-071's
// assertion was discarded. The audit cannot report a collision it has already
// thrown away. That corpus collision has since been repaired (re-measured
// 2026-09-01 after the repair: Fixed.md has ONE `### A52` heading, 25 owner
// keys, 0 duplicates), which is precisely why the guard below runs against a
// FIXTURE — a guard that only holds while the corpus happens to be dirty stops
// guarding the moment it is cleaned.
//
// DEFECT 2 — THE CURSOR IS NOT RESET BY A NON-BLOCK HEADING.
// A heading line that does NOT match blockOwnerRE (an item-level heading
// written with a name instead of a block code — the corpus has three) leaves
// `cur` pointing at the PREVIOUS block. A `**TMX-ID:**` line appearing under
// such a heading is then attributed to the wrong block. Measured impact today:
// zero, because those three headings carry no id line — but it is a live trap
// the moment the missing id lines are backfilled.
//
// DEFECT 3 (output layer) — THE FINDING MUST REACH THE CALLER. Defects 1 and 2
// are covered at the markdownBlockOwners level, which is one layer BELOW the
// thing that makes the repair user-visible: the loop in ValidateBlockIdentity
// (validate_identity.go:135-148) that turns a returned duplicate map into a
// §11.4.54 Finding. An independent reviewer's mutation deleting that whole loop
// (keeping `issuesDups`/`fixedDups` referenced so the package still compiles)
// left the suite GREEN — the helper-level tests cannot see it, because they
// never call ValidateBlockIdentity. TestValidateBlockIdentity_* below assert on
// the AUDIT'S OWN OUTPUT, which is what a caller actually consumes.
//
// NOT A CROSS-FILE RULE (§11.4.201(1) false-positive guard). The same code in
// DIFFERENT files is LEGITIMATE and pervasive — measured: 9 duplicated codes
// across the corpus, 8 of them Issues-vs-Fixed, which are distinct identities
// because identity is (location, category, ordinal). Only a SAME-FILE
// duplicate whose blocks BOTH declare an id is a collision. A check that
// refused cross-file reuse would refuse the live corpus.
//
// POLARITY SWITCH (§11.4.115 — one source, two roles). These tests use the
// package's existing `redMode()` helper (reconcile_identity_test.go:29), whose
// established convention is RED_MODE=1 → reproduce-and-assert-defect-PRESENT
// (so it FAILs on the repaired artifact, which is the RED baseline), and
// RED_MODE=0 or unset → the standing GREEN regression guard asserting the
// defect is ABSENT. Declaring a second, differently-defaulted switch here would
// fork the package's polarity semantics, so the existing one is used verbatim.
// The cross-file control is deliberately polarity-INDEPENDENT: it is a
// false-positive guard on behaviour that was never defective, so it must hold
// in both polarities.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTemp(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return p
}

// dupFixedMD holds two blocks under one code (A52), both declaring an id, plus
// an ordinary un-duplicated block (A55) that serves as the control needle.
const dupFixedMD = `# Fixed

### A52. first block

**TMX-ID:** TMX-062

body one.

### A52. second block

**TMX-ID:** TMX-071

body two.

### A55. unrelated

**TMX-ID:** TMX-078

body three.
`

// TestMarkdownBlockOwners_SameFileDuplicateIsReported covers DEFECT 1.
func TestMarkdownBlockOwners_SameFileDuplicateIsReported(t *testing.T) {
	path := writeTemp(t, "Fixed.md", dupFixedMD)
	owners, dups, err := markdownBlockOwners(path)
	if err != nil {
		t.Fatalf("markdownBlockOwners: %v", err)
	}

	// Control needle (§11.4.201(7)(b)): the map must see a NON-duplicated block,
	// proving it is not blind before any conclusion is drawn from what it omits.
	// Polarity-independent — it holds in both RED and GREEN.
	if owners["A55"] != "TMX-078" {
		t.Fatalf("control needle FAILED: owners[\"A55\"]=%q want TMX-078 — the "+
			"owner map cannot see an ordinary block, so its verdict on the "+
			"duplicate proves nothing", owners["A55"])
	}

	got := dups["A52"]

	if redMode() {
		if len(got) == 2 {
			t.Fatalf("RED_MODE=1: the defect did NOT reproduce — the duplicate A52 "+
				"IS already reported (%v). A RED that cannot fail on the broken "+
				"artifact is a blind test (§11.4.115 honest boundary).", got)
		}
		t.Logf("RED confirmed: same-file duplicate A52 is NOT reported (dups=%v) — "+
			"the second ownership assertion is silently discarded.", got)
		return
	}

	// RED_MODE=0 — the standing GREEN regression guard.
	if len(got) != 2 {
		t.Fatalf("same-file duplicate code A52 not reported: got %v, want both "+
			"TMX-062 and TMX-071 — the second ownership assertion is being "+
			"silently discarded", got)
	}
	if got[0] != "TMX-062" || got[1] != "TMX-071" {
		t.Errorf("duplicate declarers = %v, want [TMX-062 TMX-071]", got)
	}
}

// TestMarkdownBlockOwners_NonBlockHeadingResetsCursor covers DEFECT 2.
//
// The intervening heading is written at level 4 (`#### `) deliberately: the
// cursor reset must fire for ANY heading level, matching the item parser's own
// window-closing rule (parser.go's anyHeadingRE, `^#{1,6}\s`). A reset keyed to
// the literal `### ` prefix leaves the two components disagreeing about what
// closes an id-scan window, and passes this fixture only by accident of level.
func TestMarkdownBlockOwners_NonBlockHeadingResetsCursor(t *testing.T) {
	path := writeTemp(t, "Fixed.md", `# Fixed

### D1. a real block

body with no id line of its own.

#### NEZHA-INSTALL-v1.0.26-001 (closed) — an item-level heading with no block code

**TMX-ID:** TMX-999

this id belongs to the un-coded heading, NOT to D1.
`)
	owners, _, err := markdownBlockOwners(path)
	if err != nil {
		t.Fatalf("markdownBlockOwners: %v", err)
	}
	got, credited := owners["D1"]

	if redMode() {
		if !credited {
			t.Fatalf("RED_MODE=1: the defect did NOT reproduce — D1 was already NOT " +
				"credited with the id under the un-coded heading. A RED that cannot " +
				"fail on the broken artifact is a blind test (§11.4.115).")
		}
		t.Logf("RED confirmed: D1 was wrongly credited with %q from a `**TMX-ID:**` "+
			"line sitting under a non-block heading.", got)
		return
	}

	// RED_MODE=0 — the standing GREEN regression guard.
	if credited {
		t.Errorf("D1 was credited with %q, but that **TMX-ID:** line sits under a "+
			"non-block heading — the cursor must reset so an un-coded "+
			"heading cannot donate its id to the preceding block", got)
	}
}

// TestMarkdownBlockOwners_CrossFileDuplicateIsNotAFinding is the §11.4.201(1)
// false-positive guard: the same code in a DIFFERENT file is legitimate.
// Polarity-independent — this behaviour was never defective, so it must hold in
// both RED and GREEN.
func TestMarkdownBlockOwners_CrossFileDuplicateIsNotAFinding(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"Issues.md", "Fixed.md"} {
		p := filepath.Join(dir, n)
		if err := os.WriteFile(p, []byte("# x\n\n### A7. a block\n\n**TMX-ID:** TMX-0"+
			map[string]string{"Issues.md": "95", "Fixed.md": "31"}[n]+"\n\nbody.\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		_, dups, err := markdownBlockOwners(p)
		if err != nil {
			t.Fatalf("markdownBlockOwners(%s): %v", n, err)
		}
		if len(dups) != 0 {
			t.Errorf("%s: cross-file code reuse reported as a duplicate (%v) — "+
				"identity is (location, category, ordinal), so A7 in both "+
				"trackers is legitimate and pervasive in the live corpus", n, dups)
		}
	}
}

// writeDupIdentityFixtures lays down an Issues.md with no duplicates and a
// Fixed.md carrying the A52 collision, and returns both paths.
func writeDupIdentityFixtures(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	iss := filepath.Join(dir, "Issues.md")
	fix := filepath.Join(dir, "Fixed.md")
	if err := os.WriteFile(iss, []byte("# Issues\n\n### G5. a clean block\n\n"+
		"**TMX-ID:** TMX-095\n\nbody.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fix, []byte(dupFixedMD), 0o644); err != nil {
		t.Fatal(err)
	}
	return iss, fix
}

// TestValidateBlockIdentity_SameFileDuplicateProducesFinding covers DEFECT 3 —
// the output layer. It asserts on what ValidateBlockIdentity RETURNS, which is
// the only thing a caller (`workable-items validate`) ever sees.
//
// The seeded item is deliberately TMX-062 naming Fixed.md A52, i.e. the FIRST
// declarer: the per-item collision loop therefore produces NO finding for it
// (owner == ATMID), so any finding this test observes can only have come from
// the duplicate-reporting loop under test. Without that separation the test
// could pass on a finding raised by the wrong mechanism.
func TestValidateBlockIdentity_SameFileDuplicateProducesFinding(t *testing.T) {
	iss, fix := writeDupIdentityFixtures(t)
	db := openIDTestDB(t)
	put(t, db, "TMX-062", "A", 52, LocationFixed, StatusFixed)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatalf("ValidateBlockIdentity: %v", err)
	}

	var dupFindings []Finding
	for _, f := range findings {
		if strings.Contains(f.Detail, "is declared by") {
			dupFindings = append(dupFindings, f)
		}
	}

	if redMode() {
		if len(dupFindings) != 0 {
			t.Fatalf("RED_MODE=1: the defect did NOT reproduce — the audit already "+
				"reports the duplicate (%v). A RED that cannot fail on the broken "+
				"artifact is a blind test (§11.4.115).", dupFindings)
		}
		t.Logf("RED confirmed: ValidateBlockIdentity returned %d finding(s), none of "+
			"which reports the A52 one-block-two-owners collision.", len(findings))
		return
	}

	// RED_MODE=0 — the standing GREEN regression guard.
	if len(dupFindings) != 1 {
		t.Fatalf("GREEN guard FAILED: expected exactly 1 duplicate-block finding from "+
			"ValidateBlockIdentity, got %d (all findings: %v). The audit computes the "+
			"duplicate map but never turns it into a Finding, so a one-block-two-owners "+
			"collision is invisible to every caller.", len(dupFindings), findings)
	}
	f := dupFindings[0]
	if f.Section != "§11.4.54" {
		t.Errorf("finding Section = %q, want §11.4.54", f.Section)
	}
	// The Detail must name the FILE, the CODE, and BOTH declarers — an operator
	// cannot act on "there is a collision somewhere" (§11.4.201(5): a refusal
	// reports its resolved evidence).
	for _, want := range []string{"A52", "Fixed.md", "TMX-062", "TMX-071"} {
		if !strings.Contains(f.Detail, want) {
			t.Errorf("finding Detail does not name %q — got %q", want, f.Detail)
		}
	}
}

// TestValidateBlockIdentity_NoDuplicateProducesNoDuplicateFinding is the
// §11.4.201(1) false-positive guard for the test above: a tracker pair with NO
// same-file duplicate must raise NO duplicate finding. Without it, a gate that
// reported a collision unconditionally would pass the RED/GREEN pair while
// refusing every clean corpus. Polarity-independent.
func TestValidateBlockIdentity_NoDuplicateProducesNoDuplicateFinding(t *testing.T) {
	dir := t.TempDir()
	iss := filepath.Join(dir, "Issues.md")
	fix := filepath.Join(dir, "Fixed.md")
	// A7 appears in BOTH files — legitimate cross-file reuse, not a duplicate.
	if err := os.WriteFile(iss, []byte("# Issues\n\n### A7. issues block\n\n"+
		"**TMX-ID:** TMX-095\n\nbody.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fix, []byte("# Fixed\n\n### A7. fixed block\n\n"+
		"**TMX-ID:** TMX-031\n\nbody.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	db := openIDTestDB(t)
	put(t, db, "TMX-095", "A", 7, LocationIssues, StatusQueued)
	put(t, db, "TMX-031", "A", 7, LocationFixed, StatusFixed)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatalf("ValidateBlockIdentity: %v", err)
	}
	for _, f := range findings {
		if strings.Contains(f.Detail, "is declared by") {
			t.Errorf("clean corpus reported a duplicate-block finding: %q — cross-file "+
				"code reuse is legitimate and pervasive in the live corpus", f.Detail)
		}
	}
}
