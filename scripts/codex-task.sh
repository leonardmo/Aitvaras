#!/usr/bin/env bash
# Runs Codex CLI as a supervised worker on one branch. The supervisor (a Claude
# Code session following .claude/skills/supervise) calls this script; Codex edits
# the worktree and this script alone commits.
#
#   limits                         Codex usage windows (spends no tokens)
#   wait-limit [percent]           sleep until every window is below percent (98)
#   prepare <branch> [base]        create the worktree and fetch packages
#   sync <branch>                  fetch packages again after a dependency change
#   run <branch> <prompt-file> [--new] [--plan] [--net] [--web]
#                              [--effort E] [--model M] [--stall-minutes N]
#                                  run or resume Codex in the sandbox
#   sandbox <branch> -- <cmd...>   run a command in the sandbox, spends no tokens
#   verify <branch> [--app|--host] privacy and tests in the sandbox; --app adds
#                                  the app build, --host runs everything unsandboxed
#   commit <branch> <message-file> commit the worktree through the hooks
#   status                         worktrees, sessions and last results
#   remove <branch>                delete the worktree, keep the branch
#
# `run` exit codes: 0 finished, 75 usage limit reached (wait-limit, then run
# again to resume), 124 stalled and killed, anything else failed.
set -euo pipefail

self_dir="$(cd "$(dirname "$0")" && pwd)"
common="$(cd "$(git -C "$self_dir" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
state_root="$common/aitvaras-codex"
# Outside the home folder: the sandbox blocks all of home, and the compilers
# fail unless they can read every parent of their working directory.
worktree_root="${AITVARAS_CODEX_ROOT:-$(dirname "$HOME")/Shared/aitvaras-codex}"
model_default="${AITVARAS_CODEX_MODEL:-gpt-6.1-sol}"
effort_default="${AITVARAS_CODEX_EFFORT:-high}"

# Codex may read these but never change them: they decide what gets published
# and what this script runs on the host.
guarded_paths=(.git .githooks .github .claude scripts/check-privacy.sh
    scripts/check-commits.sh scripts/install-hooks.sh scripts/codex-task.sh
    scripts/codex-limits.py scripts/codex-swift.sh)

die() { echo "codex-task: $*" >&2; exit 1; }

codex_bin() {
    local candidate
    for candidate in "${CODEX_BIN:-}" "$(command -v codex || true)" \
        /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex \
        /Applications/Codex.app/Contents/Resources/codex; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then echo "$candidate"; return; fi
    done
    die "Codex CLI not found; set CODEX_BIN"
}

slug() { echo "${1//\//-}"; }
worktree_of() { echo "$worktree_root/$(slug "$1")"; }
state_of() { echo "$state_root/$(slug "$1")"; }
require_worktree() { [[ -d "$(worktree_of "$1")" ]] || die "no worktree for $1; run prepare first"; }
installed_privacy() { echo "$common/aitvaras-hooks/check-privacy.sh"; }

# The sandbox: all of home is unreadable (Codex login, tokens, SSH keys, private
# folders), the only writable places are the worktree and scratch folders, and
# the guarded paths and the private denylist stay protected.
sandbox_flags() {
    local worktree="$1" worktree_access="$2" network="$3" work cache entries path
    work="$worktree/.build/codex-home"
    mkdir -p "$work/tmp" "$work/clang"
    cache="$(getconf DARWIN_USER_CACHE_DIR)clang"
    mkdir -p "$cache"
    cache="$(cd "$cache" && pwd -P)"
    entries="\":minimal\"=\"read\",\":tmpdir\"=\"write\",\"/tmp\"=\"write\""
    entries+=",\"$(dirname "$HOME")\"=\"read\",\"$HOME\"=\"none\""
    entries+=",\"$common\"=\"read\",\"$common/info/privacy-denylist\"=\"none\""
    entries+=",\"$common/config\"=\"read\""
    entries+=",\"/private/var/run/com.apple.security.cryptexd/mnt\"=\"read\",\"$cache\"=\"write\""
    entries+=",\"$worktree\"=\"$worktree_access\",\"$work\"=\"write\""
    for path in "${guarded_paths[@]}"; do
        entries+=",\"$worktree/$path\"=\"read\""
    done
    printf '%s\n' \
        -c 'default_permissions="supervised"' \
        -c "permissions.supervised.filesystem={$entries}" \
        -c "permissions.supervised.network.enabled=$network"
}

sandbox_env() {
    local work="$1/.build/codex-home"
    printf 'HOME=%s\nTMPDIR=%s/tmp\nCLANG_MODULE_CACHE_PATH=%s/clang\nGIT_CONFIG_NOSYSTEM=1\nGH_CONFIG_DIR=/nonexistent\nGH_TOKEN=\nGITHUB_TOKEN=\n' \
        "$work" "$work" "$work"
}

preamble() {
    cat <<'PREAMBLE'
You are a worker supervised by another agent, who reviews everything you produce.
Nobody answers questions during this run, so decide and record the assumption.

Rules for this environment:
- Read AGENTS.md first and follow it, especially the hard rules and "Public
  repository hygiene": no private data anywhere, including tests and fixtures.
- Read docs/DECISIONS.md before changing direction. If the task would break a
  hard rule or a decision, stop and report that instead of working around it.
- The sandbox has no network and no access to the home folder. If something is
  denied, do not look for a way around it; report what you need.
- Build and test only through `scripts/codex-swift.sh build --build-tests` and
  `scripts/codex-swift.sh test --skip-build`, because plain `swift` fails here.
  `make privacy` works normally. `make app` and `make node-test` do not work in
  this sandbox, and a handful of Swift tests are skipped. The supervisor runs
  those on the host and sends you any failures, so for App/ changes say what you
  could not compile.
- Do not commit, push, or edit .git, .githooks, .github, .claude or the
  check/harness scripts. Leave your changes uncommitted; the supervisor commits.

End your final message with exactly these sections:
SUMMARY: what now works.
CHANGED: the files you changed and why.
VERIFIED: every check you ran and its result.
NOT VERIFIED: what you could not check, and what only a person could check.
DECISIONS: assumptions you made that the supervisor should review.
COMMIT MESSAGE: an imperative subject of 72 characters or fewer, then a body
saying why. No attribution trailers.

The task:

PREAMBLE
}

cmd_limits() { python3 "$self_dir/codex-limits.py" "$(codex_bin)" "$@"; }

cmd_wait_limit() {
    local percent="${1:-98}" seconds
    while :; do
        seconds="$(cmd_limits --seconds-until-free "$percent")"
        [[ "$seconds" -le 0 ]] && break
        # Short naps so a sleeping Mac can't overshoot the reset by much.
        echo "Codex is at its limit; waiting ${seconds}s" >&2
        sleep "$(( seconds < 600 ? seconds + 30 : 600 ))"
    done
    cmd_limits
}

fetch_packages() {
    local worktree="$1"
    ( cd "$worktree"
      swift package resolve --disable-keychain >/dev/null
      xcodegen generate --quiet
      xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -derivedDataPath .build-xcode \
          -skipMacroValidation -skipPackagePluginValidation -resolvePackageDependencies >/dev/null )
}

cmd_prepare() {
    local branch="${1:?branch required}" base="${2:-origin/main}" worktree
    worktree="$(worktree_of "$branch")"
    mkdir -m 700 -p "$worktree_root"
    git -C "$self_dir" fetch origin --quiet
    if [[ -d "$worktree" ]]; then
        echo "Worktree exists: $worktree"
    elif git -C "$self_dir" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$self_dir" worktree add -q "$worktree" "$branch"
    else
        git -C "$self_dir" worktree add -q --no-track -b "$branch" "$worktree" "$base"
    fi
    mkdir -p "$(state_of "$branch")"
    fetch_packages "$worktree"
    echo "$worktree"
}

cmd_sync() {
    local branch="${1:?branch required}"
    require_worktree "$branch"
    fetch_packages "$(worktree_of "$branch")"
}

cmd_run() {
    local branch="${1:?branch required}" prompt_file="${2:?prompt file required}"
    shift 2
    local new=0 access=write network=false web=disabled effort="$effort_default"
    local model="$model_default" stall=45
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new) new=1 ;;
            --plan) access=read ;;
            --net) network=true ;;
            --web) web=live ;;
            --effort) effort="$2"; shift ;;
            --model) model="$2"; shift ;;
            --stall-minutes) stall="$2"; shift ;;
            *) die "unknown run option $1" ;;
        esac
        shift
    done
    require_worktree "$branch"
    [[ -f "$prompt_file" ]] || die "no prompt file $prompt_file"

    local worktree state bin session="" stamp log result prompt line
    worktree="$(worktree_of "$branch")"
    state="$(state_of "$branch")"
    bin="$(codex_bin)"
    mkdir -p "$state"
    [[ "$new" == 0 && -s "$state/session" ]] && session="$(cat "$state/session")"
    stamp="$(date +%Y%m%d-%H%M%S)"
    log="$state/$stamp.jsonl"
    result="$state/$stamp.result.md"

    local args=() flag
    while IFS= read -r flag; do args+=("$flag"); done < <(sandbox_flags "$worktree" "$access" "$network")
    while IFS= read -r flag; do
        args+=(-c "shell_environment_policy.set.${flag%%=*}=\"${flag#*=}\"")
    done < <(sandbox_env "$worktree")
    args+=(-c 'shell_environment_policy.inherit="core"'
        -c 'approval_policy="never"'
        -c "web_search=\"$web\""
        -c "model_reasoning_effort=\"$effort\""
        -m "$model" --ignore-user-config --ignore-rules --json -o "$result")
    # Everything Codex could reach beyond the shell and the worktree.
    for flag in apps plugins remote_plugin plugin_discovery_prefetch tool_suggest \
        skill_mcp_dependency_install browser_use browser_use_external in_app_browser \
        computer_use image_generation multi_agent hooks; do
        args+=(--disable "$flag")
    done

    if [[ -n "$session" ]]; then
        prompt="$(cat "$prompt_file")"
    else
        prompt="$(preamble; cat "$prompt_file")"
    fi

    cd "$worktree"
    if [[ -n "$session" ]]; then
        "$bin" exec resume "${args[@]}" "$session" "$prompt" </dev/null >"$log" 2>"$log.stderr" &
    else
        "$bin" exec "${args[@]}" "$prompt" </dev/null >"$log" 2>"$log.stderr" &
    fi
    local pid=$! code=0 quiet
    trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
    echo "Codex running on $branch: pid $pid, log $log"

    # A run that writes no event for this long is stuck, not slow.
    while kill -0 "$pid" 2>/dev/null; do
        sleep 20
        quiet=$(( $(date +%s) - $(stat -f %m "$log") ))
        if (( quiet > stall * 60 )); then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            trap - EXIT INT TERM
            echo "Codex stalled: no output for $stall minutes. Log: $log" >&2
            return 124
        fi
    done
    wait "$pid" || code=$?
    trap - EXIT INT TERM

    line="$(grep -m1 '"thread.started"' "$log" || true)"
    if [[ -n "$line" ]]; then
        python3 -c 'import json,sys; print(json.loads(sys.argv[1])["thread_id"])' "$line" > "$state/session"
    fi
    python3 - "$log" <<'SUMMARY' || true
import json, sys
usage = None
for raw in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(raw)
    except ValueError:
        continue
    if event.get("type") == "turn.completed":
        usage = event.get("usage")
print("tokens:", json.dumps(usage) if usage else "no completed turn")
SUMMARY

    if [[ "$code" != 0 ]] && tail -c 4000 "$log" "$log.stderr" 2>/dev/null \
        | grep -qiE 'usage_limit_reached|usage limit|rate_limit_exceeded'; then
        echo "Codex hit its usage limit. Run wait-limit, then run again to resume." >&2
        cmd_limits >&2 || true
        return 75
    fi
    if [[ "$code" != 0 ]]; then
        echo "Codex failed with exit code $code. Log: $log" >&2
        tail -c 1500 "$log.stderr" >&2 || true
        return "$code"
    fi
    echo "Result: $result"
    cat "$result"
}

cmd_sandbox() {
    local branch="${1:?branch required}"
    shift
    [[ "${1:-}" == "--" ]] && shift
    require_worktree "$branch"
    local worktree args=() flag vars=()
    worktree="$(worktree_of "$branch")"
    while IFS= read -r flag; do args+=("$flag"); done < <(sandbox_flags "$worktree" write false)
    while IFS= read -r flag; do vars+=("$flag"); done < <(sandbox_env "$worktree")
    cd "$worktree"
    "$(codex_bin)" sandbox "${args[@]}" -- /usr/bin/env "${vars[@]}" "$@"
}

# Refuses when the worktree changed a guarded path, since these checks would
# otherwise trust a copy that the changes under review could have altered.
check_guards() {
    local worktree="$1" base path
    base="$(git -C "$worktree" merge-base HEAD origin/main)"
    for path in "${guarded_paths[@]}"; do
        [[ "$path" == .git ]] && continue
        if [[ -n "$(git -C "$worktree" status --porcelain -- "$path")" ]] \
            || ! git -C "$worktree" diff --quiet "$base" HEAD -- "$path"; then
            die "guarded path changed in $worktree: $path. Review it by hand."
        fi
    done
}

cmd_verify() {
    local branch="${1:?branch required}" mode="${2:-}" worktree
    require_worktree "$branch"
    worktree="$(worktree_of "$branch")"
    case "$mode" in ""|--app|--host) ;; *) die "unknown verify option $mode" ;; esac
    check_guards "$worktree"

    echo "── privacy (installed checker)"
    ( cd "$worktree" && "$(installed_privacy)" )
    if [[ "$mode" == --host ]]; then
        # Runs the branch's code with full access to this account: review the
        # diff before using it.
        ( cd "$worktree" && make check && make app )
    else
        cmd_sandbox "$branch" -- scripts/codex-swift.sh build --build-tests
        cmd_sandbox "$branch" -- scripts/codex-swift.sh test --skip-build
        # xcodebuild can't load its plug-ins in the sandbox. This compiles the
        # branch on the host, so read changes to project.yml and Package.swift first.
        if [[ "$mode" == --app ]]; then ( cd "$worktree" && make app ); fi
    fi
    echo "✓ verified $branch ${mode:-in the sandbox}"
}

cmd_commit() {
    local branch="${1:?branch required}" message="${2:?message file required}" worktree
    require_worktree "$branch"
    worktree="$(worktree_of "$branch")"
    [[ -f "$message" ]] || die "no message file $message"
    check_guards "$worktree"
    ( cd "$worktree"
      git add -A
      git diff --cached --quiet && die "nothing to commit on $branch"
      "$(installed_privacy)" --staged
      git commit -q -F "$message"
      git log -1 --stat --format='%h %s' )
}

cmd_status() {
    local dir name worktree last
    git -C "$self_dir" worktree list | grep -F "$worktree_root" || echo "No Codex worktrees."
    [[ -d "$state_root" ]] || return 0
    for dir in "$state_root"/*/; do
        [[ -d "$dir" ]] || continue
        name="$(basename "$dir")"
        worktree="$worktree_root/$name"
        last="$(ls -t "$dir"*.result.md 2>/dev/null | head -1 || true)"
        echo "$name: session $(cat "$dir/session" 2>/dev/null || echo none), last result ${last:-none}"
        [[ -d "$worktree" ]] && git -C "$worktree" status --short | head -20
    done
    return 0
}

cmd_remove() {
    local branch="${1:?branch required}" worktree
    worktree="$(worktree_of "$branch")"
    [[ -z "$(git -C "$worktree" status --porcelain)" ]] || die "$worktree has uncommitted changes"
    git -C "$self_dir" worktree remove --force "$worktree"
    echo "Removed $worktree; branch $branch kept."
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    limits) cmd_limits "$@" ;;
    wait-limit) cmd_wait_limit "$@" ;;
    prepare) cmd_prepare "$@" ;;
    sync) cmd_sync "$@" ;;
    run) cmd_run "$@" ;;
    sandbox) cmd_sandbox "$@" ;;
    verify) cmd_verify "$@" ;;
    commit) cmd_commit "$@" ;;
    status) cmd_status ;;
    remove) cmd_remove "$@" ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
