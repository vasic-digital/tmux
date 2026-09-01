// heading_forms_test.go — pins the CLOSED set of heading forms the item parser
// accepts, and the forms it refuses.
//
// WHY THIS EXISTS. headingRE was widened from period-only (`### A3. title`) to
// also accept the space form (`### G5 NAME-001 — title`), because the corpus
// uses both and the narrow form silently dropped every space-form block from the
// SSoT. A widening is only safe if its EDGE is stated: without this test the
// regex quietly also accepted `### A1.x` (no space after the period),
// `### A12.5 decimal` (ordinal 12, title "5 decimal") and `### A1.` (empty
// title, whose heading_hash would be computed over ""). None occur in the live
// corpus today, so nothing would have failed — the classic §11.4.201(6)
// FALSE-NULL: a silent zero that proves nothing about the instrument.
//
// ORACLE (§11.4.245, SPECIFIED): the accepted set is the one documented above
// headingRE in parser.go. The oracle is that written contract, not the regex —
// so a future edit that changes behaviour without changing the contract fails
// here rather than passing by agreeing with itself.
//
// blockCodeRE (reconcile.go) is asserted to share the same accepted set: the two
// disagreeing is exactly the defect that hid the space-form blocks.

package main

import "testing"

func TestHeadingRE_AcceptedAndRefused(t *testing.T) {
	accepted := []struct{ line, cat, ord, title string }{
		{"### A3. Period form with one space", "A", "3", "Period form with one space"},
		{"### A52.  Period form, extra spaces", "A", "52", "Period form, extra spaces"},
		{"### G5 SANITIZE-NAME-001 — space form", "G", "5", "SANITIZE-NAME-001 — space form"},
		{"### H1 STATE-HOOK-RACE-001 — space form, single digit", "H", "1", "STATE-HOOK-RACE-001 — space form, single digit"},
		{"### A55. Title — with an em dash and `code`", "A", "55", "Title — with an em dash and `code`"},
	}
	for _, c := range accepted {
		m := headingRE.FindStringSubmatch(c.line)
		if m == nil {
			t.Errorf("MUST accept but refused: %q", c.line)
			continue
		}
		if m[1] != c.cat || m[2] != c.ord || m[3] != c.title {
			t.Errorf("%q → cat=%q ord=%q title=%q; want cat=%q ord=%q title=%q",
				c.line, m[1], m[2], m[3], c.cat, c.ord, c.title)
		}
	}

	refused := []struct{ line, why string }{
		{"### A50X no separator at all", "the code must end at a separator, not run into the title"},
		{"### A1.x period not followed by whitespace", "`A1.x` is one token, not an ordinal plus a title"},
		{"### A12.5 decimal-looking token", "a version/decimal token is not an ordinal, and would silently yield ord=12 title=\"5 decimal-looking token\""},
		{"### A1.", "empty title — its heading_hash would be computed over the empty string"},
		{"### A1 ", "empty title after a space separator"},
		{"### TMX-051 — an id, not a block code", "no `<CAT><N>` code"},
		{"### M24-ESCAPE-001 — a mutation marker heading", "no `<CAT><N>` code; this real corpus heading must never become an item"},
		{"## A3. only two hashes", "block headings are `### `"},
		{"#### A3. four hashes", "block headings are `### `"},
	}
	for _, c := range refused {
		if m := headingRE.FindStringSubmatch(c.line); m != nil {
			t.Errorf("MUST refuse but accepted: %q (%s) → cat=%q ord=%q title=%q",
				c.line, c.why, m[1], m[2], m[3])
		}
	}
}

// The two regexes MUST agree on which headings carry a block code. They once did
// not — headingRE required the period while blockCodeRE did not — and that gap
// is precisely what let space-form blocks sit in the corpus unparsed while the
// reconciler happily matched them.
func TestHeadingRE_AndBlockCodeRE_AgreeOnAcceptance(t *testing.T) {
	lines := []string{
		"### A3. Period form",
		"### G5 SANITIZE-NAME-001 — space form",
		"### A1.x period not followed by whitespace",
		"### A12.5 decimal-looking token",
		"### A1.",
		"### A50X no separator",
		"### TMX-051 — an id, not a block code",
		"### M24-ESCAPE-001 — a mutation marker heading",
	}
	for _, line := range lines {
		byItem := headingRE.MatchString(line)
		byCode := blockCodeRE.MatchString(line)
		if byItem != byCode {
			t.Errorf("regex disagreement on %q: headingRE=%v blockCodeRE=%v — "+
				"a heading one accepts and the other rejects is the gap that hid "+
				"the space-form blocks", line, byItem, byCode)
		}
	}
}
