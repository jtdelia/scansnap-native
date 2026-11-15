#!/usr/bin/env bash
# One-time setup for a repository created from this template. GitHub copies files
# from a template but not labels, branch rules, or settings, so this applies them.
#
# Usage: scripts/setup-repo.sh [owner/repo]   (defaults to the current directory's repo)
# Requires the GitHub CLI (gh), logged in with admin access to the repository.
# Safe to run more than once.

set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
echo "Setting up $repo"

step() { printf '\n==> %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

step "Labels"
while IFS='|' read -r name color description; do
  gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force
done <<'EOF'
type:bug|d73a4a|Something is broken
type:feature|a2eeef|New behavior
type:plan|5319e7|A larger goal split into build tasks
type:task|0e8a16|An atomic build task
needs-triage|fbca04|Waiting for a maintainer to accept it
needs-info|d876e3|Waiting on reporter for more information
ready-for-agent|0e8a16|Fully specified, ready for an AFK agent
ready-for-human|c5def5|Requires human implementation
agent-ready|1d76db|Ready for the agent to implement
blocked|b60205|Waiting on other work
EOF

step "Merge settings: squash only, pull request title as the commit message"
gh api --silent -X PATCH "repos/$repo" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

step "Actions: read-only token by default"
gh api --silent -X PUT "repos/$repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

step "Private vulnerability reporting"
gh api --silent -X PUT "repos/$repo/private-vulnerability-reporting" 2>/dev/null \
  || warn "could not enable it (GitHub only offers this on public repositories)"

# Creates the named ruleset from JSON on stdin, or replaces it if it already exists.
apply_ruleset() {
  local name="$1" existing method path
  existing=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    method=PUT path="repos/$repo/rulesets/$existing"
  else
    method=POST path="repos/$repo/rulesets"
  fi
  gh api --silent -X "$method" "$path" --input - 2>/dev/null
}
admin_bypass='[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]'

# The agent app can push branches and open pull requests, so a pull request needs one
# approval, given after its last push, before it can merge. Admins can still bypass.
step "Protect the default branch"
branch=$(gh api "repos/$repo" --jq .default_branch)
if apply_ruleset "protect-$branch" <<EOF
{
  "name": "protect-$branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": $admin_bypass,
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [{"context": "ci-success"}]
    }}
  ]
}
EOF
then
  echo "Pull requests need one approval and the ci-success check on $branch. Admins can bypass."
else
  warn "could not create the branch ruleset. Private repositories need GitHub Pro, Team, or Enterprise for this."
fi

step "Protect tags"
if apply_ruleset protect-tags <<EOF
{
  "name": "protect-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~ALL"], "exclude": []}},
  "bypass_actors": $admin_bypass,
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]
}
EOF
then
  echo "Only admins can create, move, or delete tags, so the agent app cannot publish releases."
else
  warn "could not create the tag ruleset. Private repositories need GitHub Pro, Team, or Enterprise for this."
fi

step "Kiro CLI fallback reviewer (optional)"
echo "When no free OpenCode model works, the AI review falls back to Kiro CLI."
echo "That needs a KIRO_API_KEY from a paid Kiro plan (Pro or higher)."
read -r -p "Set the KIRO_API_KEY secret now? [y/N] " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  gh secret set KIRO_API_KEY --repo "$repo"
fi

open_url() {
  echo "  $1"
  if command -v open >/dev/null; then open "$1"; elif command -v xdg-open >/dev/null; then xdg-open "$1"; fi
}

owner=${repo%%/*}
if [ "$(gh api "users/$owner" --jq .type)" = Organization ]; then
  settings="https://github.com/organizations/$owner/settings"
else
  settings="https://github.com/settings"
fi

# Returns 1 when the check failed, 2 when it could not run. Leaves the run's ID in run_id.
verify_agent_app() {
  local out before
  latest_run() {
    gh run list --repo "$repo" --workflow setup-check.yml --event workflow_dispatch \
      --limit 1 --json databaseId --jq '.[0].databaseId // 0'
  }
  before=$(latest_run 2>/dev/null || echo 0)
  out=$(gh workflow run setup-check.yml --repo "$repo" 2>&1) || { warn "could not start the setup check: $out"; return 2; }
  run_id=$(printf '%s' "$out" | grep -oE 'runs/[0-9]+' | cut -d/ -f2 || true)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$run_id" ] && break
    sleep 3
    run_id=$(latest_run)
    if [ "$run_id" -le "$before" ]; then run_id=""; fi
  done
  [ -n "$run_id" ] || { warn "could not find the setup check run"; return 2; }
  echo "Checking with the Setup check workflow (about 30 seconds)..."
  gh run watch "$run_id" --repo "$repo" --exit-status >/dev/null 2>&1 || return 1
}

step "Agent GitHub app"
cat <<EOF
/oc comments and agent-ready tasks push branches and open pull requests as a GitHub app you
own, so CI runs on them. The app can only change code, issues, and pull requests, and only
on repositories you install it on. One app can serve every repository made from this
template. The AI review works without it.
EOF
skip_app=false
read -r -p "Create a new agent app? Answer n to reuse one you made before, or s to skip. [Y/n/s] " answer
case "$answer" in
  [Ss]*) skip_app=true ;;
  [Nn]*) ;;
  *)
    cat <<EOF
Create it with this pre-filled form. Change the name if GitHub says it is taken, and keep
the permissions as they are: Contents, Issues, and Pull requests, read and write.
EOF
    open_url "$settings/apps/new?name=$owner-agent&url=https://github.com/$repo&public=false&webhook_active=false&contents=write&issues=write&pull_requests=write"
    echo "Then, on the app's page, click \"Generate a private key\". Your browser downloads a .pem file."
    read -r -p "Press Enter when you have the key file. " _
    ;;
esac

if [ "$skip_app" = true ]; then
  warn "skipped. /oc comments and agent-ready tasks will fail until the agent app is set up."
else
  read -r -p "The app's Client ID, from its settings page: " client_id
  gh variable set AGENT_APP_CLIENT_ID --repo "$repo" --body "$client_id"
  while true; do
    read -r -p "Path to the app's private key (.pem): " key_path
    key_path="${key_path/#\~/$HOME}"
    [ -f "$key_path" ] && break
    echo "No file at $key_path."
  done
  gh secret set AGENT_APP_PRIVATE_KEY --repo "$repo" < "$key_path"
  echo "Stored. Keep the key file somewhere safe if other repositories will use this app, or delete it."

  read -r -p "The app's name as it appears in its URL, github.com/apps/<name>: " slug
  echo "Install it on $repo. Choose \"Only select repositories\" and pick this one:"
  open_url "https://github.com/apps/$slug/installations/new"
  while true; do
    read -r -p "Press Enter once it is installed, or type 'skip': " answer
    if [ "$answer" = "skip" ]; then
      warn "skipped. Run the Setup check workflow from the Actions tab once the app is installed."
      break
    fi
    status=0
    verify_agent_app || status=$?
    case "$status" in
      0) echo "The agent app is installed and has only the permissions it needs."; break ;;
      1) cat <<EOF
The check failed. Make sure $repo is selected in the app's installation, the client ID and
key belong to the same app, and the app has no permissions beyond Contents, Issues, and Pull
requests. See why with: gh run view $run_id --repo $repo --log-failed
EOF
        ;;
      *) warn "run the Setup check workflow from the Actions tab once Actions is enabled."; break ;;
    esac
  done
fi

step "Remove the opencode-agent app"
cat <<EOF
Earlier versions of this template used the opencode-agent app, which can also change
workflows and secrets. If it is installed, uninstall it or remove this repository from it:

  $settings/installations
EOF
