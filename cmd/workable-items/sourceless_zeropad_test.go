// sourceless_zeropad_test.go — §1.1 guard for the zero-padded-ordinal
// normalization in sourcelessItems (sync_db_to_md.go:218).
//
// WHY THIS FILE EXISTS. sourcelessItems' block scanner derives a block code
// from a `### <CAT><N>` heading and normalises the ordinal with
// `strings.TrimLeft(m[2], "0")` before comparing it to an item's stored claim.
// An independent reviewer measured (2026-09-01) that DELETING that TrimLeft
// left the entire package suite GREEN: no test in the package exercises a
// zero-padded ordinal, so the branch was untested.
//
// WHY IT IS LOAD-BEARING. The scanner must agree with the PARSER's semantics.
// parser.go's headingRE captures the ordinal digits and db.go turns them into
// an int via Atoi, so the parser reads `### A052.` as ordinal 52 and stores
// code_ordinal 52. Without the TrimLeft the scanner would key that same block
// under the LITERAL "A052", fail to match the row's "A52" claim, and — with
// the other two suppression signals silent — hand the row to
// appendRenderedItems, which APPENDS a second block for an item that already
// has one. sourcelessItems' own header states the consequence: a false
// positive here is "strictly worse than the omission it repairs" (§11.4.108
// corruption, not omission).
//
// HONEST REACHABILITY BOUNDARY (§11.4.6). The branch is DEFENSIVE, not
// currently exercised by the live corpus. Measured 2026-09-02:
// `grep -nE '^### [A-Z]0[0-9]' Issues.md Fixed.md` returns NO hits (exit 1),
// and the same grep against a planted `### A052.` line returns a hit (exit 0),
// so the null is a real absence and not a blind instrument (§11.4.201(7)(b)).
// The writer cannot emit padding either — writeItemBlock formats ordinals with
// `%d`. The branch is nonetheless load-bearing because operators demonstrably
// hand-write nonconforming headings: that is the origin of this entire release
// cycle (parser.go:42 records headingRE having disagreed with blockCodeRE on
// exactly such an operator-written form).
//
// FIXTURE SHAPE — why no `**TMX-ID:**` line names the item under test.
// Signal 2 (`ids[m[1]] = true`) is set by ANY matching id line ANYWHERE in a
// blob, unconditionally and before any code comparison. A fixture whose padded
// block declares the item's own id therefore suppresses the row through signal
// 2 regardless of how the code is normalised, and is BLIND to this mutation.
// Measured 2026-09-02: such a variant PASSes with the TrimLeft deleted. These
// fixtures therefore use the signal-3a shape (a block declaring no owner),
// which is also the shape the operator corpus is full of — it predates the
// `**TMX-ID:**` convention — so the code comparison is the only thing deciding
// the verdict and the mutation flips it.
package main

import "testing"

// TestSourcelessItems_ZeroPaddedHeadingOrdinalIsNormalised is the guard.
//
// `### A052.` is the item's own block: the parser reads that heading as
// ordinal 52, which is exactly the code_ordinal the row stores. The scanner
// must normalise the padded "052" to "52" so the codes agree; otherwise the
// row looks blockless and db→md synthesises a DUPLICATE `### A52.` block
// beside the operator's existing `### A052.` one.
func TestSourcelessItems_ZeroPaddedHeadingOrdinalIsNormalised(t *testing.T) {
	// A hand-written, zero-padded heading declaring no ticket id — the shape
	// the pre-TMX-ID operator corpus is written in.
	blob := "# Issues\n\n## A. Sec\n\n" +
		"### A052. a hand-written block with a zero-padded ordinal\n\n" +
		"**Type:** Bug\n\nbody with no id line.\n"
	it := mkItem("TMX-910", "A", 52, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if got[it.ATMID] {
		t.Fatalf("%s was selected for synthesis even though `### A052.` — the "+
			"zero-padded spelling of the `A52` code its stored code_ordinal "+
			"names — already exists in the blob. The parser reads that heading "+
			"as ordinal 52, so the scanner must TrimLeft the padding before "+
			"comparing; without it the codes read A052 vs A52, the row looks "+
			"blockless, and db→md APPENDS a duplicate block beside the "+
			"operator's existing one (selected=%v).", it.ATMID, got)
	}
}

// TestSourcelessItems_ZeroPaddedHeadingOfADifferentOrdinalDoesNotSuppress is
// the §11.4.201(1) false-positive guard for the test above: normalising the
// padding must NOT collapse distinct ordinals into one another. `### A051.`
// normalises to A51, which is NOT this item's A52 claim, so the genuinely
// blockless row MUST still be selected for synthesis. Without this the test
// above would also pass against a mutation that made every padded code match
// everything (suppress-all), which is the omission failure mode rather than
// the duplication one — both are defects.
func TestSourcelessItems_ZeroPaddedHeadingOfADifferentOrdinalDoesNotSuppress(t *testing.T) {
	blob := "# Issues\n\n## A. Sec\n\n" +
		"### A051. a zero-padded block for a DIFFERENT ordinal\n\n" +
		"**Type:** Bug\n\nbody with no id line.\n"
	it := mkItem("TMX-911", "A", 52, "")

	got := sourcelessIDs([]*Item{it}, blob)
	if !got[it.ATMID] {
		t.Fatalf("%s was NOT selected for synthesis, but the only block present "+
			"is `### A051.` (ordinal 51) and this row claims A52. Normalising "+
			"the zero padding must not collapse distinct ordinals — suppressing "+
			"here would leave a genuinely blockless row rendered into neither "+
			"tracker (selected=%v).", it.ATMID, got)
	}
}

