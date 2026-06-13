// db.go — §11.4.93 + §11.4.95 SQLite persistence layer.
//
// Opens the workable_items.db, applies the embedded schema idempotently,
// configures WAL mode (per constitution schema), exposes CRUD per table,
// and runs PRAGMA wal_checkpoint(TRUNCATE) on close so the tracked
// docs/workable_items.db carries authoritative state (sidecar .db-wal /
// .db-shm are gitignored transient).

package main

import (
	"crypto/sha256"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var embeddedSchema string

// DB wraps *sql.DB with workable-items-specific helpers.
type DB struct {
	conn *sql.DB
	path string
}

// OpenDB opens (or creates) the SQLite DB at path, applies schema, sets WAL mode.
// Caller MUST call Close() to checkpoint+release.
func OpenDB(path string) (*DB, error) {
	conn, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open sqlite %q: %w", path, err)
	}
	if err := conn.Ping(); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("ping sqlite %q: %w", path, err)
	}
	// Apply embedded schema (idempotent CREATE IF NOT EXISTS).
	if _, err := conn.Exec(embeddedSchema); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	// PWU-Q3 (§11.4.93 phase-6) — auto-migrate older DBs that lack the
	// raw_body column. CREATE TABLE IF NOT EXISTS won't add new columns to
	// an existing table, so we do ALTER TABLE ADD COLUMN if absent. SQLite
	// has no IF NOT EXISTS for ADD COLUMN, so we probe pragma_table_info.
	var hasRawBody int
	if err := conn.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info('items') WHERE name = 'raw_body'`,
	).Scan(&hasRawBody); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("probe raw_body column: %w", err)
	}
	if hasRawBody == 0 {
		if _, err := conn.Exec(
			`ALTER TABLE items ADD COLUMN raw_body TEXT NOT NULL DEFAULT ''`,
		); err != nil {
			_ = conn.Close()
			return nil, fmt.Errorf("migrate raw_body: %w", err)
		}
	}
	return &DB{conn: conn, path: path}, nil
}

// Close runs the §11.4.95 WAL-checkpoint then closes the connection.
func (d *DB) Close() error {
	if d.conn == nil {
		return nil
	}
	// PRAGMA wal_checkpoint(TRUNCATE) folds WAL into the main DB file so the
	// tracked file alone holds authoritative state — sidecar .db-wal can be
	// safely discarded (and IS gitignored per §11.4.95).
	if _, err := d.conn.Exec("PRAGMA wal_checkpoint(TRUNCATE);"); err != nil {
		// Non-fatal — we still close.
		_ = d.conn.Close()
		d.conn = nil
		return fmt.Errorf("wal_checkpoint: %w", err)
	}
	err := d.conn.Close()
	d.conn = nil
	return err
}

// MetaGet returns the meta-table value for key, or "" if missing.
func (d *DB) MetaGet(key string) (string, error) {
	var v string
	err := d.conn.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return v, err
}

// MetaSet upserts a meta-table value.
func (d *DB) MetaSet(key, value string) error {
	_, err := d.conn.Exec(
		"INSERT INTO meta(key, value, last_modified) VALUES(?, ?, datetime('now')) "+
			"ON CONFLICT(key) DO UPDATE SET value=excluded.value, last_modified=excluded.last_modified",
		key, value)
	return err
}

// NextATMID returns the next available ATM-NNN identifier and bumps the
// counter atomically. Format: ATM-NNN with zero-padding ≥3 digits.
func (d *DB) NextATMID() (string, error) {
	tx, err := d.conn.Begin()
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()

	var cur string
	err = tx.QueryRow("SELECT value FROM meta WHERE key = 'next_atm_id'").Scan(&cur)
	if err != nil {
		return "", fmt.Errorf("read next_atm_id: %w", err)
	}
	n, err := strconv.Atoi(cur)
	if err != nil || n < 1 {
		n = 1
	}
	atm := fmt.Sprintf("ATM-%03d", n)
	if _, err := tx.Exec(
		"UPDATE meta SET value = ?, last_modified = datetime('now') WHERE key = 'next_atm_id'",
		strconv.Itoa(n+1)); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return atm, nil
}

// UpsertItem inserts-or-updates an item keyed on heading_hash.
// If an existing row's heading_hash matches, the existing ATMID is preserved
// and the row is updated; otherwise a new row is inserted with the provided
// ATMID (caller must have allocated via NextATMID()).
func (d *DB) UpsertItem(it *Item) error {
	// First try lookup by heading_hash.
	var existingATM string
	err := d.conn.QueryRow(
		"SELECT atm_id FROM items WHERE heading_hash = ?", it.HeadingHash).Scan(&existingATM)
	if err != nil && err != sql.ErrNoRows {
		return fmt.Errorf("lookup by heading_hash: %w", err)
	}
	if err == nil {
		// Update existing row. Preserve atm_id, created_at.
		it.ATMID = existingATM
		_, err = d.conn.Exec(`
			UPDATE items SET
				type = ?, status = ?, severity = ?, title = ?, description = ?,
				forensic_anchor = ?, closure_criteria = ?, composes_with = ?,
				current_location = ?, category = ?, code_ordinal = ?,
				raw_body = ?, last_modified = datetime('now')
			WHERE atm_id = ?`,
			it.Type, it.Status, it.Severity, it.Title, it.Description,
			it.ForensicAnchor, it.ClosureCriteria, it.ComposesWith,
			it.CurrentLocation, it.Category, it.CodeOrdinal,
			it.RawBody, existingATM)
		return err
	}
	// Insert new row.
	_, err = d.conn.Exec(`
		INSERT INTO items(
			atm_id, type, status, severity, title, description,
			forensic_anchor, closure_criteria, composes_with,
			current_location, category, code_ordinal, heading_hash, raw_body
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		it.ATMID, it.Type, it.Status, it.Severity, it.Title, it.Description,
		it.ForensicAnchor, it.ClosureCriteria, it.ComposesWith,
		it.CurrentLocation, it.Category, it.CodeOrdinal, it.HeadingHash, it.RawBody)
	return err
}

// InsertItemHistory appends an item_history row.
func (d *DB) InsertItemHistory(ev *ItemHistoryEvent) error {
	_, err := d.conn.Exec(`
		INSERT INTO item_history(atm_id, event_type, by, on_date, reason, evidence_path)
		VALUES(?, ?, ?, ?, ?, ?)`,
		ev.ATMID, ev.EventType,
		nullIfEmpty(ev.By), ev.OnDate,
		nullIfEmpty(ev.Reason), nullIfEmpty(ev.EvidencePath))
	return err
}

// AllItems returns every row of items, sorted by ATM-NNN numeric ascending.
func (d *DB) AllItems() ([]*Item, error) {
	rows, err := d.conn.Query(`
		SELECT atm_id, type, status, severity, title, description,
		       COALESCE(forensic_anchor, ''), COALESCE(closure_criteria, ''),
		       COALESCE(composes_with, ''), current_location,
		       COALESCE(category, ''), COALESCE(code_ordinal, 0), heading_hash,
		       COALESCE(raw_body, ''),
		       created_at, last_modified
		FROM items
		ORDER BY CAST(SUBSTR(atm_id, 5) AS INTEGER) ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Item
	for rows.Next() {
		it := &Item{}
		if err := rows.Scan(
			&it.ATMID, &it.Type, &it.Status, &it.Severity,
			&it.Title, &it.Description,
			&it.ForensicAnchor, &it.ClosureCriteria,
			&it.ComposesWith, &it.CurrentLocation,
			&it.Category, &it.CodeOrdinal, &it.HeadingHash,
			&it.RawBody,
			&it.CreatedAt, &it.LastModified); err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// ItemsByLocation returns items whose current_location matches.
func (d *DB) ItemsByLocation(loc string) ([]*Item, error) {
	all, err := d.AllItems()
	if err != nil {
		return nil, err
	}
	var out []*Item
	for _, it := range all {
		if it.CurrentLocation == loc {
			out = append(out, it)
		}
	}
	return out, nil
}

// GetItem returns the item by ATM-NNN, or nil if missing.
func (d *DB) GetItem(atmID string) (*Item, error) {
	it := &Item{}
	err := d.conn.QueryRow(`
		SELECT atm_id, type, status, severity, title, description,
		       COALESCE(forensic_anchor, ''), COALESCE(closure_criteria, ''),
		       COALESCE(composes_with, ''), current_location,
		       COALESCE(category, ''), COALESCE(code_ordinal, 0), heading_hash,
		       COALESCE(raw_body, ''),
		       created_at, last_modified
		FROM items WHERE atm_id = ?`, atmID).Scan(
		&it.ATMID, &it.Type, &it.Status, &it.Severity,
		&it.Title, &it.Description,
		&it.ForensicAnchor, &it.ClosureCriteria,
		&it.ComposesWith, &it.CurrentLocation,
		&it.Category, &it.CodeOrdinal, &it.HeadingHash,
		&it.RawBody,
		&it.CreatedAt, &it.LastModified)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return it, err
}

// HistoryFor returns all item_history rows for an ATM-NNN, oldest first.
func (d *DB) HistoryFor(atmID string) ([]*ItemHistoryEvent, error) {
	rows, err := d.conn.Query(`
		SELECT id, atm_id, event_type, COALESCE(by, ''), on_date,
		       COALESCE(reason, ''), COALESCE(evidence_path, ''), created_at
		FROM item_history WHERE atm_id = ? ORDER BY id ASC`, atmID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*ItemHistoryEvent
	for rows.Next() {
		ev := &ItemHistoryEvent{}
		if err := rows.Scan(&ev.ID, &ev.ATMID, &ev.EventType,
			&ev.By, &ev.OnDate, &ev.Reason, &ev.EvidencePath, &ev.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

// CountRows returns the row count of `items` (used for reporting + tests).
func (d *DB) CountRows() (int, error) {
	var n int
	err := d.conn.QueryRow("SELECT COUNT(*) FROM items").Scan(&n)
	return n, err
}

// ObsoleteDetailsFor returns obsolete_details for an ATM-NNN, nil if absent.
func (d *DB) ObsoleteDetailsFor(atmID string) (*ObsoleteDetails, error) {
	od := &ObsoleteDetails{}
	err := d.conn.QueryRow(`
		SELECT atm_id, since, reason, superseding_item, triple_check_evidence
		FROM obsolete_details WHERE atm_id = ?`, atmID).Scan(
		&od.ATMID, &od.Since, &od.Reason, &od.SupersedingItem, &od.TripleCheckEvidence)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return od, err
}

// OperatorBlockDetailsFor returns operator_block_details for an ATM-NNN, nil if absent.
func (d *DB) OperatorBlockDetailsFor(atmID string) (*OperatorBlockDetails, error) {
	ob := &OperatorBlockDetails{}
	err := d.conn.QueryRow(`
		SELECT atm_id, what, why_exhausted_alternatives, unblock_condition, COALESCE(who, '')
		FROM operator_block_details WHERE atm_id = ?`, atmID).Scan(
		&ob.ATMID, &ob.What, &ob.WhyExhaustedAlternatives, &ob.UnblockCondition, &ob.Who)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return ob, err
}

// PutOperatorBlockDetails upserts the §11.4.21 operator_block_details row for
// an ATM-NNN. Called from md→db sync when an item's status is Operator-blocked
// and its body carries an **Operator-Block-Details:** block. The schema's
// what / why_exhausted_alternatives / unblock_condition columns are NOT NULL,
// so empty extracted values are stored as empty strings rather than NULL.
func (d *DB) PutOperatorBlockDetails(ob *OperatorBlockDetails) error {
	_, err := d.conn.Exec(`
		INSERT OR REPLACE INTO operator_block_details(
			atm_id, what, why_exhausted_alternatives, unblock_condition, who
		) VALUES(?, ?, ?, ?, ?)`,
		ob.ATMID, ob.What, ob.WhyExhaustedAlternatives, ob.UnblockCondition,
		nullIfEmpty(ob.Who))
	return err
}

// SetComposesWith JSON-encodes the slice and stores it.
func (d *DB) SetComposesWith(atmID string, refs []string) error {
	if refs == nil {
		refs = []string{}
	}
	b, err := json.Marshal(refs)
	if err != nil {
		return err
	}
	_, err = d.conn.Exec("UPDATE items SET composes_with = ? WHERE atm_id = ?", string(b), atmID)
	return err
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// PutDocumentSource upserts a verbatim source document for the given location.
// Used by md→db so db→md can replay byte-identical even when the items.raw_body
// per-item capture cannot represent preamble / section separators / trailers.
func (d *DB) PutDocumentSource(location, rawText string) error {
	if location != LocationIssues && location != LocationFixed {
		return fmt.Errorf("PutDocumentSource: invalid location %q", location)
	}
	sum := sha256.Sum256([]byte(rawText))
	hash := hex.EncodeToString(sum[:])
	_, err := d.conn.Exec(`
		INSERT INTO document_sources(location, raw_text, sha256, last_modified)
		VALUES(?, ?, ?, datetime('now'))
		ON CONFLICT(location) DO UPDATE SET
			raw_text = excluded.raw_text,
			sha256 = excluded.sha256,
			last_modified = excluded.last_modified`,
		location, rawText, hash)
	return err
}

// GetDocumentSource returns the stored verbatim source for the given location.
// Returns ("", nil) when no source has been captured yet.
func (d *DB) GetDocumentSource(location string) (string, error) {
	var rawText string
	err := d.conn.QueryRow(
		`SELECT raw_text FROM document_sources WHERE location = ?`, location,
	).Scan(&rawText)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return rawText, err
}
