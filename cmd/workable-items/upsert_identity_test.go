// upsert_identity_test.go — §11.4.115 RED-first guard for the heading-form gap.
//
// THE DEFECT (reproduced on the live corpus 2026-09-01, before the fix):
//
//	sync md-to-db: update TMX-072: constraint failed:
//	UNIQUE constraint failed: items.atm_id (1555)
//
// MECHANISM. `UpsertItem` decides INSERT-vs-UPDATE *solely* by heading_hash.
// When a block's heading legitimately changes — a wording reflow, or (the case
// that produced this) a block that only becomes parseable once headingRE
// accepts the space form — its recomputed heading_hash no longer matches the
// stored one. `sync_md_to_db.go` correctly resolves the row by the block's own
// `**TMX-ID:**` (its ExplicitATM fallback) and calls UpsertItem to UPDATE it,
// but UpsertItem re-derives its own verdict from the *changed* hash, misses,
// and attempts an INSERT of an atm_id that already exists.
//
// THE INVARIANT. An item's identity is its atm_id. heading_hash is a FINDING
// AID that must be free to change when the heading changes; it is not the
// identity. So: hash miss + atm_id that already exists => UPDATE that row and
// refresh its hash. Never INSERT.
//
// This is the primitive defect (§11.4.250) beneath two compensating layers —
// the narrow headingRE and the TMX-065/B52 greedy-bind guard.

package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// upsertFixture builds an item whose heading identity is fully specified, so a
// test can change the heading (and thus the hash) while holding atm_id fixed.
func upsertFixture(id, cat string, ord int, title string) *Item {
	return &Item{
		ATMID: id, Type: TypeBug, Status: StatusQueued,
		Title:           title,
		Description:     "A fixture item long enough to satisfy the description-length invariant.",
		CurrentLocation: LocationIssues, Category: cat, CodeOrdinal: ord,
		HeadingHash: computeHeadingHash(cat, cat+itoa(ord), title),
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

// RED — reproduces the live UNIQUE-constraint failure.
//
// Sequence: seed a row (the Z0-sentinel analogue), then re-upsert the SAME
// atm_id carrying the repaired heading identity the widened parser produces.
// Pre-fix this raised `UNIQUE constraint failed: items.atm_id`.
func TestUpsertItem_ChangedHeadingHashUpdatesByATMID(t *testing.T) {
	db, err := OpenDB(filepath.Join(t.TempDir(), "upsert.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	// The sentinel row as the live DB actually held it: identity unknown
	// (category Z, ordinal 0) because its heading never parsed.
	seed := upsertFixture("TMX-072", "Z", 0, "Wizard-created sessions get a random 4-digit name suffix")
	if err := db.UpsertItem(seed); err != nil {
		t.Fatalf("seeding the sentinel row failed: %v", err)
	}

	// The widened parser now reads the block's real heading `### G1 ...`,
	// so the recomputed hash differs while the atm_id is unchanged.
	repaired := upsertFixture("TMX-072", "G", 1, "WIZARD-SUFFIX-001 — wizard-created sessions get a random 4-digit name suffix")
	if repaired.HeadingHash == seed.HeadingHash {
		t.Fatal("fixture is blind: the repaired heading must yield a DIFFERENT hash")
	}

	if err := db.UpsertItem(repaired); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			t.Fatalf("RED reproduced — upsert tried to INSERT an existing atm_id: %v", err)
		}
		t.Fatalf("upsert failed: %v", err)
	}

	// GREEN: exactly one row, identity repaired, hash refreshed.
	items, err := db.AllItems()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 row after re-upsert, got %d (a duplicate identity was created)", len(items))
	}
	got := items[0]
	if got.ATMID != "TMX-072" || got.Category != "G" || got.CodeOrdinal != 1 {
		t.Fatalf("identity not repaired: got %s %s%d", got.ATMID, got.Category, got.CodeOrdinal)
	}
	// The hash must be REFRESHED, or the next sync repeats the same miss.
	if got.HeadingHash != repaired.HeadingHash {
		t.Fatalf("heading_hash not refreshed: stored %q want %q", got.HeadingHash, repaired.HeadingHash)
	}
}

// FALSE-POSITIVE CONTROL (§11.4.201(1)): a genuinely NEW item — an atm_id the
// DB has never seen — must still INSERT. A fix that turned every hash-miss into
// an update-by-id would silently stop creating rows; this control refuses that.
func TestUpsertItem_UnknownATMIDStillInserts(t *testing.T) {
	db, err := OpenDB(filepath.Join(t.TempDir(), "upsert2.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.UpsertItem(upsertFixture("TMX-900", "A", 1, "first item")); err != nil {
		t.Fatal(err)
	}
	if err := db.UpsertItem(upsertFixture("TMX-901", "A", 2, "a genuinely different second item")); err != nil {
		t.Fatalf("a new atm_id must still INSERT: %v", err)
	}
	items, err := db.AllItems()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 distinct rows, got %d — new-item insertion regressed", len(items))
	}
}

// FALSE-POSITIVE CONTROL: the heading_hash path must keep working. An item
// whose hash MATCHES an existing row still binds to that row's atm_id even when
// the caller supplies a different id — the reflow-survival property that made
// heading_hash the primary key of the lookup in the first place.
func TestUpsertItem_HashHitStillBindsToExistingRow(t *testing.T) {
	db, err := OpenDB(filepath.Join(t.TempDir(), "upsert3.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.UpsertItem(upsertFixture("TMX-800", "A", 7, "stable title")); err != nil {
		t.Fatal(err)
	}
	// Same heading (same hash), different caller-supplied id.
	incoming := upsertFixture("TMX-801", "A", 7, "stable title")
	if err := db.UpsertItem(incoming); err != nil {
		t.Fatal(err)
	}
	items, err := db.AllItems()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("hash hit must reuse the existing row, got %d rows", len(items))
	}
	if items[0].ATMID != "TMX-800" {
		t.Fatalf("hash hit must preserve the original atm_id, got %s", items[0].ATMID)
	}
}
