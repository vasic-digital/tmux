// add_category_validation_test.go — §11.4.115 RED-first guard for the
// category-validation gap surfaced while fixing TMX-093.
//
// THE DEFECT. `headingRE` (parser.go) accepts a block code of exactly ONE
// letter followed by digits: `^###\s+([A-Z])(\d+)(?:\.\s+|\s+)(\S.*)$`.
// `AddItem` (add.go) accepted ANY Category string and merely uppercased it.
// A category that is not a single letter therefore produced a heading the
// parser can NEVER read — measured: "AB" renders `### AB1.` and "1" renders
// `### 11.`, and neither matches headingRE.
//
// WHY IT MATTERS. The row lands in the SSoT, the writer emits its block, and
// the parser silently cannot see it. That is precisely the invisible-block
// class this whole cycle existed to close: the row and its block exist, but no
// heading-form the parser accepts binds them, so the item is untracked in
// every derived document while looking present in the DB.
//
// THE ORACLE (§11.4.245 — DERIVED, structurally independent). The test does
// NOT assert "AddItem returns an error" (tautological — it would pass on any
// error, including a wrong one). It asserts the USER-VISIBLE invariant end to
// end: for every category `add` ACCEPTS, the block the real writer emits MUST
// be readable by the real parser. Rejection and a parseable heading are both
// compliant outcomes; an accepted-but-unparseable row is the defect.
//
// POLARITY SWITCH (§11.4.115). Env RED_MODE, default "1":
//
//	RED_MODE=1 — assert the DEFECT IS PRESENT (some malformed category is
//	             accepted AND yields an unreadable block). PASSES pre-fix.
//	RED_MODE=0 — assert the DEFECT IS ABSENT. FAILS pre-fix (the RED
//	             baseline); PASSES post-fix as the standing guard.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// malformedCategories are inputs that are NOT a single ASCII letter and so
// cannot produce a headingRE-readable block code.
var malformedCategories = []string{"AB", "1", "a-b", "_"}

// categoryProbe reports, for one category, whether AddItem accepted it and
// whether the emitted block was readable by the real parser.
func categoryProbe(t *testing.T, category string) (accepted, parseable bool, heading string) {
	t.Helper()

	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(dir, "add_category.db"))
	if err != nil {
		t.Fatalf("OpenDB: %v", err)
	}
	defer db.Close()

	it, err := AddItem(db, AddItemParams{
		Type:     TypeBug,
		Severity: "High",
		Title:    "category validation probe item",
		Description: "A fixture item whose description clears the §11.4.91 " +
			"clarity floor so AddItem accepts it on the category axis alone.",
		Category: category,
	})
	if err != nil {
		return false, false, ""
	}

	outDir := filepath.Join(dir, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD(category=%q): %v", category, err)
	}
	items, err := ParseFile(filepath.Join(outDir, "Issues.md"), LocationIssues)
	if err != nil {
		t.Fatalf("ParseFile(category=%q): %v", category, err)
	}
	for _, pi := range items {
		if pi.ExplicitATM == it.ATMID {
			return true, true, pi.RawHeading
		}
	}
	return true, false, ""
}

func TestAddRejectsCategoriesThatCannotRenderAReadableBlock(t *testing.T) {
	// Default 0 = standing GREEN regression guard, matching this repo's
	// post-fix convention (scripts/tests/71_root_free_zig_build.sh:62,
	// 73_build_native_localdeps_wiring.sh) and this package's existing Go
	// tests (reconcile_identity_test.go:29). §11.4.115's default-1 applies
	// while the defect is LIVE; once the fix lands, leaving the default at 1
	// would make the package suite permanently FAIL — a §11.4.1 FAIL-bluff.
	// RED_MODE=1 stays available to re-reproduce the defect on a broken
	// artifact, which is how the RED evidence in the closure record was taken.
	redMode := os.Getenv("RED_MODE")
	if redMode == "" {
		redMode = "0"
	}

	type outcome struct {
		category  string
		accepted  bool
		parseable bool
	}
	var bad []outcome
	for _, c := range malformedCategories {
		accepted, parseable, _ := categoryProbe(t, c)
		if accepted && !parseable {
			bad = append(bad, outcome{c, accepted, parseable})
		}
	}

	// Control needle (§11.4.201(7)(b)): a KNOWN-GOOD category must be accepted
	// AND parseable, proving this probe can observe a readable block at all. A
	// probe that reports "unparseable" for every input is blind, and its
	// findings would be meaningless.
	okAccepted, okParseable, okHeading := categoryProbe(t, "A")
	if !okAccepted || !okParseable {
		t.Fatalf("control needle FAILED: category \"A\" accepted=%v parseable=%v — "+
			"the probe cannot observe a readable block, so its verdicts on the "+
			"malformed set prove nothing (§11.4.201 blind instrument)",
			okAccepted, okParseable)
	}
	t.Logf("control needle OK: category \"A\" -> readable block %q", okHeading)

	switch redMode {
	case "1":
		if len(bad) == 0 {
			t.Fatalf("RED_MODE=1: the defect did NOT reproduce — every malformed "+
				"category in %v was either rejected or rendered a readable block. "+
				"A RED that cannot fail on the broken artifact is a blind test "+
				"(§11.4.115 honest boundary).", malformedCategories)
		}
		for _, b := range bad {
			t.Logf("RED_MODE=1 DEFECT REPRODUCED: category %q ACCEPTED by AddItem "+
				"but its emitted block is UNREADABLE by the parser — the row is "+
				"invisible in every derived document.", b.category)
		}
	case "0":
		if len(bad) != 0 {
			for _, b := range bad {
				t.Errorf("category %q is accepted by AddItem but renders a block the "+
					"parser cannot read — add must reject any category that is not a "+
					"single ASCII letter, or render a readable heading for it.", b.category)
			}
			t.FailNow()
		}
	default:
		t.Fatalf("RED_MODE must be \"0\" or \"1\", got %q", redMode)
	}
}
