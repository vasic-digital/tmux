#!/bin/sh
# tmx-ssh-install -- client-side bootstrapper for `ssh <host>-tmx <session>`.
# Project: vasic-digital tmux
# Documentation: docs/scripts/tmx-ssh-install.md
# §11.4.67 POSIX-parseable (sh -n clean) -- runs on macOS bash 3.2 + Linux dash/bash.
#
# Behaviour contract (see spec §4.D):
#   1. Validate args (user@host required).
#   2. Generate ~/.ssh/id_tmx_<sanitized-host> if missing (NEVER overwrite without --force).
#   3. Probe remote reachability via an existing working auth path.
#   4. Stage dispatcher template + substitute __PROJECT__/__DATE__ on remote (mode 0755).
#   5. Append `command="..."` line to remote ~/.ssh/authorized_keys (idempotent by fingerprint).
#   6. Append Host alias to local ~/.ssh/config (idempotent by Host heading).
#   7. Verify with a token that won't match the dispatcher regex; expect stderr + exit 1.
#   8. Print success summary + uninstall hint.
#
# Idempotent: every step checks before mutating.  Re-running is a no-op.

set -u

PROG="tmx-ssh-install"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/tmx-ssh-dispatch.sh.template"

log()  { printf '[%s] %s\n' "$PROG" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; exit 1; }
step() { printf '[%s] step %s: %s\n' "$PROG" "$1" "$2" >&2; }

usage() {
    cat >&2 <<USAGE
Usage:
  $PROG <user>@<host> [--remote-project-path /path/on/remote]
  $PROG --uninstall <user>@<host> [--purge-key]
  $PROG --dry-run    <user>@<host> [--remote-project-path /path/on/remote]
  $PROG -h | --help

Defaults:
  --remote-project-path  ~/Projects/tmux

Examples:
  $PROG milos@nezha.local
  $PROG milos@nezha.local --remote-project-path /opt/tmux
  $PROG --uninstall milos@nezha.local --purge-key

See docs/scripts/tmx-ssh-install.md and docs/guides/tmx-ssh-dispatch.md.
USAGE
}

# ---------------------------------------------------------------- args ----
TARGET=""
REMOTE_PROJECT="~/Projects/tmux"
MODE="install"
PURGE_KEY=0
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)              usage; exit 0 ;;
        --uninstall)            MODE="uninstall" ;;
        --purge-key)            PURGE_KEY=1 ;;
        --force)                FORCE=1 ;;
        --dry-run)              DRY_RUN=1 ;;
        --remote-project-path)  shift; [ $# -gt 0 ] || die "--remote-project-path needs a value"; REMOTE_PROJECT="$1" ;;
        --remote-project-path=*) REMOTE_PROJECT="${1#--remote-project-path=}" ;;
        --*)                    die "unknown flag: $1 (try --help)" ;;
        *)                      [ -z "$TARGET" ] || die "multiple targets: '$TARGET' and '$1'"; TARGET="$1" ;;
    esac
    shift
done

[ -n "$TARGET" ] || { usage; die "missing <user>@<host>"; }

# Sanity-check target shape: <non-empty>@<non-empty>, sane characters.
case "$TARGET" in
    *@*) ;;
    *)   die "target must be in user@host form, got: '$TARGET'" ;;
esac
case "$TARGET" in
    *[!A-Za-z0-9._@-]*) die "target contains forbidden characters: '$TARGET'" ;;
esac

REMOTE_USER="${TARGET%@*}"
REMOTE_HOST="${TARGET#*@}"
[ -n "$REMOTE_USER" ] || die "empty user in target: '$TARGET'"
[ -n "$REMOTE_HOST" ] || die "empty host in target: '$TARGET'"

# Sanitize host for filename (replace dots & colons with underscores).
SANITIZED_HOST="$(printf '%s\n' "$REMOTE_HOST" | tr './:' '___')"
KEY_PATH="$HOME/.ssh/id_tmx_${SANITIZED_HOST}"
PUB_PATH="${KEY_PATH}.pub"
ALIAS_HOST="${REMOTE_HOST}-tmx"

# Helper: run-or-print depending on --dry-run.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[%s] DRY-RUN would run: %s\n' "$PROG" "$*" >&2
        return 0
    fi
    "$@"
}

# ssh wrappers honour dry-run too.
ssh_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[%s] DRY-RUN would ssh %s -- %s\n' "$PROG" "$TARGET" "$*" >&2
        return 0
    fi
    ssh -o BatchMode=yes "$TARGET" "$@"
}
scp_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[%s] DRY-RUN would scp %s %s:%s\n' "$PROG" "$1" "$TARGET" "$2" >&2
        return 0
    fi
    scp -q "$1" "$TARGET:$2"
}

# ---------------------------------------------------------- uninstall ----
if [ "$MODE" = "uninstall" ]; then
    step 1 "uninstall: remove authorized_keys line on $TARGET (by fingerprint)"
    if [ -f "$PUB_PATH" ]; then
        FPR="$(ssh-keygen -lf "$PUB_PATH" 2>/dev/null | awk '{print $2}')"
    else
        FPR=""
        log "no local pubkey at $PUB_PATH; will skip fingerprint match"
    fi
    if [ -n "$FPR" ]; then
        # Build a remote one-liner that filters out matching lines.
        REMOTE_SCRIPT='set -eu
ak="$HOME/.ssh/authorized_keys"
[ -f "$ak" ] || exit 0
tmp="$(mktemp)"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ""|"#"*) printf "%s\n" "$line" >> "$tmp"; continue ;;
    esac
    fpr="$(printf "%s\n" "$line" | ssh-keygen -lf - 2>/dev/null | awk "{print \$2}")"
    if [ "$fpr" = "'"$FPR"'" ]; then continue; fi
    printf "%s\n" "$line" >> "$tmp"
done < "$ak"
chmod 600 "$tmp"
mv "$tmp" "$ak"'
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '[%s] DRY-RUN would ssh %s -- (strip line with fingerprint %s)\n' "$PROG" "$TARGET" "$FPR" >&2
        else
            ssh -o BatchMode=yes "$TARGET" "sh -c '$REMOTE_SCRIPT'"
        fi
    fi

    step 2 "uninstall: remove Host alias '$ALIAS_HOST' from ~/.ssh/config"
    if [ -f "$HOME/.ssh/config" ]; then
        TMPCFG="$(mktemp)"
        awk -v alias="Host $ALIAS_HOST" '
            BEGIN { skip=0 }
            /^Host / { if ($0 == alias) { skip=1; next } else { skip=0 } }
            skip == 1 { next }
            { print }
        ' "$HOME/.ssh/config" > "$TMPCFG"
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '[%s] DRY-RUN would rewrite ~/.ssh/config (drop Host %s block)\n' "$PROG" "$ALIAS_HOST" >&2
            rm -f "$TMPCFG"
        else
            chmod 600 "$TMPCFG"
            mv "$TMPCFG" "$HOME/.ssh/config"
        fi
    fi

    if [ "$PURGE_KEY" -eq 1 ]; then
        step 3 "uninstall: purge local key $KEY_PATH"
        run rm -f "$KEY_PATH" "$PUB_PATH"
    fi

    log "uninstall complete for $TARGET"
    exit 0
fi

# -------------------------------------------------------------- install ---
[ -f "$TEMPLATE" ] || die "dispatcher template missing: $TEMPLATE"

step 1 "validate target ($TARGET) and remote project path ($REMOTE_PROJECT)"

step 2 "ensure local key $KEY_PATH (ed25519, BatchMode-friendly)"
if [ -f "$KEY_PATH" ] && [ "$FORCE" -eq 0 ]; then
    log "key exists, leaving in place"
else
    if [ -f "$KEY_PATH" ] && [ "$FORCE" -eq 1 ]; then
        log "--force given: overwriting existing key"
        run rm -f "$KEY_PATH" "$PUB_PATH"
    fi
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    run ssh-keygen -q -t ed25519 -N '' -C "tmx-dispatch-${SANITIZED_HOST}" -f "$KEY_PATH"
fi

step 3 "probe remote reachability via existing auth path (BatchMode)"
if [ "$DRY_RUN" -eq 0 ]; then
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" exit 0 2>/dev/null; then
        die "cannot reach $TARGET non-interactively; run 'ssh-copy-id $TARGET' or similar first"
    fi
    log "reachable"
else
    printf '[%s] DRY-RUN would: ssh -o BatchMode=yes -o ConnectTimeout=5 %s exit 0\n' "$PROG" "$TARGET" >&2
fi

step 4 "stage dispatcher template + substitute on remote"
REMOTE_TEMPLATE_PATH="$REMOTE_PROJECT/scripts/tmx-ssh-dispatch.sh.template"
REMOTE_DISPATCH_PATH="$REMOTE_PROJECT/scripts/tmx-ssh-dispatch.sh"

# Refuse to clobber a remote project that doesn't exist.
if [ "$DRY_RUN" -eq 0 ]; then
    if ! ssh -o BatchMode=yes "$TARGET" "test -d '$REMOTE_PROJECT/scripts'" 2>/dev/null; then
        die "remote project dir not found at $REMOTE_PROJECT/scripts -- clone the project there first"
    fi
fi
scp_run "$TEMPLATE" "$REMOTE_TEMPLATE_PATH"

NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
REMOTE_GEN_SCRIPT="set -eu
proj='$REMOTE_PROJECT'
tpl=\"\$proj/scripts/tmx-ssh-dispatch.sh.template\"
out=\"\$proj/scripts/tmx-ssh-dispatch.sh\"
sed -e \"s|__PROJECT__|\$proj|g\" -e \"s|__DATE__|$NOW_ISO|g\" \"\$tpl\" > \"\$out\"
chmod 0755 \"\$out\""
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[%s] DRY-RUN would ssh %s -- substitute __PROJECT__/__DATE__ -> %s (mode 0755)\n' "$PROG" "$TARGET" "$REMOTE_DISPATCH_PATH" >&2
else
    ssh -o BatchMode=yes "$TARGET" "sh -c '$REMOTE_GEN_SCRIPT'"
fi

step 5 "install authorized_keys entry (idempotent by fingerprint)"
PUBKEY_CONTENT=""
if [ -f "$PUB_PATH" ]; then
    PUBKEY_CONTENT="$(awk '{print $1, $2}' "$PUB_PATH")"
fi
if [ -z "$PUBKEY_CONTENT" ] && [ "$DRY_RUN" -eq 0 ]; then
    die "could not read pubkey at $PUB_PATH"
fi
LOCAL_FPR=""
if [ -f "$PUB_PATH" ]; then
    LOCAL_FPR="$(ssh-keygen -lf "$PUB_PATH" 2>/dev/null | awk '{print $2}')"
fi
AK_LINE="command=\"$REMOTE_DISPATCH_PATH\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUBKEY_CONTENT tmx-dispatch-${SANITIZED_HOST}"
REMOTE_AK_SCRIPT="set -eu
mkdir -p \"\$HOME/.ssh\"
chmod 700 \"\$HOME/.ssh\"
ak=\"\$HOME/.ssh/authorized_keys\"
touch \"\$ak\"
chmod 600 \"\$ak\"
# Idempotency: skip if any existing line has the same fingerprint.
already=0
while IFS= read -r line || [ -n \"\$line\" ]; do
    case \"\$line\" in ''|'#'*) continue ;; esac
    fpr=\"\$(printf '%s\n' \"\$line\" | ssh-keygen -lf - 2>/dev/null | awk '{print \$2}')\"
    if [ \"\$fpr\" = '$LOCAL_FPR' ]; then already=1; break; fi
done < \"\$ak\"
if [ \"\$already\" -eq 1 ]; then
    echo '[remote] authorized_keys already has this key (by fingerprint); skipping'
    exit 0
fi
printf '%s\n' '$AK_LINE' >> \"\$ak\"
echo '[remote] appended authorized_keys entry'"
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[%s] DRY-RUN would ssh %s -- append authorized_keys line (fpr=%s)\n' "$PROG" "$TARGET" "$LOCAL_FPR" >&2
    printf '[%s] DRY-RUN AK_LINE: %s\n' "$PROG" "$AK_LINE" >&2
else
    ssh -o BatchMode=yes "$TARGET" "sh -c '$REMOTE_AK_SCRIPT'"
fi

step 6 "install Host alias '$ALIAS_HOST' in local ~/.ssh/config (idempotent)"
CFG="$HOME/.ssh/config"
if [ -f "$CFG" ] && grep -q "^Host $ALIAS_HOST\$" "$CFG" 2>/dev/null; then
    log "Host '$ALIAS_HOST' already present in $CFG; skipping"
else
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[%s] DRY-RUN would append Host %s block to %s\n' "$PROG" "$ALIAS_HOST" "$CFG" >&2
    else
        run mkdir -p "$HOME/.ssh"
        run chmod 700 "$HOME/.ssh"
        : > /dev/null  # appease set -u for $CFG presence
        {
            printf '\n# tmx-ssh-dispatch alias for %s (added by %s on %s)\n' "$TARGET" "$PROG" "$NOW_ISO"
            printf 'Host %s\n' "$ALIAS_HOST"
            printf '    HostName %s\n' "$REMOTE_HOST"
            printf '    User %s\n' "$REMOTE_USER"
            printf '    IdentityFile %s\n' "$KEY_PATH"
            printf '    IdentitiesOnly yes\n'
            printf '    PreferredAuthentications publickey\n'
        } >> "$CFG"
        chmod 600 "$CFG"
    fi
fi

step 7 "verification probe (token deliberately fails dispatcher regex)"
if [ "$DRY_RUN" -eq 1 ]; then
    printf '[%s] DRY-RUN would: ssh %s tmx-install-verify-token-XXXX (expect exit 1 + stderr [tmx-ssh-dispatch]...)\n' "$PROG" "$ALIAS_HOST" >&2
else
    TOKEN="tmx-install-verify-token-XXXX"
    PROBE_STDERR="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$ALIAS_HOST" "$TOKEN" 2>&1 1>/dev/null)" || true
    case "$PROBE_STDERR" in
        *"[tmx-ssh-dispatch]"*)
            log "verification PASS: dispatcher rejected the probe token as designed"
            ;;
        *)
            die "verification FAIL: probe did not produce expected [tmx-ssh-dispatch] stderr. Got: '$PROBE_STDERR'"
            ;;
    esac
fi

step 8 "summary"
cat >&2 <<SUMMARY

[$PROG] install complete.

  local key:        $KEY_PATH (+ .pub)
  local alias:      Host $ALIAS_HOST in ~/.ssh/config
  remote dispatch:  $REMOTE_DISPATCH_PATH
  remote authkey:   ~/.ssh/authorized_keys (one entry, marked tmx-dispatch-${SANITIZED_HOST})

Usage:
  ssh $ALIAS_HOST           # empty command -> interactive login shell
  ssh $ALIAS_HOST work      # attaches/creates tmx session 'work' with restored cwd

Uninstall:
  $0 --uninstall $TARGET [--purge-key]
SUMMARY

exit 0
