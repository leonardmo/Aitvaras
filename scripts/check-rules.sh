#!/usr/bin/env bash
# Hard rules from AGENTS.md that a script can check, so they don't depend on
# a reviewer noticing. Runs in `make check` and in CI.
#
#   scripts/check-rules.sh                 # compare migrations with origin/main
#   scripts/check-rules.sh --base <rev>    # compare migrations with <rev>
#
# Checks:
# - no cloud LLM API endpoints in app code (local only);
# - no way to send email (D20): compose APIs, AppleScript outgoing messages,
#   SMTP clients;
# - migrations that already exist on the base are unchanged and keep their
#   order (new migrations are appended).
#
# The other hard rules (autonomy policy, memory discipline, GRDB UUIDs) need
# judgment and stay with the reviewer agent. If a check is wrong, fix the
# pattern here with a test case in mind; don't rename things to dodge it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

BASE=origin/main
case "${1:-}" in
    --base) [[ -n "${2:-}" ]] || { echo "usage: $0 [--base <rev>]" >&2; exit 2; }; BASE=$2 ;;
    "") ;;
    *) echo "usage: $0 [--base <rev>]" >&2; exit 2 ;;
esac

CODE_PATHS=(Sources App helper voice)
FAILED=0

# Tracked and new (not ignored) files, so uncommitted work is checked too.
scan() {
    local label=$1 regex=$2 hits
    if hits=$(git grep --untracked -nIiE "$regex" -- "${CODE_PATHS[@]}"); then
        echo "✗ $label:" >&2
        sed 's/^/    /' <<< "$hits" >&2
        FAILED=1
    fi
}

scan "cloud LLM endpoint (AGENTS.md: local only)" \
    'api\.anthropic\.com|api\.openai\.com|openai\.azure\.com|generativelanguage\.googleapis\.com|aiplatform\.googleapis\.com|bedrock-runtime|api\.mistral\.ai|api\.groq\.com|api\.cohere\.(ai|com)|openrouter\.ai|api\.together\.(ai|xyz)|api\.deepseek\.com|api\.x\.ai'

scan "email sending capability (D20: mail is read/search only)" \
    'MFMailComposeViewController|\.composeEmail\b|outgoing message|smtplib|nodemailer|SwiftSMTP|smtps?://'

# Migrations: every block registered on the base must be byte-identical
# (ignoring trailing whitespace) and in the same order on this side.
MIGRATIONS=Sources/AitvarasStore/Database.swift
blocks() {
    awk '
        /^[[:space:]]*return m[[:space:]]*$/ { inside = 0 }
        match($0, /registerMigration\("[^"]+"\)/) {
            inside = 1
            print "@@ " substr($0, RSTART + 19, RLENGTH - 21)
            next
        }
        inside { sub(/[[:space:]]+$/, ""); print }
    '
}

if ! git rev-parse --verify -q "$BASE^{commit}" > /dev/null; then
    echo "• migrations: base $BASE not available, skipped (git fetch origin)"
elif ! FORK=$(git merge-base "$BASE" HEAD) || ! git cat-file -e "$FORK:$MIGRATIONS" 2> /dev/null; then
    echo "• migrations: no $MIGRATIONS on the base, skipped"
else
    OLD=$(git show "$FORK:$MIGRATIONS" | blocks)
    COUNT=$(grep -c '^@@ ' <<< "$OLD" || true)
    # This side up to the first migration the base doesn't have. Read to the end
    # instead of exiting early: an early exit kills the writer with SIGPIPE, and
    # pipefail turns that into a silent exit 141.
    NEW=$(blocks < "$MIGRATIONS" | awk -v n="$COUNT" '/^@@ / && ++seen > n { done = 1 } !done { print }')
    if [[ "$OLD" != "$NEW" ]]; then
        echo "✗ existing migrations changed, reordered or removed (append a new vN-topic migration instead):" >&2
        diff -u <(echo "$OLD") <(echo "$NEW") | tail -n +3 | grep -E '^[-+@]' | head -40 | sed 's/^/    /' >&2 || true
        FAILED=1
    fi
fi

[[ "$FAILED" -eq 0 ]] && echo "✓ hard-rule checks passed"
exit "$FAILED"
