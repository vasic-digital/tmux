package main

import "testing"

func TestValidColor(t *testing.T) {
	good := []string{
		"red", "Red", "RED", // case-insensitive names
		"green", "yellow", "blue", "magenta", "cyan", "white", "black",
		"brightred", "brightcyan", "default", "terminal",
		"colour0", "colour255", "colour39", "color160", "Color7",
		"#3b82f6", "#FFF", "#f0a", "#000000",
	}
	for _, c := range good {
		if !validColor(c) {
			t.Errorf("validColor(%q) = false, want true", c)
		}
	}
	bad := []string{
		"", "purple", "colour256", "colour-1", "colour", "color1234",
		"#12", "#12345", "#GGG", "3b82f6", "red ", " red",
	}
	for _, c := range bad {
		if validColor(c) {
			t.Errorf("validColor(%q) = true, want false", c)
		}
	}
}

// TestCanonColorNamesBashTwin asserts the Go list is byte-identical to the
// bash lib's list. The exact same space-separated string appears in
// scripts/tmx-color-lib.sh::CANON_COLOR_NAMES. A divergence is a §11.4.6
// guessing surface. (The bash side mirrors this in test 64.)
func TestCanonColorNamesBashTwin(t *testing.T) {
	want := "red green yellow blue magenta cyan white black brightred brightgreen brightyellow brightblue brightmagenta brightcyan brightwhite default terminal"
	got := ""
	for i, n := range CanonColorNames {
		if i > 0 {
			got += " "
		}
		got += n
	}
	if got != want {
		t.Errorf("CanonColorNames drift:\n got: %q\nwant: %q", got, want)
	}
}
