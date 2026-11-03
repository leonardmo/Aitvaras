#!/usr/bin/env bash
# Applies the repository settings this project expects (idempotent).
# Maintainer-only: needs admin rights on the repository.
#
#   scripts/configure-github.sh [owner/repo]   # default: leonardmo/Aitvaras
set -euo pipefail
REPO="${1:-leonardmo/Aitvaras}"

echo "── Merge settings: squash/rebase only, auto-merge, delete merged branches"
gh repo edit "$REPO" \
    --description "Local-first agentic AI assistant for macOS with a 3D companion and DE/EN voice" \
    --add-topic macos --add-topic swift --add-topic swiftui --add-topic mlx \
    --add-topic local-llm --add-topic ai-assistant \
    --enable-merge-commit=false --enable-squash-merge --enable-rebase-merge \
    --enable-auto-merge --delete-branch-on-merge \
    --enable-wiki=false

echo "── Security: secret scanning, push protection, Dependabot alerts and fixes"
gh api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON'
{"security_and_analysis": {
  "secret_scanning": {"status": "enabled"},
  "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null

echo "── Ruleset for main: PR + green CI, no force-push or deletion (admins may bypass)"
RULESET=$(cat <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["squash", "rebase"]}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [
        {"context": "Privacy & commit hygiene"},
        {"context": "Package tests"},
        {"context": "App build"}]}}
  ]
}
JSON
)
EXISTING=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "main") | .id')
if [[ -n "$EXISTING" ]]; then
    gh api -X PUT "repos/$REPO/rulesets/$EXISTING" --input - <<<"$RULESET" >/dev/null
else
    gh api -X POST "repos/$REPO/rulesets" --input - <<<"$RULESET" >/dev/null
fi

echo "── Labels for claiming work"
label() { gh label create "$1" -R "$REPO" --color "$2" --description "$3" --force >/dev/null; }
label "agent:claude" "d97757" "Claimed by a Claude Code session"
label "agent:codex"  "10a37f" "Claimed by a Codex session"
label "task"         "0e8a16" "A unit of work"
label "bug"          "d73a4a" "Something behaves wrongly"
label "dependencies" "0366d6" "Dependency updates"

echo "✓ $REPO configured"
