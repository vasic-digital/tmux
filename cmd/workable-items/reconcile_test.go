// reconcile_test.go — TMX-060 regression guard (§11.4.43 / §11.4.115 /
// §11.4.135). RED on the pre-fix artifact (db→md replayed the stale verbatim
// document_sources blob, so a `close`d item stayed in Issues.md and never
// migrated to Fixed.md); GREEN after the structured-authoritative reconciler.
//
// §11.4.115 polarity: set RED_MODE=1 to assert the DEFECT is PRESENT (the
// reproduce-on-broken-artifact proof — only passes when reconcileLocations is
// disabled). Default RED_MODE=0 is the standing regression guard asserting the
// defect is ABSENT.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const tmx060IssuesBlob = `# vasic-digital tmux — Open Issues Tracker

> preamble blockquote that the per-item raw_body cannot capture.

## A. Tooling / harness gaps

### A98 KEEP-ME-001 — an open item that must STAY in Issues.md — ` + "`OPEN`" + `

**TMX-ID:** TMX-901
**Status:** ` + "`OPEN`" + `
**Type:** Task
**Severity:** LOW

This open item must remain in Issues.md untouched after a sibling closes.

### A99 MIGRATE-ME-001 — a ready item that must MIGRATE to Fixed.md on close — ` + "`INVESTIGATED`" + `

**TMX-ID:** TMX-902
**Status:** ` + "`Ready for testing`" + `
**Type:** Bug
**Severity:** HIGH

This RICH multi-line body lives ONLY in the document_sources blob (items.raw_body
is empty for add-created items) and MUST be preserved verbatim — including this
second paragraph — when the item migrates to Fixed.md on close.

---

## B. next section

(none open.)
`

const tmx060FixedBlob = `# vasic-digital tmux — Closed Items Tracker

## Items

### A1. a prior closed item — ` + "`RESOLVED`" + `

**Type:** Task
**Status:** Completed (→ Fixed.md)

Prior closed body.
`

// seedTMX060 builds a DB whose document_sources carry the two-blob fixture and
// whose items table holds the two structured items (both at Issues), returning
// the open db + a non-empty evidence file path for close.
func seedTMX060(t *testing.T) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "wi.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.PutDocumentSource(LocationIssues, tmx060IssuesBlob); err != nil {
		t.Fatalf("put issues source: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, tmx060FixedBlob); err != nil {
		t.Fatalf("put fixed source: %v", err)
	}
	// Seed meta.next_atm_id so any allocation path is sane (not used here).
	_ = db.MetaSet("next_atm_id", "903")

	keep := &Item{
		ATMID: "TMX-901", Type: TypeTask, Status: StatusQueued, Severity: "LOW",
		Title: "an open item that must STAY in Issues.md", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 98,
		HeadingHash: computeHeadingHash("A", "A98", "an open item that must STAY in Issues.md"),
	}
	migrate := &Item{
		ATMID: "TMX-902", Type: TypeBug, Status: StatusReadyForTest, Severity: "HIGH",
		Title: "a ready item that must MIGRATE to Fixed.md on close", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 99,
		HeadingHash: computeHeadingHash("A", "A99", "a ready item that must MIGRATE to Fixed.md on close"),
	}
	if err := db.UpsertItem(keep); err != nil {
		t.Fatalf("seed keep: %v", err)
	}
	if err := db.UpsertItem(migrate); err != nil {
		t.Fatalf("seed migrate: %v", err)
	}

	evPath := filepath.Join(tmp, "evidence.log")
	if err := os.WriteFile(evPath, []byte("captured evidence body"), 0o644); err != nil {
		t.Fatalf("write evidence: %v", err)
	}
	return db, evPath
}

// TestTMX060_ClosedItemMigratesAndPreservesBody is the standing regression
// guard: closing TMX-902 (a Bug → status fixed) MUST migrate its full block to
// Fixed.md and remove it from Issues.md, while the unrelated open TMX-901 stays.
func TestTMX060_ClosedItemMigratesAndPreservesBody(t *testing.T) {
	db, evPath := seedTMX060(t)
	defer db.Close()

	if _, err := CloseItem(db, CloseItemParams{
		ATMID: "TMX-902", Status: "fixed", Evidence: evPath,
	}); err != nil {
		t.Fatalf("close TMX-902: %v", err)
	}

	outDir := t.TempDir()
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}
	issues := readFileT(t, filepath.Join(outDir, "Issues.md"))
	fixed := readFileT(t, filepath.Join(outDir, "Fixed.md"))

	redMode := os.Getenv("RED_MODE") == "1"

	migratedOut := strings.Contains(issues, "TMX-902")
	if redMode {
		// On the BROKEN artifact the closed item is STILL in Issues.md.
		if !migratedOut {
			t.Fatalf("RED_MODE: expected the defect (TMX-902 still in Issues.md) but it migrated — fix is active")
		}
		t.Logf("RED_MODE reproduced: closed TMX-902 still present in Issues.md (the bug)")
		return
	}

	// GREEN regression guard.
	if migratedOut {
		t.Errorf("TMX-060 BUG: closed TMX-902 is STILL in regenerated Issues.md (must migrate)")
	}
	if !strings.Contains(fixed, "TMX-902") {
		t.Errorf("TMX-060 BUG: closed TMX-902 did NOT migrate into Fixed.md")
	}
	// Rich operator-authored body preserved verbatim.
	if !strings.Contains(fixed, "including this\nsecond paragraph") {
		t.Errorf("rich multi-line body NOT preserved on migration to Fixed.md")
	}
	// Status rewritten to the terminal value; stale heading hint gone.
	if !strings.Contains(fixed, "**Status:** Fixed (→ Fixed.md)") {
		t.Errorf("migrated block Status line not rewritten to the terminal value")
	}
	if strings.Contains(fixed, "`INVESTIGATED`") {
		t.Errorf("stale `INVESTIGATED` heading hint survived migration")
	}
	if !strings.Contains(fixed, "`RESOLVED`") {
		t.Errorf("migrated heading hint not rewritten to RESOLVED")
	}
	// The unrelated open item stays put.
	if !strings.Contains(issues, "TMX-901") {
		t.Errorf("unrelated open TMX-901 wrongly removed from Issues.md")
	}
	if strings.Contains(fixed, "TMX-901") {
		t.Errorf("unrelated open TMX-901 wrongly migrated to Fixed.md")
	}
	// The kept item's preamble/blockquote survives (no structural rewrite).
	if !strings.Contains(issues, "preamble blockquote that the per-item raw_body cannot capture") {
		t.Errorf("Issues.md preamble lost — reconciler should only move blocks, not regenerate scaffolding")
	}
}

// TestTMX060_NoDriftIsByteIdentical proves the §11.4.93 round-trip invariant:
// with NO close (no structured/blob drift) db→md returns both blobs
// byte-identical.
func TestTMX060_NoDriftIsByteIdentical(t *testing.T) {
	db, _ := seedTMX060(t)
	defer db.Close()

	outDir := t.TempDir()
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}
	issues := readFileT(t, filepath.Join(outDir, "Issues.md"))
	fixed := readFileT(t, filepath.Join(outDir, "Fixed.md"))
	if issues != tmx060IssuesBlob {
		t.Errorf("no-drift Issues.md not byte-identical to source blob\n--got--\n%q\n--want--\n%q", issues, tmx060IssuesBlob)
	}
	if fixed != tmx060FixedBlob {
		t.Errorf("no-drift Fixed.md not byte-identical to source blob\n--got--\n%q\n--want--\n%q", fixed, tmx060FixedBlob)
	}
}

// TestTMX060_ReconcileIdempotent proves a SECOND db→md after the migration
// reproduces identical output (deterministic regeneration §11.4.50).
func TestTMX060_ReconcileIdempotent(t *testing.T) {
	db, evPath := seedTMX060(t)
	defer db.Close()
	if _, err := CloseItem(db, CloseItemParams{ATMID: "TMX-902", Status: "fixed", Evidence: evPath}); err != nil {
		t.Fatalf("close: %v", err)
	}
	out1, out2 := t.TempDir(), t.TempDir()
	if err := SyncDBToMD(db, out1); err != nil {
		t.Fatalf("first db-to-md: %v", err)
	}
	if err := SyncDBToMD(db, out2); err != nil {
		t.Fatalf("second db-to-md: %v", err)
	}
	if a, b := readFileT(t, filepath.Join(out1, "Issues.md")), readFileT(t, filepath.Join(out2, "Issues.md")); a != b {
		t.Errorf("Issues.md not idempotent across two db-to-md runs")
	}
	if a, b := readFileT(t, filepath.Join(out1, "Fixed.md")), readFileT(t, filepath.Join(out2, "Fixed.md")); a != b {
		t.Errorf("Fixed.md not idempotent across two db-to-md runs")
	}
}

func readFileT(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
