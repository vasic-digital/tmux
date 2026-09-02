// sourceless_sentinel_test.go — §11.4.115 RED-first guard for the ordinal-0
// sentinel collision in sourcelessItems.
//
// THE DEFECT (measured on the live corpus 2026-09-01). `workable-items add`
// writes a row with the sentinel `code_ordinal = 0`. sourcelessItems derived a
// block code from that sentinel (`A` + `0` = "A0") and asked whether a block
// under that code claims the item. `Fixed.md:2585` holds a REAL block
// `### A0. Initial migration from ATMOSphere project …` that declares no
// `**TMX-ID:**`, so codeOwners["A0"][""] is true and blockClaimedBy returned
// true for EVERY add-created row in category A — silently suppressing exactly
// the rows TMX-094 exists to render. Live proof: TMX-099 and TMX-100 were in
// the DB with location Issues and rendered into NEITHER tracker.
//
// The codebase's own rule is stated at validate_identity.go:163 —
// `if it.CodeOrdinal <= 0 { continue // ordinal sentinel — asserts no block
// claim }`. sourcelessItems contradicted it. This guard pins the convention.
//
// Polarity per §11.4.115: RED_MODE=1 asserts the defect is PRESENT (use on a
// pre-fix artifact); default RED_MODE=0 is the standing green guard.
package main

import "testing"

func TestSourcelessItems_SentinelOrdinalIsNotABlockClaim(t *testing.T) {
	// A corpus that contains a genuine <CAT>0 block declaring no id — the
	// exact shape of Fixed.md:2585 that triggered the live suppression.
	fixed := "# Fixed\n\n## A. Sec\n\n### A0. Initial migration — `RESOLVED`\n\nbody text\n"
	issues := "# Issues\n\n## A. Sec\n\n### A7. Something — real\n\n**TMX-ID:** TMX-095\n\nbody\n"

	sentinel := &Item{
		ATMID: "TMX-099", Type: "Bug", Status: "Queued",
		CurrentLocation: LocationIssues, Category: "A", CodeOrdinal: 0,
		Title: "sentinel row created by add", RawBody: "",
	}
	byID := map[string]*Item{sentinel.ATMID: sentinel}

	got := sourcelessItems(byID, issues, fixed)

	found := false
	for _, it := range got {
		if it.ATMID == "TMX-099" {
			found = true
		}
	}

	if redMode() {
		if found {
			t.Fatalf("RED_MODE=1: the defect did NOT reproduce — TMX-099 was returned. " +
				"This RED test is BLIND on this artifact.")
		}
		t.Logf("RED reproduced: sentinel-ordinal row suppressed by the A0 block (count=%d)", len(got))
		return
	}

	if !found {
		t.Fatalf("sentinel-ordinal (code_ordinal=0) row TMX-099 was suppressed because a "+
			"genuine `### A0.` block declares no id — but ordinal 0 asserts NO block claim "+
			"(validate_identity.go:163). sourceless count=%d", len(got))
	}
}

// §11.4.201(1) false-positive guard: a row whose REAL ordinal names a block
// that already declares THAT ROW'S OWN id must still be suppressed — it has a
// block, so rendering another would duplicate it. This pins that the fix above
// narrowed ONLY the sentinel case and left the real-ordinal path intact.
//
// NOTE (author correction): an earlier version of this guard asserted that a
// row naming a block declared by a DIFFERENT id must be suppressed. That was
// wrong — blockClaimedBy deliberately answers only for this item's own id or
// for an unowned block; a block claimed by another id is a genuine two-items-
// one-block collision that validate_identity.go reports, and masking it here
// would hide it. The guard below tests the contract that actually exists.
func TestSourcelessItems_RealOrdinalOwnBlockStillSuppressed(t *testing.T) {
	fixed := "# Fixed\n\n## A. Sec\n\n### A5. Mine — `RESOLVED`\n\n**TMX-ID:** TMX-050\n\nbody\n"
	owned := &Item{
		ATMID: "TMX-050", Type: "Bug", Status: "Queued",
		CurrentLocation: LocationFixed, Category: "A", CodeOrdinal: 5,
		Title: "row whose real ordinal names its own block", RawBody: "",
	}
	byID := map[string]*Item{owned.ATMID: owned}
	for _, it := range sourcelessItems(byID, "", fixed) {
		if it.ATMID == "TMX-050" {
			t.Fatalf("false positive: a row whose real ordinal names its OWN declared " +
				"block must NOT be re-rendered as sourceless")
		}
	}
}
