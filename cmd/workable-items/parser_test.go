// parser_test.go — §11.4.15/§11.4.21 status-extraction tests for the
// Markdown → Item parser.
//
// Forensic anchor: Issues.md F1 (TMX-050) carries `**Status:** Operator-blocked`
// in the MD, but the parser's structured `status` extraction captured `Queued`
// instead — the statusLineRE non-greedy capture truncated the hyphenated value
// `Operator-blocked` at its first hyphen, yielding the unrecognised token
// `Operator`, which mapHeadingHintToStatus defaulted to `Queued`.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

// parseStatusFromBody is a small helper that writes a one-item Issues.md
// fragment whose **Status:** line carries the given value, parses it, and
// returns the resulting structured Status of the single parsed item.
func parseStatusFromBody(t *testing.T, statusLine string) string {
	t.Helper()
	tmp := t.TempDir()
	path := filepath.Join(tmp, "Issues.md")
	doc := "# Issues\n\n## F\n\n### F1. `tmx` session named \"HelixCode\" crashes the whole terminal\n\n" +
		"**Status:** " + statusLine + "\n" +
		"**Type:** Bug\n\nSome body text describing the defect in enough words.\n"
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	items, err := ParseFile(path, LocationIssues)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected exactly 1 parsed item, got %d", len(items))
	}
	return items[0].Item.Status
}

// TestParse_OperatorBlockedStatus is the RED test: the F1 forensic case.
func TestParse_OperatorBlockedStatus(t *testing.T) {
	got := parseStatusFromBody(t, "Operator-blocked")
	if got != StatusOperatorBlock {
		t.Errorf("structured status for `Operator-blocked`: got %q, want %q", got, StatusOperatorBlock)
	}
}

// TestParse_AllStatusValues exercises every §11.4.15/§11.4.21/§11.4.90 status
// value to guard against further truncation/mapping regressions.
func TestParse_AllStatusValues(t *testing.T) {
	cases := []struct {
		line string
		want string
	}{
		{"Queued", StatusQueued},
		{"In progress", StatusInProgress},
		{"Ready for testing", StatusReadyForTest},
		{"In testing", StatusInTesting},
		{"Reopened", StatusReopened},
		{"Operator-blocked", StatusOperatorBlock},
		{"`Operator-blocked`", StatusOperatorBlock},
		{"Fixed (→ Fixed.md)", StatusFixed},
		{"Implemented (→ Fixed.md)", StatusImplemented},
		{"Completed (→ Fixed.md)", StatusCompleted},
		{"Obsolete (→ Fixed.md)", StatusObsolete},
	}
	for _, c := range cases {
		got := parseStatusFromBody(t, c.line)
		if got != c.want {
			t.Errorf("status line %q: got structured status %q, want %q", c.line, got, c.want)
		}
	}
}
