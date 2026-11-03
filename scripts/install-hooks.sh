#!/usr/bin/env bash
# Installs the git hooks and the check scripts they call into the repository's
# common git dir and points core.hooksPath there. Because the path is shared
# by every worktree, the hooks also guard checkouts of older branches that
# don't contain .githooks/. Re-run after the hooks or check scripts change
# (`make setup` does; the Claude Code SessionStart hook does too).
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
dest="$common/aitvaras-hooks"

mkdir -p "$dest" "$common/info"
cp "$root"/.githooks/* "$dest/"
cp "$root/scripts/check-privacy.sh" "$root/scripts/check-commits.sh" "$dest/"
chmod +x "$dest"/pre-commit "$dest"/commit-msg "$dest"/pre-push "$dest"/check-*.sh
git config core.hooksPath "$dest"

denylist="$common/info/privacy-denylist"
if [[ ! -f "$denylist" ]]; then
    cat > "$denylist" <<'TEMPLATE'
# Private denylist for scripts/check-privacy.sh. Never committed.
# One case-insensitive extended regex per line: your name, email addresses,
# university, city, hostnames, project names, anything that must never be
# published. Example: (^|[^a-z])acme([^a-z]|$)
TEMPLATE
    echo "Created $denylist: add your private terms there."
fi
echo "Hooks installed in $dest"
