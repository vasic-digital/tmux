// duplicate_block_test.go — §11.4.115 RED-first guard for cross-file block
// duplication (the §11.4.19 one-item-one-tracker invariant).
//
// THE DEFECT (measured on the live corpus 2026-09-01). Four items — TMX-072..075
// (blocks G1..G4) — exist as FULL blocks in BOTH Issues.md and Fixed.md, with
// identical bodies and the same `**TMX-ID:**`. They are stale leftovers of a
// §11.4.19 atomic migration that copied each block into Fixed.md but never
// removed it from Issues.md.
//
// WHY IT WAS INVISIBLE. Those blocks are space-form headings, which the narrow
// headingRE never parsed, so neither copy ever became a structured item.
//
// WHY IT BITES THE MOMENT THE PARSER IS WIDENED. computeHeadingHash hashes
// (category, code, title) and deliberately does NOT include the file, so both
// copies produce the SAME heading_hash — and heading_hash is NOT NULL UNIQUE.
// The second copy processed therefore binds to the SAME row and UPDATEs it,
// silently COLLAPSING two distinct blocks into one row whose current_location
// is simply whichever file the sync happened to read last. Nothing reported it.
//
// A silent collapse is the §11.4 data-loss class: the corpus said two things,
// the SSoT recorded one, and no verdict said so. Per §11.4.252 the sync must
// FAIL CLOSED on an unresolvable identity instead of picking a winner.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The minimal reproduction: one item id, one block code, one title — present in
// both trackers, exactly as TMX-072 is in the live corpus.
const dupIssues = `# Issues

### G1 WIZARD-SUFFIX-001 — wizard-created sessions get a random suffix

**TMX-ID:** TMX-072
**Type:** Feature
**Status:** Implemented (→ Fixed.md)

Body text that is long enough to serve as a description for this item.
`

const dupFixed = `# Fixed

### G1 WIZARD-SUFFIX-001 — wizard-created sessions get a random suffix — ` + "`IMPLEMENTED`" + `

**TMX-ID:** TMX-072
**Status:** Implemented (→ Fixed.md)
**Type:** Feature
**Severity:** MEDIUM

Body text that is long enough to serve as a description for this item.
`

func writeDupFixtures(t *testing.T) (string, string) {
	t.Helper()
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	if err := os.WriteFile(iss, []byte(dupIssues), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fix, []byte(dupFixed), 0o644); err != nil {
		t.Fatal(err)
	}
	return iss, fix
}

// RED — one item claimed by two files must be REFUSED, never silently collapsed.
func TestSyncMDToDB_RefusesSameItemInBothTrackers(t *testing.T) {
	iss, fix := writeDupFixtures(t)
	db, err := OpenDB(filepath.Join(t.TempDir(), "dup.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	_, err = SyncMDToDB(db, iss, fix)
	if err == nil {
		// Pre-fix behaviour: the sync "succeeds" and one row survives, its
		// location decided by read order. Show that to make the loss concrete.
		items, _ := db.AllItems()
		loc := "<none>"
		if len(items) == 1 {
			loc = items[0].CurrentLocation
		}
		t.Fatalf("RED: sync accepted the same item from BOTH trackers — "+
			"%d row(s) survived, current_location=%q decided by read order; "+
			"the duplicate block was silently discarded", len(items), loc)
	}
	if !strings.Contains(err.Error(), "TMX-072") {
		t.Fatalf("the refusal must NAME the offending item so it is actionable, got: %v", err)
	}
	// §11.4.120 RECONCILED: the guard used to say "in BOTH trackers" because it
	// only compared Issues against Fixed. It now keys on the union of every
	// parsed block, so the message names the two LOCATIONS instead of the
	// cross-file relation. Asserting both filenames is the stronger check — it
	// pins where each copy lives, which "both" never did.
	for _, want := range []string{"Issues.md", "Fixed.md"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("the refusal must name the file holding each copy (missing %q), got: %v", want, err)
		}
	}
}

// IMPORTANT-2 (reviewer mutation M-A): the same id under DIFFERENT block codes.
// The pre-widening guard compared only the id, so this case passed by luck —
// both fixtures happened to use G1. With distinct codes a same-code-only guard
// would let this through, and UpsertItem's TMX-ID fallback would then bind the
// Fixed block onto the Issues row and overwrite it. Keying on the id, never the
// code, is what makes the refusal real.
func TestSyncMDToDB_RefusesSameIDUnderDifferentBlockCodes(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	mustWrite(t, iss, `# Issues

### G1 SPLIT-ID-001 — the open copy, filed under a G-series code

**TMX-ID:** TMX-072
**Type:** Feature
**Status:** Queued

Body text that is long enough to serve as a description for this item.
`)
	mustWrite(t, fix, `# Fixed

### A56 SPLIT-ID-001 — the closed copy, renumbered into the A series — `+"`IMPLEMENTED`"+`

**TMX-ID:** TMX-072
**Status:** Implemented (→ Fixed.md)
**Type:** Feature

Body text that is long enough to serve as a description for this item.
`)
	db, err := OpenDB(filepath.Join(tmp, "splitid.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := SyncMDToDB(db, iss, fix); err == nil {
		items, _ := db.AllItems()
		t.Fatalf("RED: two blocks declaring TMX-072 under codes G1 and A56 were accepted — "+
			"%d row(s) survived; the loser's title/status/body were overwritten silently", len(items))
	} else if !strings.Contains(err.Error(), "TMX-072") {
		t.Fatalf("the refusal must name the duplicated id, got: %v", err)
	}
}

// IMPORTANT-1: two blocks in ONE file declaring the same id. Before UpsertItem
// gained its TMX-ID fallback this died loudly on the UNIQUE constraint; the
// fallback converts it into a silent clobber, so the refusal has to cover the
// same-file case too — not only Issues-vs-Fixed.
func TestSyncMDToDB_RefusesSameIDTwiceWithinOneFile(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	mustWrite(t, iss, `# Issues

### G1 SAME-FILE-001 — the first block claiming this id

**TMX-ID:** TMX-072
**Type:** Feature
**Status:** Queued

Body text that is long enough to serve as a description for this item.

### G2 SAME-FILE-002 — a second block claiming the very same id

**TMX-ID:** TMX-072
**Type:** Feature
**Status:** Queued

Body text that is long enough to serve as a description for this item.
`)
	mustWrite(t, fix, "# Fixed\n")
	db, err := OpenDB(filepath.Join(tmp, "samefile.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := SyncMDToDB(db, iss, fix); err == nil {
		items, _ := db.AllItems()
		t.Fatalf("RED: two blocks in ONE file both declaring TMX-072 were accepted — "+
			"%d row(s) survived; the second block clobbered the first", len(items))
	} else if !strings.Contains(err.Error(), "TMX-072") {
		t.Fatalf("the refusal must name the duplicated id, got: %v", err)
	}
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// FALSE-POSITIVE CONTROL (§11.4.201(1)): the ordinary case — each item in
// exactly ONE tracker — must sync cleanly. A guard that refused every corpus
// would have replaced a data-loss bug with a deadlock.
func TestSyncMDToDB_DistinctItemsPerTrackerStillSync(t *testing.T) {
	tmp := t.TempDir()
	iss := filepath.Join(tmp, "Issues.md")
	fix := filepath.Join(tmp, "Fixed.md")
	if err := os.WriteFile(iss, []byte(`# Issues

### G1 OPEN-ONE-001 — an open item that lives only in Issues

**TMX-ID:** TMX-072
**Type:** Feature
**Status:** Queued

Body text that is long enough to serve as a description for this item.
`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fix, []byte(`# Fixed

### G2 CLOSED-TWO-001 — a closed item that lives only in Fixed — `+"`IMPLEMENTED`"+`

**TMX-ID:** TMX-073
**Status:** Implemented (→ Fixed.md)
**Type:** Feature

Body text that is long enough to serve as a description for this item.
`), 0o644); err != nil {
		t.Fatal(err)
	}
	db, err := OpenDB(filepath.Join(tmp, "ok.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := SyncMDToDB(db, iss, fix); err != nil {
		t.Fatalf("a clean one-item-one-tracker corpus must sync: %v", err)
	}
	items, err := db.AllItems()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 distinct rows, got %d", len(items))
	}
}
