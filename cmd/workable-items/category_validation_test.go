// category_validation_test.go — TMX-095 guards.
//
// headingRE (parser.go) accepts a block code of exactly ONE letter followed by
// digits. add.go must therefore refuse any --category that is not a single
// ASCII letter A-Z; otherwise the row lands in the SSoT and its emitted block
// is invisible to every derived document.
//
// POLARITY (§11.4.115): RED_MODE=0 (default) asserts the defect is ABSENT —
// malformed categories are rejected and valid ones accepted. RED_MODE=1
// asserts the defect is PRESENT — some malformed category is accepted. Run
// RED_MODE=1 on a broken (validation-removed) artifact to reproduce the RED.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const categoryFixtureTitle = "category validation guard item"
const categoryFixtureDesc = "Fixture clearing the section 11.4.91 clarity floor so AddItem is decided on the category axis alone."

// addCategoryAttempt returns the AddItem result for one category in a private DB.
func addCategoryAttempt(t *testing.T, category string) (*Item, error) {
	t.Helper()
	dir := t.TempDir()
	db, err := OpenDB(filepath.Join(dir, "category.db"))
	if err != nil {
		t.Fatalf("OpenDB: %v", err)
	}
	defer db.Close()
	return AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "High",
		Title:       categoryFixtureTitle,
		Description: categoryFixtureDesc,
		Category:    category,
	})
}

// validCategoryInputs MUST be accepted. Empty defaults to Z; lowercase folds up.
var validCategoryInputs = []string{"A", "Z", "a", ""}

// malformedCategoryInputs can never render a headingRE-readable block.
var malformedCategoryInputs = []string{"AB", "1", "a-b", "_", "A1", " A ", "EEE"}

func TestAddCategoryValidationMatrix(t *testing.T) {
	mode := os.Getenv("RED_MODE")
	if mode == "" {
		mode = "0"
	}
	if mode != "0" && mode != "1" {
		t.Fatalf("RED_MODE must be 0 or 1, got %q", mode)
	}

	// False-positive guard (§11.4.201(1)): legitimate categories MUST still be
	// accepted in BOTH polarities. A guard that refuses them is a finding.
	for _, c := range validCategoryInputs {
		it, err := addCategoryAttempt(t, c)
		if err != nil {
			t.Errorf("valid category %q was REJECTED: %v", c, err)
			continue
		}
		want := strings.ToUpper(c)
		if want == "" {
			want = "Z"
		}
		if it.Category != want {
			t.Errorf("category %q stored as %q, want %q", c, it.Category, want)
		}
	}

	var acceptedBad []string
	for _, c := range malformedCategoryInputs {
		it, err := addCategoryAttempt(t, c)
		if err == nil {
			acceptedBad = append(acceptedBad, c)
			continue
		}
		if mode == "0" && !strings.Contains(err.Error(), "--category") {
			t.Errorf("malformed category %q rejected with unclear error %q (want --category guidance)", c, err)
		}
		_ = it
	}

	switch mode {
	case "0":
		if len(acceptedBad) != 0 {
			t.Errorf("add ACCEPTED malformed categories %v — they render blocks the parser cannot read", acceptedBad)
		}
	case "1":
		if len(acceptedBad) == 0 {
			t.Fatalf("RED_MODE=1: defect did NOT reproduce — every malformed category was rejected. A RED that cannot fail on the broken artifact is a blind test.")
		}
		t.Logf("RED_MODE=1 DEFECT REPRODUCED: accepted malformed categories %v", acceptedBad)
	}
}

// TestAddedCategoryBlockRoundTrips proves end-to-end that an add-created item
// with a legitimate category is parseable by parser.go. It is
// polarity-independent: it runs against the fixed artifact only.
func TestAddedCategoryBlockRoundTrips(t *testing.T) {
	if os.Getenv("RED_MODE") == "1" {
		t.Skip("RED_MODE=1: broken artifact — round-trip proof belongs to the GREEN path")
	}
	for _, category := range []string{"B", "a", ""} {
		t.Run("category_"+category, func(t *testing.T) {
			dir := t.TempDir()
			db, err := OpenDB(filepath.Join(dir, "roundtrip.db"))
			if err != nil {
				t.Fatalf("OpenDB: %v", err)
			}
			defer db.Close()

			it, err := AddItem(db, AddItemParams{
				Type:        TypeFeature,
				Severity:    "High",
				Title:       categoryFixtureTitle,
				Description: categoryFixtureDesc,
				Category:    category,
			})
			if err != nil {
				t.Fatalf("AddItem(category=%q): %v", category, err)
			}
			outDir := filepath.Join(dir, "out")
			if err := SyncDBToMD(db, outDir); err != nil {
				t.Fatalf("SyncDBToMD: %v", err)
			}
			items, err := ParseFile(filepath.Join(outDir, "Issues.md"), LocationIssues)
			if err != nil {
				t.Fatalf("ParseFile: %v", err)
			}
			found := false
			for _, pi := range items {
				if pi.ExplicitATM == it.ATMID {
					found = true
					if pi.Item.HeadingHash != it.HeadingHash {
						t.Errorf("round-trip hash mismatch: add=%s parser=%s", it.HeadingHash, pi.Item.HeadingHash)
					}
					t.Logf("category %q -> %s (heading %s)", category, it.ATMID, pi.RawHeading)
					break
				}
			}
			if !found {
				t.Fatalf("add-created item %s (category %q) has NO parseable block — the added item is invisible", it.ATMID, category)
			}
		})
	}
}
