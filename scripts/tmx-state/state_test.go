// state_test.go — §11.4 anti-bluff tests for state load/save.
//
// Every assertion reads back from a FRESH decoder (or fresh process for
// main_test.go) — never from the in-memory struct we just set.
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// withTempState returns a fresh temp file path and a t.Cleanup that
// removes the file + lock + dir on test exit.
func withTempState(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	t.Setenv("TMX_STATE_FILE", path)
	return path
}

func TestStatePathHonorsEnv(t *testing.T) {
	t.Setenv("TMX_STATE_FILE", "/tmp/explicit.json")
	got, err := statePath()
	if err != nil {
		t.Fatalf("statePath err: %v", err)
	}
	if got != "/tmp/explicit.json" {
		t.Errorf("statePath = %q, want /tmp/explicit.json", got)
	}
}

func TestStatePathDefaultsToHomeDotTmx(t *testing.T) {
	t.Setenv("TMX_STATE_FILE", "")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	got, err := statePath()
	if err != nil {
		t.Fatalf("statePath err: %v", err)
	}
	want := filepath.Join(home, ".tmx", "state.json")
	if got != want {
		t.Errorf("statePath = %q, want %q", got, want)
	}
}

func TestLoadStateMissingFileReturnsEmpty(t *testing.T) {
	path := withTempState(t)
	st, err := loadState(path)
	if err != nil {
		t.Fatalf("loadState err: %v", err)
	}
	if st == nil {
		t.Fatal("loadState returned nil state")
	}
	if st.SchemaVersion != SchemaVersion {
		t.Errorf("SchemaVersion = %d, want %d", st.SchemaVersion, SchemaVersion)
	}
	if st.Sessions == nil {
		t.Error("Sessions map is nil; want empty non-nil map")
	}
	if len(st.Sessions) != 0 {
		t.Errorf("Sessions has %d entries; want 0", len(st.Sessions))
	}
}

func TestSaveAndReloadRoundTrip(t *testing.T) {
	path := withTempState(t)
	want := newEmptyState()
	want.Sessions["work"] = Session{
		LastPwd:      "/tmp/proj",
		LastSeenUnix: 1700000000,
		CreatedUnix:  1700000000,
		Host:         "test-host",
	}
	if err := saveState(path, want); err != nil {
		t.Fatalf("saveState: %v", err)
	}

	// FRESH read from disk — not the in-memory struct.
	got, err := loadState(path)
	if err != nil {
		t.Fatalf("loadState: %v", err)
	}
	gs, ok := got.Sessions["work"]
	if !ok {
		t.Fatal("session 'work' missing after reload")
	}
	if gs.LastPwd != "/tmp/proj" {
		t.Errorf("LastPwd = %q, want /tmp/proj", gs.LastPwd)
	}
	if gs.LastSeenUnix != 1700000000 {
		t.Errorf("LastSeenUnix = %d, want 1700000000", gs.LastSeenUnix)
	}
	if gs.Host != "test-host" {
		t.Errorf("Host = %q, want test-host", gs.Host)
	}
}

func TestSaveStateFileMode0600(t *testing.T) {
	path := withTempState(t)
	if err := saveState(path, newEmptyState()); err != nil {
		t.Fatalf("saveState: %v", err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	mode := st.Mode().Perm()
	if mode != 0o600 {
		t.Errorf("state file mode = %o, want 0600", mode)
	}
}

func TestEnsureParentDirCreates0700(t *testing.T) {
	tmp := t.TempDir()
	nested := filepath.Join(tmp, "deep", "child", "state.json")
	if err := ensureParentDir(nested); err != nil {
		t.Fatalf("ensureParentDir: %v", err)
	}
	st, err := os.Stat(filepath.Dir(nested))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o700 {
		t.Errorf("dir mode = %o, want 0700", mode)
	}
}

func TestLoadStateCorruptFileRebuilds(t *testing.T) {
	path := withTempState(t)
	// Write garbage that is NOT valid JSON.
	if err := os.WriteFile(path, []byte("not json {{{"), 0o600); err != nil {
		t.Fatalf("seed garbage: %v", err)
	}
	st, err := loadState(path)
	if err != errStateRebuilt {
		t.Errorf("loadState err = %v, want errStateRebuilt", err)
	}
	if st == nil || st.Sessions == nil {
		t.Fatal("loadState returned nil state on rebuild")
	}
	if len(st.Sessions) != 0 {
		t.Errorf("rebuilt state has %d sessions; want 0", len(st.Sessions))
	}
}

func TestSavedFileIsValidJSON(t *testing.T) {
	path := withTempState(t)
	s := newEmptyState()
	s.Sessions["a"] = Session{LastPwd: "/x", LastSeenUnix: 1, CreatedUnix: 1, Host: "h"}
	s.Sessions["b"] = Session{LastPwd: "/y", LastSeenUnix: 2, CreatedUnix: 2}
	if err := saveState(path, s); err != nil {
		t.Fatalf("saveState: %v", err)
	}
	// Decode with a fresh raw decoder — not loadState — to assert
	// the on-disk bytes are independently valid JSON.
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readfile: %v", err)
	}
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		t.Fatalf("on-disk bytes are not valid JSON: %v\nbytes=%s", err, raw)
	}
	if v, ok := generic["schema_version"]; !ok || int(v.(float64)) != SchemaVersion {
		t.Errorf("schema_version field missing or wrong: %v", generic)
	}
	sessions, ok := generic["sessions"].(map[string]any)
	if !ok {
		t.Fatalf("sessions is not an object: %T", generic["sessions"])
	}
	if _, ok := sessions["a"]; !ok {
		t.Error("session 'a' missing in on-disk JSON")
	}
	if _, ok := sessions["b"]; !ok {
		t.Error("session 'b' missing in on-disk JSON")
	}
}

func TestSessionColorRoundTrip(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "state.json")
	st := newEmptyState()
	st.SchemaVersion = SchemaVersion // current (2)
	st.Sessions["work"] = Session{
		LastPwd: "/tmp", LastSeenUnix: 1, CreatedUnix: 1, Color: "red",
	}
	if err := saveState(tmp, st); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := loadState(tmp)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got.Sessions["work"].Color != "red" {
		t.Errorf("Color round-trip = %q, want red", got.Sessions["work"].Color)
	}
	if got.SchemaVersion != 2 {
		t.Errorf("SchemaVersion = %d, want 2", got.SchemaVersion)
	}
}

// TestSchema1FileLoadsAsEmptyColor proves an old (schema-1) file with no
// color field loads cleanly with Color=="" (forward compat — additive
// omitempty field).
func TestSchema1FileLoadsAsEmptyColor(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "state.json")
	// Hand-write a schema-1 file with no color field.
	old := []byte(`{"schema_version":1,"sessions":{"work":{"last_pwd":"/x","last_seen_unix":1,"created_unix":1}}}` + "\n")
	if err := os.WriteFile(tmp, old, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(tmp)
	if err != nil {
		t.Fatalf("load schema-1: %v", err)
	}
	if got.Sessions["work"].Color != "" {
		t.Errorf("legacy Color = %q, want empty", got.Sessions["work"].Color)
	}
}
