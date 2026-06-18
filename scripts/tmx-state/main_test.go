// main_test.go — §11.4 anti-bluff CLI tests for tmx-state.
//
// Every PASS reads back the on-disk state from a FRESH decoder, never
// from the in-memory struct. Stdout/stderr captured to bytes.Buffer
// so we assert exact byte contents — no "exit 0 = pass" bluff.
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// runCLI is the test-harness wrapper around run().
func runCLI(t *testing.T, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	var out, err bytes.Buffer
	code = run(args, &out, &err)
	return out.String(), err.String(), code
}

func TestVersionPrintsExpectedString(t *testing.T) {
	withTempState(t)
	stdout, _, code := runCLI(t, "version")
	if code != 0 {
		t.Errorf("exit code = %d, want 0", code)
	}
	want := "tmx-state v1.0.9\n"
	if stdout != want {
		t.Errorf("stdout = %q, want %q", stdout, want)
	}
}

func TestRecordThenRecallRoundTripFromDisk(t *testing.T) {
	path := withTempState(t)
	if _, _, code := runCLI(t, "record", "work", "/tmp/proj"); code != 0 {
		t.Fatalf("record exit = %d", code)
	}
	// Assertion 1: on-disk JSON contains the value (fresh decoder).
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readfile: %v", err)
	}
	var st State
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatalf("on-disk JSON parse: %v", err)
	}
	s, ok := st.Sessions["work"]
	if !ok {
		t.Fatal("session 'work' missing from on-disk JSON")
	}
	if s.LastPwd != "/tmp/proj" {
		t.Errorf("on-disk LastPwd = %q, want /tmp/proj", s.LastPwd)
	}
	// Assertion 2: recall prints the same value to stdout (no newline).
	stdout, _, code := runCLI(t, "recall", "work")
	if code != 0 {
		t.Errorf("recall exit = %d", code)
	}
	if stdout != "/tmp/proj" {
		t.Errorf("recall stdout = %q, want /tmp/proj (no trailing newline)", stdout)
	}
}

func TestRecallMissingSessionExits1(t *testing.T) {
	withTempState(t)
	stdout, _, code := runCLI(t, "recall", "nonexistent")
	if code != 1 {
		t.Errorf("exit code = %d, want 1", code)
	}
	if stdout != "" {
		t.Errorf("stdout = %q, want empty", stdout)
	}
}

func TestRecallCorruptStateExits2(t *testing.T) {
	path := withTempState(t)
	// Pre-seed corrupt bytes.
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("not json"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	stdout, _, code := runCLI(t, "recall", "anything")
	if code != 2 {
		t.Errorf("exit code = %d, want 2", code)
	}
	if stdout != "" {
		t.Errorf("stdout = %q, want empty", stdout)
	}
}

func TestRecordRebuildsCorruptStateFile(t *testing.T) {
	path := withTempState(t)
	// Pre-seed garbage.
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte("not json"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// record MUST succeed even though state was corrupt.
	_, stderr, code := runCLI(t, "record", "work", "/tmp/x")
	if code != 0 {
		t.Fatalf("record exit = %d, stderr=%q", code, stderr)
	}
	// Notice on stderr per spec §6 edge #6.
	if !strings.Contains(stderr, "corrupt") {
		t.Errorf("stderr did not mention 'corrupt': %q", stderr)
	}
	// Post-condition: file now parses as valid JSON with our entry.
	raw, _ := os.ReadFile(path)
	var st State
	if err := json.Unmarshal(raw, &st); err != nil {
		t.Fatalf("post-record JSON parse: %v\nbytes=%s", err, raw)
	}
	if _, ok := st.Sessions["work"]; !ok {
		t.Errorf("'work' missing in post-record state: %+v", st)
	}
}

func TestListPrintsTSVSortedBySession(t *testing.T) {
	withTempState(t)
	if _, _, c := runCLI(t, "record", "zeta", "/tmp/z"); c != 0 {
		t.Fatalf("record zeta: %d", c)
	}
	if _, _, c := runCLI(t, "record", "alpha", "/tmp/a"); c != 0 {
		t.Fatalf("record alpha: %d", c)
	}
	if _, _, c := runCLI(t, "record", "mike", "/tmp/m"); c != 0 {
		t.Fatalf("record mike: %d", c)
	}
	stdout, _, code := runCLI(t, "list")
	if code != 0 {
		t.Fatalf("list exit = %d", code)
	}
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("got %d lines, want 3:\n%s", len(lines), stdout)
	}
	// Sorted alphabetically.
	wantPrefixes := []string{"alpha\t/tmp/a\t", "mike\t/tmp/m\t", "zeta\t/tmp/z\t"}
	for i, w := range wantPrefixes {
		if !strings.HasPrefix(lines[i], w) {
			t.Errorf("line %d = %q, want prefix %q", i, lines[i], w)
		}
	}
}

func TestForgetRemovesSessionAndIsIdempotent(t *testing.T) {
	path := withTempState(t)
	if _, _, c := runCLI(t, "record", "tmp", "/tmp/x"); c != 0 {
		t.Fatalf("record: %d", c)
	}
	if _, _, c := runCLI(t, "forget", "tmp"); c != 0 {
		t.Fatalf("forget: %d", c)
	}
	// Verify removal from disk.
	raw, _ := os.ReadFile(path)
	var st State
	_ = json.Unmarshal(raw, &st)
	if _, ok := st.Sessions["tmp"]; ok {
		t.Errorf("session 'tmp' still present after forget: %+v", st.Sessions)
	}
	// Idempotent: forgetting again still succeeds.
	if _, _, c := runCLI(t, "forget", "tmp"); c != 0 {
		t.Errorf("second forget exit = %d, want 0 (idempotent)", c)
	}
	// Also forgetting one that never existed.
	if _, _, c := runCLI(t, "forget", "never-was"); c != 0 {
		t.Errorf("forget never-was exit = %d, want 0", c)
	}
}

func TestRecordRejectsRelativePath(t *testing.T) {
	withTempState(t)
	_, stderr, code := runCLI(t, "record", "x", "relative/path")
	if code == 0 {
		t.Errorf("exit code = 0, want non-zero for relative path")
	}
	if !strings.Contains(stderr, "absolute") {
		t.Errorf("stderr did not mention 'absolute': %q", stderr)
	}
}

func TestRecordRejectsEmptySessionName(t *testing.T) {
	withTempState(t)
	_, _, code := runCLI(t, "record", "", "/tmp/x")
	if code == 0 {
		t.Error("exit code = 0, want non-zero for empty session")
	}
}

func TestUnknownSubcommandExits1(t *testing.T) {
	withTempState(t)
	_, stderr, code := runCLI(t, "frobnicate")
	if code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
	if !strings.Contains(stderr, "unknown subcommand") {
		t.Errorf("stderr did not mention unknown subcommand: %q", stderr)
	}
}

func TestNoArgsExits1(t *testing.T) {
	withTempState(t)
	_, _, code := runCLI(t, []string{}...)
	if code != 1 {
		t.Errorf("exit = %d, want 1", code)
	}
}

func TestRecordPreservesCreatedUnixOnUpdate(t *testing.T) {
	path := withTempState(t)
	if _, _, c := runCLI(t, "record", "k", "/a"); c != 0 {
		t.Fatalf("record 1: %d", c)
	}
	raw1, _ := os.ReadFile(path)
	var st1 State
	_ = json.Unmarshal(raw1, &st1)
	created1 := st1.Sessions["k"].CreatedUnix
	if created1 == 0 {
		t.Fatal("CreatedUnix not set on first record")
	}

	// Force a different LastSeen tick by sleeping past the second boundary.
	for time.Now().Unix() <= st1.Sessions["k"].LastSeenUnix {
		time.Sleep(50 * time.Millisecond)
	}

	if _, _, c := runCLI(t, "record", "k", "/b"); c != 0 {
		t.Fatalf("record 2: %d", c)
	}
	raw2, _ := os.ReadFile(path)
	var st2 State
	_ = json.Unmarshal(raw2, &st2)
	if got := st2.Sessions["k"].CreatedUnix; got != created1 {
		t.Errorf("CreatedUnix changed across update: %d -> %d", created1, got)
	}
	if st2.Sessions["k"].LastPwd != "/b" {
		t.Errorf("LastPwd not updated: %q", st2.Sessions["k"].LastPwd)
	}
}

func TestSetColorAndGetColor(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("TMX_STATE_FILE", tmp)

	var buf bytes.Buffer
	var stderr bytes.Buffer
	// set-color work red
	if rc := run([]string{"set-color", "work", "red"}, &buf, &stderr); rc != 0 {
		t.Fatalf("set-color rc=%d stderr=%s", rc, stderr.String())
	}
	// get-color work → "red"
	buf.Reset(); stderr.Reset()
	if rc := run([]string{"get-color", "work"}, &buf, &stderr); rc != 0 {
		t.Fatalf("get-color rc=%d", rc)
	}
	if buf.String() != "red" {
		t.Errorf("get-color = %q, want red", buf.String())
	}
	// get-color unknown → exit 1, empty
	buf.Reset()
	if rc := run([]string{"get-color", "nope"}, &buf, &stderr); rc != 1 {
		t.Errorf("get-color unknown rc=%d, want 1", rc)
	}
	if buf.String() != "" {
		t.Errorf("get-color unknown = %q, want empty", buf.String())
	}
}

func TestSetColorInvalid(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("TMX_STATE_FILE", tmp)
	var stdout, stderr bytes.Buffer
	if rc := run([]string{"set-color", "work", "notacolor"}, &stdout, &stderr); rc != 1 {
		t.Errorf("set-color invalid rc=%d, want 1", rc)
	}
}

// TestSetColorPreservesSiblingFields — set-color must not clobber last_pwd.
func TestSetColorPreservesSiblingFields(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("TMX_STATE_FILE", tmp)
	var o, e bytes.Buffer
	run([]string{"record", "work", "/tmp"}, &o, &e)
	o.Reset(); e.Reset()
	run([]string{"set-color", "work", "blue"}, &o, &e)
	// reload + check last_pwd intact
	st, err := loadState(tmp)
	if err != nil {
		t.Fatal(err)
	}
	if st.Sessions["work"].LastPwd != "/tmp" {
		t.Errorf("last_pwd clobbered = %q", st.Sessions["work"].LastPwd)
	}
	if st.Sessions["work"].Color != "blue" {
		t.Errorf("color = %q, want blue", st.Sessions["work"].Color)
	}
}
