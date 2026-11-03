# Shared by the git hooks. Installed with them by scripts/install-hooks.sh into
# the repository's common git dir, so the hooks also run in worktrees whose
# checkout predates them.
root="$(git rev-parse --show-toplevel)"
hooks_dir="$(cd "$(dirname "$0")" && pwd)"

# Prefer the checkout's own copy of a check script; fall back to the copy
# installed next to the hooks.
tool() {
    if [ -x "$root/scripts/$1" ]; then echo "$root/scripts/$1"; else echo "$hooks_dir/$1"; fi
}

# Remotes listed in `git config aitvaras.privateRemote` (one per entry) are
# private archives; publication checks don't apply to them.
is_private_remote() {
    [ -n "$1" ] && git config --get-all aitvaras.privateRemote 2>/dev/null | grep -qxF "$1"
}
