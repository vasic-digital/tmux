// set_status_test.go — §11.4.43 RED→GREEN coverage for `set-status` (TMX-066).
//
// Before this command existed the ONLY way to move an item to a non-terminal
// status was a hand-written `sqlite3 UPDATE` (no §11.4.34 audit row, an
// out-of-band §11.4.93 SSoT edit). These tests are the regression guard that the
// command (a) sets the status + last_modified, (b) appends an audited "Updated"
// history row, (c) rejects terminal statuses (pointing to `close`), and
// (d) rejects unknown statuses rather than silently defaulting (§11.4.6).

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func newSeededDB(t *testing.T) (*DB, *Item) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "wi.db")
	db, err := OpenDB(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	it, err := AddItem(db, AddItemParams{
		Type:        TypeBug,
		Severity:    "MEDIUM",
		Title:       "Seed item for set-status coverage",
		Description: "A seeded workable item used to exercise the set-status transition path.",
		Category:    "Z",
	})
	if err != nil {
		t.Fatalf("seed item: %v", err)
	}
	if it.Status != StatusQueued {
		t.Fatalf("seed item must start Queued, got %q", it.Status)
	}
	return db, it
}

// TestSetStatus_UpdatesStatusAndWritesAuditRow is the core RED→GREEN.
func TestSetStatus_UpdatesStatusAndWritesAuditRow(t *testing.T) {
	db, it := newSeededDB(t)

	updated, err := SetStatus(db, SetStatusParams{
		ATMID:  it.ATMID,
		Status: "in-progress",
		By:     "AI",
		Reason: "began work on the fix",
	})
	if err != nil {
		t.Fatalf("set-status: %v", err)
	}
	if updated.Status != StatusInProgress {
		t.Errorf("status: got %q, want %q", updated.Status, StatusInProgress)
	}

	// Re-read from DB to prove persistence (not just the in-memory struct).
	reread, err := db.GetItem(it.ATMID)
	if err != nil {
		t.Fatalf("re-read: %v", err)
	}
	if reread.Status != StatusInProgress {
		t.Errorf("persisted status: got %q, want %q", reread.Status, StatusInProgress)
	}
	if reread.LastModified == "" {
		t.Errorf("last_modified was not written")
	}

	// An audited "Updated" history row must exist (§11.4.34).
	hist, err := db.HistoryFor(it.ATMID)
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	var foundUpdated bool
	for _, ev := range hist {
		if ev.EventType == "Updated" && ev.By == "AI" && ev.Reason == "began work on the fix" {
			foundUpdated = true
		}
	}
	if !foundUpdated {
		t.Errorf("no audited 'Updated' history row found; history=%+v", hist)
	}
}

// TestSetStatus_RejectsTerminalStatus — terminal values must route through close.
func TestSetStatus_RejectsTerminalStatus(t *testing.T) {
	db, it := newSeededDB(t)
	for _, term := range []string{"fixed", "implemented", "completed", "obsolete",
		StatusFixed, StatusImplemented, StatusCompleted, StatusObsolete} {
		if _, err := SetStatus(db, SetStatusParams{ATMID: it.ATMID, Status: term}); err == nil {
			t.Errorf("set-status %q: expected an error (terminal), got nil", term)
		}
	}
	// And the item's status must be unchanged (still Queued).
	reread, _ := db.GetItem(it.ATMID)
	if reread.Status != StatusQueued {
		t.Errorf("rejected set-status mutated the item: got %q, want %q", reread.Status, StatusQueued)
	}
}

// TestSetStatus_RejectsUnknownStatus — §11.4.6: no silent default.
func TestSetStatus_RejectsUnknownStatus(t *testing.T) {
	db, it := newSeededDB(t)
	if _, err := SetStatus(db, SetStatusParams{ATMID: it.ATMID, Status: "totally-bogus"}); err == nil {
		t.Errorf("expected an error for an unknown status, got nil")
	}
}

// TestSetStatus_AcceptsTokensAndCanonical — token + canonical equivalence.
func TestSetStatus_AcceptsTokensAndCanonical(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"queued", StatusQueued},
		{"in-progress", StatusInProgress},
		{"In progress", StatusInProgress},
		{"ready", StatusReadyForTest},
		{"ready-for-testing", StatusReadyForTest},
		{"Ready for testing", StatusReadyForTest},
		{"in-testing", StatusInTesting},
		{"In testing", StatusInTesting},
		{"reopened", StatusReopened},
		{"Reopened", StatusReopened},
		{"blocked", StatusOperatorBlock},
		{"operator-blocked", StatusOperatorBlock},
		{"Operator-blocked", StatusOperatorBlock},
	}
	for _, c := range cases {
		got, err := mapSetStatusToken(c.in)
		if err != nil {
			t.Errorf("mapSetStatusToken(%q): unexpected error %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("mapSetStatusToken(%q): got %q, want %q", c.in, got, c.want)
		}
	}
}

// TestSetStatus_MissingItem — unknown ATM id is an error, not a silent no-op.
func TestSetStatus_MissingItem(t *testing.T) {
	db, _ := newSeededDB(t)
	if _, err := SetStatus(db, SetStatusParams{ATMID: "TMX-99999", Status: "in-progress"}); err == nil {
		t.Errorf("expected an error for a missing item, got nil")
	}
}

// TestSetStatus_ReopenMigratesBackToIssues — a closed item set to a non-terminal
// status (Reopened) must move its current_location back to Issues.
func TestSetStatus_ReopenMigratesBackToIssues(t *testing.T) {
	db, it := newSeededDB(t)
	// Close it first (write an evidence file so close.go accepts it).
	ev := filepath.Join(t.TempDir(), "evidence.txt")
	if err := os.WriteFile(ev, []byte("captured evidence for the close"), 0o644); err != nil {
		t.Fatalf("write evidence: %v", err)
	}
	if _, err := CloseItem(db, CloseItemParams{ATMID: it.ATMID, Status: "fixed", Evidence: ev}); err != nil {
		t.Fatalf("close: %v", err)
	}
	closed, _ := db.GetItem(it.ATMID)
	if closed.CurrentLocation != LocationFixed {
		t.Fatalf("precondition: closed item should be in Fixed, got %q", closed.CurrentLocation)
	}
	// Reopen via set-status.
	if _, err := SetStatus(db, SetStatusParams{ATMID: it.ATMID, Status: "reopened", By: "User", Reason: "operator re-test failed"}); err != nil {
		t.Fatalf("set-status reopened: %v", err)
	}
	reread, _ := db.GetItem(it.ATMID)
	if reread.Status != StatusReopened {
		t.Errorf("status: got %q, want %q", reread.Status, StatusReopened)
	}
	if reread.CurrentLocation != LocationIssues {
		t.Errorf("location after reopen: got %q, want %q", reread.CurrentLocation, LocationIssues)
	}
}
