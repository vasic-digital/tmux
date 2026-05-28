// model.go — §11.4.93 workable-items in-memory representation
//
// Type definitions for Item + ItemHistory + auxiliary tables. The DB layer
// (db.go) converts to/from these structs; the sync layer (sync_md_to_db.go,
// sync_db_to_md.go) operates on slices of Item.

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// Type closed-set per §11.4.16.
const (
	TypeBug     = "Bug"
	TypeFeature = "Feature"
	TypeTask    = "Task"
)

// Status closed-set per §11.4.15 + §11.4.21 + §11.4.90.
const (
	StatusQueued         = "Queued"
	StatusInProgress     = "In progress"
	StatusReadyForTest   = "Ready for testing"
	StatusInTesting      = "In testing"
	StatusReopened       = "Reopened"
	StatusOperatorBlock  = "Operator-blocked"
	StatusFixed          = "Fixed (→ Fixed.md)"
	StatusImplemented    = "Implemented (→ Fixed.md)"
	StatusCompleted      = "Completed (→ Fixed.md)"
	StatusObsolete       = "Obsolete (→ Fixed.md)"
)

// closedSetStatuses lists every valid Status value.
var closedSetStatuses = []string{
	StatusQueued, StatusInProgress, StatusReadyForTest, StatusInTesting,
	StatusReopened, StatusOperatorBlock,
	StatusFixed, StatusImplemented, StatusCompleted, StatusObsolete,
}

// Terminal statuses (closed items).
var terminalStatuses = map[string]bool{
	StatusFixed:       true,
	StatusImplemented: true,
	StatusCompleted:   true,
	StatusObsolete:    true,
}

// Location values.
const (
	LocationIssues = "Issues"
	LocationFixed  = "Fixed"
)

// Item represents a single workable-items row.
type Item struct {
	ATMID           string
	Type            string
	Status          string
	Severity        string
	Title           string
	Description     string
	ForensicAnchor  string
	ClosureCriteria string
	ComposesWith    string // JSON array
	CurrentLocation string
	Category        string // A..E etc.
	CodeOrdinal     int    // category-local ordinal — see schema.sql comment
	HeadingHash     string
	CreatedAt       string
	LastModified    string

	// Body is the full Markdown body BELOW the heading and metadata
	// lines, preserved in memory during parsing for description-derivation.
	// Not persisted to DB. Use RawBody for round-trip persistence.
	Body string

	// RawBody (PWU-Q3, §11.4.93 phase-6) is the verbatim text BETWEEN the
	// H3 heading and the next H3 heading, preserved EXACTLY so db→md can
	// re-emit it byte-identical. Includes any leading blank lines, embedded
	// blockquotes, code fences, and structured prefix lines (Type/Status/
	// Severity/ATM-ID) — those are still parsed into the Item structured
	// fields for DB indexing/querying, but the raw_body is the source of
	// truth for regeneration. Empty for items created via `workable-items
	// add` (no source body yet); the generator falls back to structured
	// emission in that case.
	RawBody string
}

// ItemHistoryEvent represents one row of item_history.
type ItemHistoryEvent struct {
	ID           int64
	ATMID        string
	EventType    string // Opened|Updated|Reopened|Fixed|Implemented|Completed|Obsolete
	By           string // AI|User|""
	OnDate       string
	Reason       string
	EvidencePath string
	CreatedAt    string
}

// ObsoleteDetails captures §11.4.90 closure metadata.
type ObsoleteDetails struct {
	ATMID                string
	Since                string
	Reason               string
	SupersedingItem      string
	TripleCheckEvidence  string
}

// OperatorBlockDetails captures §11.4.21 closure metadata.
type OperatorBlockDetails struct {
	ATMID                     string
	What                      string
	WhyExhaustedAlternatives  string
	UnblockCondition          string
	Who                       string
}

// IsTerminal reports whether the item's status is a terminal closure value.
func (i *Item) IsTerminal() bool {
	return terminalStatuses[i.Status]
}

// computeHeadingHash returns a stable identity hash for a parsed item.
// We hash on the category+code+title-words, not the full literal heading,
// so wording reflows (punctuation, status-suffix, version bumps) still bind.
//
// Input examples:
//
//	"A36. `scripts/test_e2e.sh` T1.2 stale podman-machine prerequisite"
//	"B3. P5-M20 + P5-M21 paired-mutation ESCAPES — pre-existing v1.0.9 layer-4 gaps"
//
// Normalisation: lowercase, remove backticks, collapse whitespace, strip
// trailing status-tag markers.
func computeHeadingHash(category, code, title string) string {
	norm := strings.ToLower(strings.TrimSpace(title))
	norm = strings.ReplaceAll(norm, "`", "")
	// Collapse internal whitespace.
	fields := strings.Fields(norm)
	norm = strings.Join(fields, " ")

	key := strings.ToLower(category) + "|" + strings.ToLower(code) + "|" + norm
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// isClosedSetStatus reports whether s is a recognised Status closed-set value.
func isClosedSetStatus(s string) bool {
	for _, v := range closedSetStatuses {
		if v == s {
			return true
		}
	}
	return false
}

// isClosedSetType reports whether t is a recognised Type closed-set value.
func isClosedSetType(t string) bool {
	return t == TypeBug || t == TypeFeature || t == TypeTask
}
