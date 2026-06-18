# tmx-color-lib.sh — pure helpers for per-session color parsing/validation.
#
# Sourced by the generated tmx wrapper AND by unit test
# scripts/tests/64_session_color_parse_unit.sh. Contains NO side effects,
# NO tmux calls, NO state writes — only:
#   _parse_session_value <raw>   sets globals PARSED_NAME + PARSED_COLOR
#   _color_valid <token>          return 0 iff token is a valid tmux color
#   CANON_COLOR_NAMES             space-list, byte-twin of Go CanonColorNames
#
# POSIX-portable (parses under sh -n per §11.4.67); sourced by the bash
# wrapper but written to avoid bash-only constructs.
#
# Canonical name set — keep byte-identical to scripts/tmx-state/color.go
# (CanonColorNames). A divergence is a §11.4.6 guessing surface; both sides
# are cross-checked by Go TestCanonColorNamesBashTwin + test 64.
CANON_COLOR_NAMES="red green yellow blue magenta cyan white black brightred brightgreen brightyellow brightblue brightmagenta brightcyan brightwhite default terminal"

# _parse_session_value <raw>
# Split on unescaped ':'. Escapes (\:) honored ONLY in field 0 (the name).
# Sets: PARSED_NAME (raw, pre-_sanitise), PARSED_COLOR ("" if none).
# Pure; emits nothing to stdout/stderr.
_parse_session_value() {
    PARSED_NAME=""
    PARSED_COLOR=""
    raw="${1-}"
    i=0
    field=0
    name=""
    color=""
    rest=""
    len=${#raw}
    while [ "$i" -lt "$len" ]; do
        ch="${raw:$i:1}"
        # Escape handling only in field 0.
        if [ "$field" -eq 0 ] && [ "$ch" = '\' ]; then
            nxt="${raw:$((i+1)):1}"
            if [ "$nxt" = ":" ]; then
                name="${name}:"   # unescape \: → literal :
                i=$((i+2))
                continue
            fi
            # A backslash not before ':' is a literal backslash.
            name="${name}\\"
            i=$((i+1))
            continue
        fi
        if [ "$ch" = ":" ]; then
            field=$((field+1))
            i=$((i+1))
            continue
        fi
        if [ "$field" -eq 0 ]; then
            name="${name}${ch}"
        elif [ "$field" -eq 1 ]; then
            color="${color}${ch}"
        else
            rest="${rest}${ch}"
        fi
        i=$((i+1))
    done
    PARSED_NAME="$name"
    PARSED_COLOR="$color"
    # rest is intentionally discarded (forward-compatible; decision #5).
    return 0
}

# _color_valid <token>
# Return 0 iff token is a valid tmux color (name / colourNNN / #hex).
_color_valid() {
    t="${1-}"
    [ -n "$t" ] || return 1
    # Canonical names, case-insensitive.
    low=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
    for n in $CANON_COLOR_NAMES; do
        [ "$low" = "$n" ] && return 0
    done
    # colourNNN / colorNNN, 0..255. Match case-insensitively via a lowercased
    # copy so "Color7" / "COLOUR39" also validate.
    lowcolour="$low"
    case "$lowcolour" in
        colour[0-9]|colour[0-9][0-9]|colour[0-9][0-9][0-9])
            num="${lowcolour#colour}"
            case "$num" in ''|*[!0-9]*) return 1 ;; esac
            [ "$num" -ge 0 ] 2>/dev/null && [ "$num" -le 255 ] 2>/dev/null && return 0
            return 1
            ;;
        color[0-9]|color[0-9][0-9]|color[0-9][0-9][0-9])
            num="${lowcolour#color}"
            case "$num" in ''|*[!0-9]*) return 1 ;; esac
            [ "$num" -ge 0 ] 2>/dev/null && [ "$num" -le 255 ] 2>/dev/null && return 0
            return 1
            ;;
    esac
    # #RGB or #RRGGBB hex. Use grep -E (ERE) — POSIX case-glob bracket
    # expressions mis-handle hex letters in some shells; grep -Eq is
    # unambiguous + already used elsewhere in this codebase.
    if printf '%s' "$t" | grep -Eq '^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$'; then
        return 0
    fi
    return 1
}
