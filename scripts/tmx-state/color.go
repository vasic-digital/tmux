// Package main — color token validation (Go twin of the bash lib).
//
// The accepted set is the SINGLE source of truth shared with the bash
// helper scripts/tmx-color-lib.sh (CANON_COLOR_NAMES). color_test.go +
// scripts/tests/64_session_color_parse_unit.sh assert both sides agree on
// a probe set, so persistence (Go) and CLI parsing (bash) can never
// disagree on what a valid color is (§11.4.6).

package main

import (
	"regexp"
	"strings"
)

// CanonColorNames — byte-identical twin of bash CANON_COLOR_NAMES.
// Keep in lockstep with scripts/tmx-color-lib.sh.
var CanonColorNames = []string{
	"red", "green", "yellow", "blue", "magenta", "cyan", "white", "black",
	"brightred", "brightgreen", "brightyellow", "brightblue", "brightmagenta",
	"brightcyan", "brightwhite", "default", "terminal",
}

var (
	reColourIdx = regexp.MustCompile(`^(?i)colou?r([0-9]{1,3})$`)
	reHex       = regexp.MustCompile(`^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$`)
)

// validColor reports whether s is a tmux-acceptable color token:
//   - a canonical name (case-insensitive);
//   - colourNNN / colorNNN with N in 0..255;
//   - #RGB or #RRGGBB hex.
func validColor(s string) bool {
	if s == "" {
		return false
	}
	low := strings.ToLower(s)
	for _, n := range CanonColorNames {
		if low == n {
			return true
		}
	}
	if m := reColourIdx.FindStringSubmatch(s); m != nil {
		// m[1] is 1-3 digits; value range check.
		var v int
		for _, ch := range m[1] {
			v = v*10 + int(ch-'0')
		}
		return v >= 0 && v <= 255
	}
	return reHex.MatchString(s)
}
