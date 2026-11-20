// hash_convention_test.go — TMX-093 (§11.4.115 RED/GREEN polarity) guard.
//
// computeHeadingHash(category, code, title) hashes the markdown BLOCK CODE in
// its second argument. parser.go builds that code as category+ordinal
// (code := m[1]+m[2]) and passes it at parser.go:201. add.go MUST derive the
// identical code, otherwise an add-created row cannot bind to the block the
// writer emits for it and survives only through the ExplicitATM rebind path.
//
// The oracle is DERIVED, not tautological (§11.4.245): this test drives the
// REAL add -> render -> parse chain and compares the two hashes. It also
// exercises a non-1 ordinal so a mutation replacing atmOrdinal(atm) with the
// literal 1 is caught.
//
// POLARITY. RED_MODE=0 (default) asserts the defect is ABSENT (hashes agree).
// RED_MODE=1 asserts the defect is PRESENT (hashes diverge) — use on a broken
// artifact to reproduce the RED baseline.

package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// hashConvProbe runs add -> render -> parse and returns the hash add stored,
// the hash the parser derived from the emitted block, and the heading itself.
func hashConvProbe(t *testing.T, category string, ordinal int) (stored, parsed, heading string) {
	t.Helper()

	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(dir, "hash_conv.db"))
	if err != nil {
		t.Fatalf("OpenDB: %v", err)
	}
	defer db.Close()

	if err := db.MetaSet("next_atm_id", strconv.Itoa(ordinal)); err != nil {
		t.Fatalf("seed next_atm_id: %v", err)
	}
	const title = "hash convention guard item"
	it, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "High",
		Title:       title,
		Description: "Fixture clearing the section 11.4.91 clarity floor so AddItem accepts it.",
		Category:    category,
	})
	if err != nil {
		t.Fatalf("AddItem(category=%q): %v", category, err)
	}
	if got := atmOrdinal(it.ATMID); got != ordinal {
		t.Fatalf("seeded ordinal %d but AddItem allocated %s (%d) — ordinal factor untested", ordinal, it.ATMID, got)
	}

	outDir := filepath.Join(dir, "out")
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("SyncDBToMD: %v", err)
	}
	items, err := ParseFile(filepath.Join(outDir, "Issues.md"), LocationIssues)
	if err != nil {
		t.Fatalf("ParseFile: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("want 1 parsed block, got %d", len(items))
	}
	pi := items[0]
	if pi.ExplicitATM != it.ATMID {
		t.Fatalf("parsed block declares %q, want %q", pi.ExplicitATM, it.ATMID)
	}
	return it.HeadingHash, pi.Item.HeadingHash, pi.RawHeading
}

func TestAddAndParserHashConventionAgree(t *testing.T) {
	mode := os.Getenv("RED_MODE")
	if mode == "" {
		mode = "0"
	}
	if mode != "0" && mode != "1" {
		t.Fatalf("RED_MODE must be 0 or 1, got %q", mode)
	}

	cases := []struct {
		name     string
		category string
		ordinal  int
	}{
		{"category A ordinal 1", "A", 1},
		{"category A ordinal 7", "A", 7},
		{"category G ordinal 42", "G", 42},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stored, parsed, heading := hashConvProbe(t, tc.category, tc.ordinal)
			diverged := stored != parsed

			switch mode {
			case "0":
				if diverged {
					t.Errorf("heading_hash convention split PRESENT:\n  heading %s\n  add    %s\n  parser %s\nadd MUST hash the block code (category+ordinal), not the ticket id.", heading, stored, parsed)
				}
			case "1":
				if !diverged {
					t.Fatalf("RED_MODE=1: defect did NOT reproduce — add and parser already agree (%s). A RED that cannot fail on the broken artifact is a blind test.", stored)
				}
				t.Logf("RED_MODE=1 DEFECT REPRODUCED: heading %s | add %s | parser %s", heading, stored, parsed)
			}
		})
	}
}

// TestAddHashEqualsExplicitBlockCode is polarity-independent: it pins the exact
// convention add must use, so an implementation that agrees with the parser by
// accident (e.g. both hashing the ticket id) is still rejected.
func TestAddHashEqualsExplicitBlockCode(t *testing.T) {
	if os.Getenv("RED_MODE") == "1" {
		t.Skip("RED_MODE=1: broken artifact, exact-convention assertion not applicable")
	}
	for _, tc := range []struct{ category string; ordinal int }{{"B", 3}, {"G", 42}} {
		dir := t.TempDir()
		db, err := OpenDB(filepath.Join(dir, "exact.db"))
		if err != nil {
			t.Fatalf("OpenDB: %v", err)
		}
		if err := db.MetaSet("next_atm_id", strconv.Itoa(tc.ordinal)); err != nil {
			t.Fatalf("seed: %v", err)
		}
		const title = "exact block code guard item"
		it, err := AddItem(db, AddItemParams{
			Type:        TypeBug,
			Severity:    "High",
			Title:       title,
			Description: "Fixture clearing the section 11.4.91 clarity floor so AddItem accepts it.",
			Category:    tc.category,
		})
		_ = db.Close()
		if err != nil {
			t.Fatalf("AddItem: %v", err)
		}
		wantCode := tc.category + strconv.Itoa(tc.ordinal)
		want := computeHeadingHash(strings.ToUpper(tc.category), wantCode, title)
		if it.HeadingHash != want {
			t.Errorf("add stored hash %s, want hash over category|%s|title = %s", it.HeadingHash, wantCode, want)
		}
	}
}
