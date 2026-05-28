-- DRIFT-CHECK: this file is a synced copy from constitution 6828ff2;
-- rerun 'workable-items validate --schema-only' if constitution updates.
-- Source of truth: constitution/scripts/workable-items/schema.sql
-- This local copy is embedded via go:embed into the workable-items binary.
--
-- PROJECT-LOCAL EXTENSION (PWU-Q3, 2026-05-28): added raw_body column for
-- §11.4.93 phase-6 byte-identical round-trip on free-form-body items.
-- Constitution upstream PR tracked as next-cycle item. The DB layer applies
-- ALTER TABLE items ADD COLUMN raw_body TEXT NOT NULL DEFAULT '' at open()
-- time when an existing DB lacks the column, so older docs/workable_items.db
-- files migrate transparently.
--
-- workable-items DDL — §11.4.93 SQLite-SSoT for workable items
--
-- Canonical authority: constitution/Constitution.md §11.4.93
-- Forensic anchor: User mandate 2026-05-27.
--
-- This schema is the AUTHORITATIVE source for every workable item.
-- All Markdown / HTML / PDF / Summary / Status surfaces are generator
-- output derived from this DB. Sync drift is mechanically impossible
-- because every regeneration starts from these tables.
--
-- Bidirectional regeneration guarantee (§11.4.93):
--   md→db: `workable-items sync md-to-db` parses Issues.md + Fixed.md +
--          Status.md fleet, upserts here.
--   db→md: `workable-items sync db-to-md` regenerates the same docs from
--          this DB. Round-trip MUST be byte-identical modulo whitespace.

PRAGMA foreign_keys = ON;

-- ============================================================
-- §11.4.93 — items: primary registry
-- ============================================================
CREATE TABLE IF NOT EXISTS items (
    -- §11.4.54 ATM-NNN ticket identifier (primary key, monotonic,
    -- append-only, never renumbered, never reused).
    atm_id           TEXT PRIMARY KEY NOT NULL,

    -- §11.4.16 Type closed-set
    type             TEXT NOT NULL CHECK (type IN ('Bug', 'Feature', 'Task')),

    -- §11.4.15 + §11.4.21 + §11.4.90 Status closed-set
    status           TEXT NOT NULL CHECK (status IN (
                         'Queued', 'In progress', 'Ready for testing',
                         'In testing', 'Reopened', 'Operator-blocked',
                         'Fixed (→ Fixed.md)', 'Implemented (→ Fixed.md)',
                         'Completed (→ Fixed.md)', 'Obsolete (→ Fixed.md)'
                     )),

    -- Severity (informational only; not closed-set, but recommended)
    severity         TEXT,

    -- Heading line text (full H2 heading including code prefix per §11.4.54)
    title            TEXT NOT NULL,

    -- §11.4.91 description floor: ≥ 6 words OR ≥ 40 chars (enforced at insert)
    description      TEXT NOT NULL,

    -- Forensic anchor — verbatim user mandate or operator quote
    forensic_anchor  TEXT,

    -- Closure criteria (markdown body)
    closure_criteria TEXT,

    -- Composes-with cross-references — JSON array of §-letter or ATM-NNN refs
    composes_with    TEXT,                    -- JSON-encoded array

    -- Current document location for atomic-move discipline per §11.4.19
    current_location TEXT NOT NULL CHECK (current_location IN ('Issues', 'Fixed')) DEFAULT 'Issues',

    -- Project-specific: category letter (A..E for tmux project) extracted from
    -- heading code-prefix (e.g. B3 → category='B'). Used for grouping in Issues.md.
    category         TEXT,

    -- Project-specific: category-local ordinal (e.g. B3 → code_ordinal=3).
    -- Distinct from the global ATM-NNN; preserved verbatim across round-trip
    -- so generator emits "### B3. ..." for a category=B + code_ordinal=3 row.
    code_ordinal     INTEGER,

    -- Heading hash (sha256 of normalised title) — binding key for re-sync
    -- when wording reflows but identity persists.
    heading_hash     TEXT NOT NULL UNIQUE,

    -- PROJECT-LOCAL EXTENSION (PWU-Q3, 2026-05-28): verbatim free-form body
    -- captured at md→db time, replayed verbatim at db→md time. Stores the
    -- exact text between the H3 heading and the next H3 heading. When
    -- non-empty, db→md emits "<heading>\n<raw_body>" — the structured
    -- Type/Status/Severity/ATM-ID prefix lines are NOT re-prepended because
    -- they are already inside raw_body (parser preserves them verbatim).
    -- Empty for items created via `workable-items add` (no source body yet);
    -- db→md falls back to the structured prefix-block emission for those.
    raw_body         TEXT NOT NULL DEFAULT '',

    -- Timestamps
    created_at       TEXT NOT NULL DEFAULT (datetime('now')),
    last_modified    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_items_status ON items(status);
CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);
CREATE INDEX IF NOT EXISTS idx_items_location ON items(current_location);
CREATE INDEX IF NOT EXISTS idx_items_heading_hash ON items(heading_hash);

-- ============================================================
-- §11.4.93 — item_history: append-only audit log
-- Covers §11.4.34 Reopened attribution + §11.4.90 Obsolete attribution +
-- §11.4.42 iteration discipline state transitions.
-- ============================================================
CREATE TABLE IF NOT EXISTS item_history (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    atm_id           TEXT NOT NULL REFERENCES items(atm_id),

    -- Event type — closed-set
    event_type       TEXT NOT NULL CHECK (event_type IN (
                         'Opened', 'Updated', 'Reopened',
                         'Fixed', 'Implemented', 'Completed', 'Obsolete'
                     )),

    -- §11.4.34 source attribution
    by               TEXT CHECK (by IN ('AI', 'User', NULL)),

    -- ISO date
    on_date          TEXT NOT NULL,

    -- §11.4.34 / §11.4.90 closed-set Reason vocabulary
    reason           TEXT,

    -- Captured-evidence per §11.4.5 — path to artefact under qa-results/ etc.
    evidence_path    TEXT,

    created_at       TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_item_history_atm_id ON item_history(atm_id);
CREATE INDEX IF NOT EXISTS idx_item_history_event_type ON item_history(event_type);

-- ============================================================
-- §11.4.90 — obsolete_details: triple-check evidence for Obsolete items
-- ============================================================
CREATE TABLE IF NOT EXISTS obsolete_details (
    atm_id                  TEXT PRIMARY KEY REFERENCES items(atm_id),

    -- ISO date of obsolescence determination
    since                   TEXT NOT NULL,

    -- §11.4.90 closed-set Reason vocabulary
    reason                  TEXT NOT NULL CHECK (reason IN (
                                'superseded-by-design-change',
                                'superseded-by-later-mandate',
                                'feature-removed',
                                'duplicate-of',
                                'unsupported-topology'
                            )),

    -- §-letter / ATM-NNN reference of the work that obsoleted this item
    superseding_item        TEXT NOT NULL,

    -- §11.4.90 triple-check: positive captured evidence (NOT bare assertion)
    triple_check_evidence   TEXT NOT NULL
);

-- ============================================================
-- §11.4.21 — operator_block_details: when Status=Operator-blocked
-- ============================================================
CREATE TABLE IF NOT EXISTS operator_block_details (
    atm_id                       TEXT PRIMARY KEY REFERENCES items(atm_id),
    what                         TEXT NOT NULL,
    why_exhausted_alternatives   TEXT NOT NULL,
    unblock_condition            TEXT NOT NULL,
    who                          TEXT
);

-- ============================================================
-- §11.4.47 — firebase_metadata: per-item Firebase-sourced telemetry
-- ============================================================
CREATE TABLE IF NOT EXISTS firebase_metadata (
    atm_id                 TEXT PRIMARY KEY REFERENCES items(atm_id),
    firebase_issue_ids     TEXT,           -- JSON array
    firebase_url           TEXT,
    stacktrace_cluster_hash TEXT,
    kpi                    TEXT,           -- Performance KPI ref
    funnel                 TEXT            -- Analytics funnel ref
);

-- ============================================================
-- PWU-Q3 (§11.4.93 phase-6) — document_sources: verbatim source documents
--
-- Holds the full Markdown text of each tracked document (Issues.md, Fixed.md)
-- captured at md→db time, so db→md can replay it byte-identical even for
-- free-form content the items.raw_body column cannot represent (preamble,
-- section separators, document conventions table, trailer line, etc.).
--
-- The items table remains authoritative for individual workable-item
-- queries / validation / Status_Summary regeneration. The document_sources
-- table is the carbon copy used for byte-identical round-trip.
-- ============================================================
CREATE TABLE IF NOT EXISTS document_sources (
    -- Closed-set: 'Issues' | 'Fixed'.
    location         TEXT PRIMARY KEY NOT NULL CHECK (location IN ('Issues', 'Fixed')),
    -- Full Markdown text, verbatim from the source file.
    raw_text         TEXT NOT NULL,
    -- sha256 of raw_text — used to detect drift in fast paths.
    sha256           TEXT NOT NULL,
    last_modified    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================
-- meta: schema version + sync state
-- ============================================================
CREATE TABLE IF NOT EXISTS meta (
    key                  TEXT PRIMARY KEY,
    value                TEXT NOT NULL,
    last_modified        TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR IGNORE INTO meta(key, value) VALUES
    ('schema_version', '1'),
    ('last_sync_direction', 'none'),
    ('last_sync_timestamp', ''),
    ('integrity_hash', ''),
    ('next_atm_id', '1'),
    ('constitution_sha', '6828ff2');
