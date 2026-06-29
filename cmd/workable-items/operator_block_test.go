// operator_block_test.go — §11.4.21 operator_block_details population tests.
//
// Forensic anchor: Issues.md F1 (TMX-050) carries `**Status:** Operator-blocked`
// AND a canonical `**Operator-Block-Details:**` block (WHAT / WHY / UNBLOCK
// CONDITION / WHO). The parser stored the status correctly but NEVER populated
// the operator_block_details table, so `workable-items validate` reported a
// §11.4.21 finding (operator_block_details row missing) for the project's first
// Operator-blocked item. These tests pin the population behaviour.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// operatorBlockedFixtureDoc returns an Issues.md fragment containing one
// Operator-blocked item with a multi-line **Operator-Block-Details:** block in
// the canonical sub-fact form used by Issues.md F1.
func operatorBlockedFixtureDoc() string {
	return "# Issues\n\n## F\n\n" +
		"### F1. `tmx` session named \"HelixCode\" crashes the whole terminal\n\n" +
		"**Status:** Operator-blocked\n" +
		"**Type:** Bug\n\n" +
		"Some body text describing the defect in enough words to clear the floor.\n\n" +
		"**Operator-Block-Details:**\n" +
		"- **WHAT:** run `docs/qa/.../diagnose.sh` in the real crashing flow; it\n" +
		"  captures the full attach byte stream read-only and leaves sessions intact.\n" +
		"- **WHY (self-resolution exhausted):** (a) CLI reproduction succeeds;\n" +
		"  (b) subagent forensic deep-dive disproved 5 hypotheses headlessly;\n" +
		"  (c) repo tooling audits all clean.\n" +
		"- **UNBLOCK CONDITION:** the captured typescript byte stream shows the\n" +
		"  malformed/runaway sequence the real session emits.\n" +
		"- **WHO:** operator (milos85vasic.3rd@gmail.com); diagnostic under docs/qa/.\n\n" +
		"---\n"
}

// syncFixtureToTempDB writes the fixture, syncs it into a fresh temp DB, and
// returns the open DB handle (caller must Close) plus the single item's ATMID.
func syncFixtureToTempDB(t *testing.T, doc string) (*DB, string) {
	t.Helper()
	tmp := t.TempDir()
	issuesPath := filepath.Join(tmp, "Issues.md")
	if err := os.WriteFile(issuesPath, []byte(doc), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	dbPath := filepath.Join(tmp, "workable_items.db")
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if _, err := SyncMDToDB(db, issuesPath, ""); err != nil {
		_ = db.Close()
		t.Fatalf("sync md-to-db: %v", err)
	}
	items, err := db.AllItems()
	if err != nil {
		_ = db.Close()
		t.Fatalf("AllItems: %v", err)
	}
	if len(items) != 1 {
		_ = db.Close()
		t.Fatalf("expected exactly 1 synced item, got %d", len(items))
	}
	return db, items[0].ATMID
}

// TestSync_OperatorBlockDetailsPopulated is the RED test: an Operator-blocked
// item with an **Operator-Block-Details:** block MUST produce an
// operator_block_details row capturing WHAT / WHY / UNBLOCK / WHO.
func TestSync_OperatorBlockDetailsPopulated(t *testing.T) {
	db, atmID := syncFixtureToTempDB(t, operatorBlockedFixtureDoc())
	defer db.Close()

	ob, err := db.OperatorBlockDetailsFor(atmID)
	if err != nil {
		t.Fatalf("OperatorBlockDetailsFor: %v", err)
	}
	if ob == nil {
		t.Fatalf("operator_block_details row missing for %s (§11.4.21) — parser did not populate it", atmID)
	}
	if ob.What == "" {
		t.Errorf("operator_block_details.what is empty for %s", atmID)
	}
	if ob.WhyExhaustedAlternatives == "" {
		t.Errorf("operator_block_details.why_exhausted_alternatives is empty for %s", atmID)
	}
	if ob.UnblockCondition == "" {
		t.Errorf("operator_block_details.unblock_condition is empty for %s", atmID)
	}
	if ob.Who == "" {
		t.Errorf("operator_block_details.who is empty for %s", atmID)
	}
}

// TestValidate_OperatorBlockedItemPasses asserts that validate reports ZERO
// §11.4.21 findings once the details row is populated.
func TestValidate_OperatorBlockedItemPasses(t *testing.T) {
	db, atmID := syncFixtureToTempDB(t, operatorBlockedFixtureDoc())
	defer db.Close()

	findings, err := Validate(db)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	for _, f := range findings {
		if f.Section == "§11.4.21" {
			t.Errorf("unexpected §11.4.21 finding for %s: %s", atmID, f.String())
		}
	}
}
