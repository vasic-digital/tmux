// add.go — allocate a new TMX-NNN, insert a new item, write 'Opened' history.

package main

import (
	"fmt"
	"strings"
	"time"
)

// AddItemParams holds the CLI-provided parameters for `workable-items add`.
type AddItemParams struct {
	Type        string
	Severity    string
	Title       string
	Description string
	Category    string
}

// AddItem creates a new item + 'Opened' history event.
func AddItem(db *DB, p AddItemParams) (*Item, error) {
	if !isClosedSetType(p.Type) {
		return nil, fmt.Errorf("invalid --type %q (want Bug|Feature|Task)", p.Type)
	}
	if strings.TrimSpace(p.Title) == "" {
		return nil, fmt.Errorf("--title is required")
	}
	if strings.TrimSpace(p.Description) == "" {
		return nil, fmt.Errorf("--description is required")
	}
	if !descriptionMeetsFloor(p.Description) {
		return nil, fmt.Errorf("--description fails §11.4.91 clarity floor (need ≥40 chars OR ≥6 words)")
	}
	if p.Category == "" {
		p.Category = "Z"
	}

	atm, err := db.NextATMID()
	if err != nil {
		return nil, err
	}

	title := strings.TrimSpace(p.Title)
	category := strings.ToUpper(p.Category)

	// The block code the writer emits must be readable by headingRE
	// (parser.go), which accepts exactly ONE letter followed by digits. A
	// category that is not a single ASCII letter renders a heading the parser
	// can never match — measured: "AB" -> `### AB1.`, "1" -> `### 11.` — so the
	// row lands in the SSoT while its block stays invisible to every derived
	// document. Refuse it here rather than create an unreachable item.
	if len(category) != 1 || category[0] < 'A' || category[0] > 'Z' {
		return nil, fmt.Errorf(
			"invalid --category %q (want exactly one letter A-Z: the block code "+
				"must render a heading the parser can read)", p.Category)
	}

	// TMX-093 (§A5 ADD-HASH-CONVENTION-SPLIT-001). computeHeadingHash's second
	// argument is the markdown BLOCK CODE, not the ticket id: parser.go builds
	// it as `code := category + ordinal` (parser.go:186) before hashing at
	// parser.go:201. Passing `atm` here produced a hash the parser could never
	// reproduce, so an add-created row could not bind to its own block by hash
	// and survived only via the ExplicitATM rebind fallback in sync_md_to_db.go
	// — which REPLACES the row and refreshes the hash, masking the split.
	//
	// `add` genuinely has no category-local ordinal: CodeOrdinal is left at the
	// 0 sentinel that validate_identity.go:101 reads as "asserts no block
	// claim", because no block exists yet. The code is still deterministic,
	// because the writer resolves that same sentinel the same way — see
	// sync_db_to_md.go:195-201, which renders the heading as
	// `### <Category><CodeOrdinal>.` and substitutes atmOrdinal(ATMID) when
	// CodeOrdinal is 0. Mirroring that expression here (rather than inventing
	// an ordinal) keeps the hash tracking whatever heading the writer actually
	// emits, for every ATMID form the writer accepts.
	blockCode := fmt.Sprintf("%s%d", category, atmOrdinal(atm))

	it := &Item{
		ATMID:           atm,
		Type:            p.Type,
		Status:          StatusQueued,
		Severity:        p.Severity,
		Title:           title,
		Description:     strings.TrimSpace(p.Description),
		CurrentLocation: LocationIssues,
		Category:        category,
		HeadingHash:     computeHeadingHash(category, blockCode, title),
	}
	if err := db.UpsertItem(it); err != nil {
		return nil, fmt.Errorf("insert: %w", err)
	}
	ev := &ItemHistoryEvent{
		ATMID:     atm,
		EventType: "Opened",
		By:        "User",
		OnDate:    time.Now().UTC().Format("2006-01-02"),
		Reason:    "workable-items add",
	}
	if err := db.InsertItemHistory(ev); err != nil {
		return nil, fmt.Errorf("insert history: %w", err)
	}
	return it, nil
}
