// validate_identity_test.go — §11.4.115 polarity guard for the §11.4.54
// cross-surface block-identity audit.
//
// RED  (defect present): an item whose stored triple names a block that a
//      different ticket declares MUST be reported. This reproduces the measured
//      2026-09-01 defect: TMX-078 stored {A,50,Fixed} while Fixed.md's `### A50`
//      declared TMX-057.
// GREEN(defect absent): the repaired identity MUST produce no finding.
//
// The false-positive controls are not decoration: each corresponds to a real
// shape in the live corpus that a naive check would wrongly condemn
// (§11.4.201(1) — a wrong refusal is as bad as a missed defect).

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

const idIssuesMD = `# Issues

### G5 SANITIZE-NAME-001 — session names are normalized

**TMX-ID:** TMX-078
**Type:** Feature
**Status:** Queued

### Z9 NO-ID-BLOCK-001 — a block that declares no ticket id

**Type:** Task
`

const idFixedMD = `# Fixed

### A50 GO-TOOLCHAIN-OBTAIN-001 — obtain Go toolchain locally

**TMX-ID:** TMX-057
**Type:** Task
**Status:** Completed (→ Fixed.md)

### B3 SUPERSEDED-BLOCK-001 — one block, a live row and its obsolete predecessor

**TMX-ID:** TMX-054
**Type:** Bug
**Status:** Fixed (→ Fixed.md)
`

func writeIDFixtures(t *testing.T) (string, string) {
	t.Helper()
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	if err := os.WriteFile(iss, []byte(idIssuesMD), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fix, []byte(idFixedMD), 0o644); err != nil {
		t.Fatal(err)
	}
	return iss, fix
}

func openIDTestDB(t *testing.T) *DB {
	t.Helper()
	db, err := OpenDB(filepath.Join(t.TempDir(), "ident.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func put(t *testing.T, db *DB, id, cat string, ord int, loc, status string) {
	t.Helper()
	it := &Item{
		ATMID: id, Type: TypeBug, Status: status,
		Title:           "identity fixture item for the cross-surface audit",
		Description:     "A fixture item long enough to satisfy the description-length invariant.",
		CurrentLocation: loc, Category: cat, CodeOrdinal: ord,
		// Distinct per item: UpsertItem keys on heading_hash, so a shared
		// (e.g. empty) hash silently overwrites the previous fixture row and
		// blinds any control needing two co-existing items.
		HeadingHash: computeHeadingHash(cat, fmt.Sprintf("%s%d", cat, ord), id),
	}
	if err := db.UpsertItem(it); err != nil {
		t.Fatal(err)
	}
}

// RED — the measured defect must be detected.
func TestBlockIdentity_DetectsTwoItemsClaimingOneBlock(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	// TMX-078's stored triple names Fixed.md `### A50`, which declares TMX-057.
	put(t, db, "TMX-078", "A", 50, LocationFixed, StatusQueued)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 1 {
		t.Fatalf("RED: expected exactly 1 identity finding, got %d: %v", len(findings), findings)
	}
	if findings[0].ATMID != "TMX-078" {
		t.Fatalf("RED: finding names %q, want TMX-078", findings[0].ATMID)
	}
}

// GREEN — the repaired identity must produce no finding.
func TestBlockIdentity_RepairedIdentityIsClean(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	// The repair applied to the tracked DB: TMX-078 -> its real block, Issues G5.
	put(t, db, "TMX-078", "G", 5, LocationIssues, StatusQueued)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("GREEN: expected 0 findings after repair, got %v", findings)
	}
}

// False-positive control 1: an Obsolete row may share its successor's block.
// Live in the corpus as TMX-001 (Obsolete) alongside TMX-054, both naming Fixed B3.
func TestBlockIdentity_ObsoleteSupersessionIsNotAFinding(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	put(t, db, "TMX-054", "B", 3, LocationFixed, StatusFixed)
	put(t, db, "TMX-001", "B", 3, LocationFixed, StatusObsolete)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range findings {
		if f.ATMID == "TMX-001" {
			t.Fatalf("false positive: obsolete supersession reported as a collision: %v", f)
		}
	}
}

// False-positive control 2: the ordinal-0 sentinel asserts no block claim.
func TestBlockIdentity_OrdinalZeroSentinelIsNotAFinding(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	put(t, db, "TMX-057", "A", 0, LocationFixed, StatusQueued)

	findings, unlocated, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("false positive: ordinal-0 sentinel reported: %v", findings)
	}
	// The skip's real observable: a sentinel must not be counted as an honest
	// coverage gap either, or the unlocated tally inflates with rows that
	// assert no block claim at all.
	if unlocated != 0 {
		t.Fatalf("ordinal-0 sentinel counted as an unlocated gap (unlocated=%d)", unlocated)
	}
}

// False-positive control 3: a block the parser cannot locate is the known
// heading-form gap — skipped, but counted so it never reads as "all clean".
func TestBlockIdentity_UnlocatedBlockIsCountedNotReported(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	put(t, db, "TMX-999", "Q", 77, LocationIssues, StatusQueued)

	findings, unlocated, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("false positive: unlocated block reported as a collision: %v", findings)
	}
	if unlocated != 1 {
		t.Fatalf("unlocated count = %d, want 1 — the gap must stay visible", unlocated)
	}
}

// False-positive control 4: a block declaring no ticket id asserts no ownership.
func TestBlockIdentity_BlockWithoutIDFieldIsNotAFinding(t *testing.T) {
	iss, fix := writeIDFixtures(t)
	db := openIDTestDB(t)
	put(t, db, "TMX-500", "Z", 9, LocationIssues, StatusQueued)

	findings, _, err := ValidateBlockIdentity(db, iss, fix)
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 0 {
		t.Fatalf("false positive: id-less block reported as a collision: %v", findings)
	}
}
