#!/usr/bin/env bash
set -euo pipefail

checker="$(cd "$(dirname "$0")" && pwd)/check-privacy.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox"
git init -q
git config user.name 'Privacy tests'
git config user.email 'fixture@example.org'
export AITVARAS_PRIVACY_DENYLIST='private-fixture'
export CI=true

expect_blocked() {
    local report
    if report=$("$checker" "$@" 2>&1); then
        echo "Expected privacy check to reject the fixture ($*)" >&2
        exit 1
    fi
    if [[ "$report" != *'private denylist match'* || "$report" == *'private-fixture'* ]]; then
        echo "Expected a redacted denylist diagnostic ($*)" >&2
        exit 1
    fi
}

printf '%s\n' 'A public example and fixture@example.org' | "$checker" --text
printf '%s\n' 'refs/heads/private-fixture' | expect_blocked --text

touch private-fixture.md
git add private-fixture.md
expect_blocked --staged
git -c core.hooksPath=/dev/null commit -qm 'Add a fixture'
expect_blocked --commits HEAD

printf '%s\n' 'A safe publication draft' | (
    export AITVARAS_PRIVACY_DENYLIST='['
    if "$checker" --text; then
        echo 'Expected an invalid denylist to block publication' >&2
        exit 1
    fi
)
