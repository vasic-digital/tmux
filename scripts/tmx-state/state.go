// Package main — state schema + load/save for tmx-state.
//
// §11.4.78 anchor: Go state daemon for per-session cwd persistence,
// per spec docs/superpowers/specs/2026-05-22-tmx-shell-session-resume-design.md §5.3.
//
// File schema (single-file, atomic write+rename):
//
//	{
//	  "schema_version": 1,
//	  "sessions": {
//	    "<name>": { "last_pwd": "...", "last_seen_unix": N,
//	                 "created_unix": N, "host": "..." }
//	  }
//	}
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// SchemaVersion is the on-disk version of the state file.
const SchemaVersion = 1

// Session is the per-session record.
type Session struct {
	LastPwd      string `json:"last_pwd"`
	LastSeenUnix int64  `json:"last_seen_unix"`
	CreatedUnix  int64  `json:"created_unix"`
	Host         string `json:"host,omitempty"`
}

// State is the root document persisted to disk.
type State struct {
	SchemaVersion int                `json:"schema_version"`
	Sessions      map[string]Session `json:"sessions"`
}

// newEmptyState returns a fresh State with schema version set + empty map.
func newEmptyState() *State {
	return &State{
		SchemaVersion: SchemaVersion,
		Sessions:      map[string]Session{},
	}
}

// statePath resolves the on-disk state file path.
// Honors TMX_STATE_FILE env var for tests; falls back to ~/.tmx/state.json.
func statePath() (string, error) {
	if p := os.Getenv("TMX_STATE_FILE"); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".tmx", "state.json"), nil
}

// ensureParentDir creates the parent directory of `path` with mode 0700
// if it does not exist. Idempotent.
func ensureParentDir(path string) error {
	dir := filepath.Dir(path)
	if dir == "" || dir == "." || dir == "/" {
		return nil
	}
	// MkdirAll respects existing perms on existing dirs.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	// Belt-and-suspenders: if we just created it, ensure mode 0700.
	// (umask might have stripped bits.)
	if err := os.Chmod(dir, 0o700); err != nil {
		// Non-fatal: directory exists and might be a shared one we
		// don't own. Tests assert the happy path explicitly.
		return nil
	}
	return nil
}

// loadState reads + parses the state file at `path`. If the file does
// not exist, returns a fresh empty state with no error (first-run is
// not an error). If the file exists but is corrupt, returns an empty
// state and a non-nil "rebuilt" sentinel error so callers (record)
// can log a notice but continue per spec §6 edge #6.
//
// errStateRebuilt is returned alongside a fresh empty State.
var errStateRebuilt = errors.New("state file corrupt, rebuilt")

func loadState(path string) (*State, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return newEmptyState(), nil
		}
		return nil, fmt.Errorf("read state %s: %w", path, err)
	}
	if len(data) == 0 {
		return newEmptyState(), errStateRebuilt
	}
	var s State
	if jerr := json.Unmarshal(data, &s); jerr != nil {
		return newEmptyState(), errStateRebuilt
	}
	// Normalize: ensure non-nil map + correct schema_version.
	if s.Sessions == nil {
		s.Sessions = map[string]Session{}
	}
	if s.SchemaVersion == 0 {
		s.SchemaVersion = SchemaVersion
	}
	return &s, nil
}

// saveState serializes `s` and atomically writes it to `path` with
// mode 0600. Acquires an advisory lock on a sibling lock file so
// concurrent writers serialize (spec §6 edge #8). Use this when you
// are NOT already holding the state lock (e.g. via withStateLock).
func saveState(path string, s *State) error {
	if err := ensureParentDir(path); err != nil {
		return err
	}
	data, err := marshalState(s)
	if err != nil {
		return err
	}
	return atomicWriteLocked(path, data, 0o600)
}

// saveStateUnlocked is the lock-free variant — call ONLY from inside
// withStateLock where the caller already holds the lock. Otherwise
// concurrent writers race.
func saveStateUnlocked(path string, s *State) error {
	if err := ensureParentDir(path); err != nil {
		return err
	}
	data, err := marshalState(s)
	if err != nil {
		return err
	}
	return atomicWrite(path, data, 0o600)
}

func marshalState(s *State) ([]byte, error) {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal state: %w", err)
	}
	// Append trailing newline for friendly `cat` output.
	return append(data, '\n'), nil
}
