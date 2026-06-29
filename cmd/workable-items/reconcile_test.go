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

// === D1 (§11.4.142 review finding — MEDIUM data-integrity) =================
// The pre-fix isBlockBoundaryLine ended a MOVED item block at the FIRST interior
// `---` thematic break OR ANY heading (`#{1,6} `) after the **TMX-ID:** line, so
// a closed item whose verbatim body legitimately contained an interior `---` OR
// a `#### ` sub-heading was SPLIT on migration — only the pre-boundary portion
// moved and the trailing body was ORPHANED in the source file (silent §11.4.108
// SOURCE→ARTIFACT data corruption in a tool that rewrites a 171 KB Fixed.md).
//
// §11.4.115 polarity: RED_MODE=1 asserts the DEFECT is PRESENT on the pre-fix
// boundary logic (post-interior-break body orphaned in Issues.md — the
// reproduce-on-the-broken-artifact proof); default RED_MODE=0 is the standing
// §11.4.135 regression guard asserting the whole block migrates intact.

const d1IssuesBlob = `# vasic-digital tmux — Open Issues Tracker

## A. section with an item whose body has interior structure

### A99 SPLIT-ME-001 — interior break plus a sub-heading must migrate intact — ` + "`INVESTIGATED`" + `

**TMX-ID:** TMX-902
**Status:** ` + "`Ready for testing`" + `
**Type:** Bug
**Severity:** HIGH

PARA_ONE_BEFORE_BREAK first paragraph of the body, before the interior break.

---

#### SUBHEADING_INSIDE_BODY a sub-section legitimately inside the item body

PARA_TWO_AFTER_SUBHEADING second paragraph, after the interior break and the
sub-heading — this is the content the pre-fix logic stranded in Issues.md.

---

## B. next section

(none open.)
`

const d1FixedBlob = `# vasic-digital tmux — Closed Items Tracker

## Items

### A1. a prior closed item — ` + "`RESOLVED`" + `

**Type:** Task
**Status:** Completed (→ Fixed.md)

Prior closed body.
`

func seedD1(t *testing.T) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "wi.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.PutDocumentSource(LocationIssues, d1IssuesBlob); err != nil {
		t.Fatalf("put issues source: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, d1FixedBlob); err != nil {
		t.Fatalf("put fixed source: %v", err)
	}
	_ = db.MetaSet("next_atm_id", "903")
	migrate := &Item{
		ATMID: "TMX-902", Type: TypeBug, Status: StatusReadyForTest, Severity: "HIGH",
		Title: "interior break plus a sub-heading must migrate intact", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 99,
		HeadingHash: computeHeadingHash("A", "A99", "interior break plus a sub-heading must migrate intact"),
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

// TestD1_InteriorBreakAndSubHeadingMigrateIntact is the §11.4.135 standing guard
// for the D1 data-integrity finding: closing TMX-902 MUST migrate its ENTIRE
// verbatim body — including the interior `---` and the `#### ` sub-heading and
// every paragraph after them — to Fixed.md with nothing orphaned in Issues.md.
func TestD1_InteriorBreakAndSubHeadingMigrateIntact(t *testing.T) {
	db, evPath := seedD1(t)
	defer db.Close()

	if _, err := CloseItem(db, CloseItemParams{ATMID: "TMX-902", Status: "fixed", Evidence: evPath}); err != nil {
		t.Fatalf("close TMX-902: %v", err)
	}
	outDir := t.TempDir()
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}
	issues := readFileT(t, filepath.Join(outDir, "Issues.md"))
	fixed := readFileT(t, filepath.Join(outDir, "Fixed.md"))

	// Markers that live AFTER the interior break — exactly what the pre-fix
	// boundary stranded in Issues.md.
	orphanInIssues := strings.Contains(issues, "SUBHEADING_INSIDE_BODY") ||
		strings.Contains(issues, "PARA_TWO_AFTER_SUBHEADING")

	if os.Getenv("RED_MODE") == "1" {
		if !orphanInIssues {
			t.Fatalf("RED_MODE: expected the D1 defect (post-interior-break body orphaned in Issues.md) but the whole block migrated — fix is active")
		}
		t.Logf("RED_MODE reproduced: post-interior-break body (SUBHEADING_INSIDE_BODY / PARA_TWO_AFTER_SUBHEADING) orphaned in Issues.md (the D1 bug)")
		return
	}

	// GREEN regression guard: the ENTIRE body migrates, nothing orphaned.
	if orphanInIssues {
		t.Errorf("D1 BUG: post-interior-break body ORPHANED in Issues.md (block split at the interior `---`/`#### ` sub-heading)")
	}
	for _, marker := range []string{"PARA_ONE_BEFORE_BREAK", "SUBHEADING_INSIDE_BODY", "PARA_TWO_AFTER_SUBHEADING"} {
		if !strings.Contains(fixed, marker) {
			t.Errorf("D1: body marker %q did NOT migrate into Fixed.md (block was split)", marker)
		}
	}
	// The interior sub-heading survives verbatim inside the migrated block.
	if !strings.Contains(fixed, "#### SUBHEADING_INSIDE_BODY") {
		t.Errorf("D1: interior `#### ` sub-heading not preserved verbatim on migration")
	}
	// The closed item is fully gone from Issues.md.
	if strings.Contains(issues, "TMX-902") || strings.Contains(issues, "PARA_ONE_BEFORE_BREAK") {
		t.Errorf("D1: closed TMX-902 not fully removed from Issues.md")
	}
	// The section-terminator `---` + the following section heading STAY in
	// Issues.md (the block boundary must not over-consume the scaffolding).
	if !strings.Contains(issues, "## B. next section") {
		t.Errorf("D1: following section heading wrongly removed from Issues.md (terminator over-consumed)")
	}
}

// === D2 (§11.4.142 review finding — LOW trailing-newline) ===================
// On the last-block-drifts-out / nothing-appended-back path, reconcileLocations
// returned strings.Join(kept,"\n") and lost the file's original trailing newline
// (appendBlocksToDoc only re-adds one when blocks are appended). Triggered when
// the migrating block runs to EOF (dropping the split-sentinel "") AND the line
// before its heading is content (so no blank "" re-adds the newline).

const d2IssuesBlob = `# Tracker
## A. section
### A98 KEEP — ` + "`OPEN`" + `
**TMX-ID:** TMX-901
**Status:** ` + "`OPEN`" + `
**Type:** Task
Body line for the keeper item.
### A99 LAST-MIGRATE — last block, runs to EOF, drifts out — ` + "`INVESTIGATED`" + `
**TMX-ID:** TMX-902
**Status:** ` + "`Ready for testing`" + `
**Type:** Bug
Last body line of the file.
`

func seedD2(t *testing.T) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "wi.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := db.PutDocumentSource(LocationIssues, d2IssuesBlob); err != nil {
		t.Fatalf("put issues source: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, d1FixedBlob); err != nil {
		t.Fatalf("put fixed source: %v", err)
	}
	_ = db.MetaSet("next_atm_id", "903")
	keep := &Item{
		ATMID: "TMX-901", Type: TypeTask, Status: StatusQueued, Severity: "LOW",
		Title: "the keeper item", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 98,
		HeadingHash: computeHeadingHash("A", "A98", "the keeper item"),
	}
	migrate := &Item{
		ATMID: "TMX-902", Type: TypeBug, Status: StatusReadyForTest, Severity: "HIGH",
		Title: "last block runs to EOF and drifts out", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 99,
		HeadingHash: computeHeadingHash("A", "A99", "last block runs to EOF and drifts out"),
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

// TestD2_TrailingNewlinePreservedWhenLastBlockDriftsOut is the §11.4.135 guard
// for the D2 trailing-newline finding. §11.4.115 polarity: RED_MODE=1 asserts
// the DEFECT (Issues.md lost its trailing newline); default RED_MODE=0 asserts
// it is preserved (exactly one).
func TestD2_TrailingNewlinePreservedWhenLastBlockDriftsOut(t *testing.T) {
	db, evPath := seedD2(t)
	defer db.Close()

	if _, err := CloseItem(db, CloseItemParams{ATMID: "TMX-902", Status: "fixed", Evidence: evPath}); err != nil {
		t.Fatalf("close TMX-902: %v", err)
	}
	outDir := t.TempDir()
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}
	issues := readFileT(t, filepath.Join(outDir, "Issues.md"))
	endsWithNL := strings.HasSuffix(issues, "\n")

	if os.Getenv("RED_MODE") == "1" {
		if endsWithNL {
			t.Fatalf("RED_MODE: expected the D2 defect (Issues.md lost its trailing newline) but it is present — fix is active")
		}
		t.Logf("RED_MODE reproduced: Issues.md lost its trailing newline after the last block drifted out (the D2 bug)")
		return
	}

	if !endsWithNL {
		t.Errorf("D2 BUG: Issues.md lost its trailing newline when the last block drifted out and nothing was appended back")
	}
	if strings.HasSuffix(issues, "\n\n") {
		t.Errorf("D2: Issues.md ends with multiple trailing newlines (over-correction)")
	}
	// The keeper survives; the migrating last block is gone.
	if !strings.Contains(issues, "TMX-901") {
		t.Errorf("D2: keeper TMX-901 wrongly removed from Issues.md")
	}
	if strings.Contains(issues, "TMX-902") {
		t.Errorf("D2: migrated TMX-902 still present in Issues.md")
	}
}

// === C1 (§11.4.142 review finding — LOW reopen-direction coverage) ==========
// Only the close direction (Issues→Fixed) was previously tested. This exercises
// the reopen direction (Fixed→Issues): a structurally-reopened item whose
// current_location is now Issues must migrate OUT of the Fixed blob, with its
// body preserved verbatim and the heading-hint + **Status:** rewritten to the
// non-terminal value.

const c1FixedBlob = `# vasic-digital tmux — Closed Items Tracker

## Items

### A1. a prior closed item that STAYS closed — ` + "`RESOLVED`" + `

**TMX-ID:** TMX-801
**Type:** Task
**Status:** Completed (→ Fixed.md)

This closed item stays in Fixed.md.

---

### A2. a closed item that gets REOPENED and must migrate back to Issues — ` + "`RESOLVED`" + `

**TMX-ID:** TMX-802
**Type:** Bug
**Status:** Fixed (→ Fixed.md)

REOPEN_BODY_MARKER this rich operator-authored body must migrate back to
Issues.md verbatim when the item is reopened.
`

const c1IssuesBlob = `# vasic-digital tmux — Open Issues Tracker

## A. open work

(none open yet.)
`

func TestC1_ReopenedItemMigratesFixedToIssues(t *testing.T) {
	tmp := t.TempDir()
	db, err := OpenDB(filepath.Join(tmp, "wi.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	if err := db.PutDocumentSource(LocationIssues, c1IssuesBlob); err != nil {
		t.Fatalf("put issues source: %v", err)
	}
	if err := db.PutDocumentSource(LocationFixed, c1FixedBlob); err != nil {
		t.Fatalf("put fixed source: %v", err)
	}
	stay := &Item{
		ATMID: "TMX-801", Type: TypeTask, Status: StatusCompleted,
		Title: "a prior closed item that STAYS closed", CurrentLocation: LocationFixed,
		Category: "A", CodeOrdinal: 1,
		HeadingHash: computeHeadingHash("A", "A1", "a prior closed item that STAYS closed"),
	}
	reopened := &Item{
		ATMID: "TMX-802", Type: TypeBug, Status: StatusReopened,
		Title: "a closed item that gets REOPENED and must migrate back to Issues", CurrentLocation: LocationIssues,
		Category: "A", CodeOrdinal: 2,
		HeadingHash: computeHeadingHash("A", "A2", "a closed item that gets REOPENED and must migrate back to Issues"),
	}
	if err := db.UpsertItem(stay); err != nil {
		t.Fatalf("seed stay: %v", err)
	}
	if err := db.UpsertItem(reopened); err != nil {
		t.Fatalf("seed reopened: %v", err)
	}

	outDir := t.TempDir()
	if err := SyncDBToMD(db, outDir); err != nil {
		t.Fatalf("db-to-md: %v", err)
	}
	issues := readFileT(t, filepath.Join(outDir, "Issues.md"))
	fixed := readFileT(t, filepath.Join(outDir, "Fixed.md"))

	// Reopened item migrated Fixed → Issues, rich body preserved verbatim.
	if !strings.Contains(issues, "TMX-802") || !strings.Contains(issues, "REOPEN_BODY_MARKER") {
		t.Errorf("C1: reopened TMX-802 did NOT migrate back into Issues.md with its body")
	}
	if strings.Contains(fixed, "TMX-802") {
		t.Errorf("C1: reopened TMX-802 still present in Fixed.md (must move out)")
	}
	// The genuinely-closed item stays in Fixed.md, never leaks to Issues.md.
	if !strings.Contains(fixed, "TMX-801") {
		t.Errorf("C1: closed TMX-801 wrongly removed from Fixed.md")
	}
	if strings.Contains(issues, "TMX-801") {
		t.Errorf("C1: closed TMX-801 wrongly migrated to Issues.md")
	}
	// Heading-hint + Status line rewritten to the non-terminal value.
	if !strings.Contains(issues, "**Status:** Reopened") {
		t.Errorf("C1: migrated block Status line not rewritten to the non-terminal value")
	}
	if !strings.Contains(issues, "`Reopened`") {
		t.Errorf("C1: migrated heading hint not rewritten to `Reopened`")
	}
	if strings.Contains(issues, "`RESOLVED`") {
		t.Errorf("C1: stale `RESOLVED` heading hint survived the reopen migration")
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
