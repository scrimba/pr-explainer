#!/usr/bin/env bash
set -euo pipefail

# Generate a Scrimba PR explainer for a local branch, no GitHub involved.
# The branch checked out in the target repo is treated as the PR head; PR
# metadata is synthesized from git. No PR comment is posted — the explainer
# URL is printed as soon as the stream starts.

usage() {
  cat <<'USAGE'
Usage: scripts/run-local.sh --mcp-url <url> [path-to-repo] [--base <ref>]

Treats the currently checked-out branch of the target repo (default: the
current directory) as a PR and generates a Scrimba explainer for it, using
the exact same prompts and agent invocation as the GitHub Action.

Options:
  --mcp-url <url>   Required. Scrimba MCP server to stream to, e.g.
                    http://localhost:3000/explain/mcp for a locally running
                    Scrimba, or https://scrimba.com/explain/mcp to
                    deliberately create a real (unlisted) explainer on
                    production.
  --base <ref>      Base to diff against. Defaults to origin's default
                    branch when known, else main, else master.

Environment:
  SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN
                 Claude token to use. When unset, your local Claude Code
                 login is used.

Artifacts (prompts, agent streams, diff) land in .scrimba-pr-explainer/
inside the target repo.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_PATH="."
BASE_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE_REF="${2:?--base needs a ref}"
      shift 2
      ;;
    --mcp-url)
      export SCRIMBA_PR_EXPLAINER_MCP_URL="${2:?--mcp-url needs a URL}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      REPO_PATH="$1"
      shift
      ;;
  esac
done

if [ -z "${SCRIMBA_PR_EXPLAINER_MCP_URL:-}" ]; then
  echo "Missing --mcp-url. Local runs must say where to stream the explainer," >&2
  echo "e.g. --mcp-url http://localhost:3000/explain/mcp for a locally running Scrimba." >&2
  exit 1
fi

cd "$REPO_PATH"
git rev-parse --is-inside-work-tree >/dev/null

# shellcheck source=scripts/run-action.sh
source "$SCRIPT_DIR/run-action.sh"

require_cmd git
require_cmd jq
require_cmd claude

HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git rev-parse HEAD)"

if [ -z "$BASE_REF" ]; then
  if BASE_REF="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    :
  elif git rev-parse --verify --quiet main >/dev/null; then
    BASE_REF="main"
  elif git rev-parse --verify --quiet master >/dev/null; then
    BASE_REF="master"
  else
    echo "Could not detect a base branch. Pass one with --base." >&2
    exit 1
  fi
fi

BASE_SHA="$(git merge-base "$BASE_REF" HEAD)"
if [ "$BASE_SHA" = "$HEAD_SHA" ]; then
  echo "Branch $HEAD_BRANCH has no commits beyond $BASE_REF. Check out the branch you want explained." >&2
  exit 1
fi

log_status "Explaining local branch $HEAD_BRANCH against $BASE_REF ($(git rev-list --count "$BASE_SHA..HEAD") commits)"

mkdir -p "$WORK_DIR"
git diff --no-color "$BASE_SHA..HEAD" > "$WORK_DIR/pr.diff"
git diff --numstat "$BASE_SHA..HEAD" | awk '{printf "- %s (+%s/-%s)\n", $3, $1, $2}' > "$WORK_DIR/diffstat.txt"
: > "$WORK_DIR/linked-issues.md"

TITLE="$(git log --reverse --format=%s "$BASE_SHA..HEAD" | head -n 1)"
TITLE="${TITLE:-$HEAD_BRANCH}"
AUTHOR="$(git log -1 --format=%an)"
BODY="$(git log --format='%s%n%n%b' "$BASE_SHA..HEAD")"

PR_NUMBER=0
jq -n \
  --arg title "$TITLE" \
  --arg author "$AUTHOR" \
  --arg body "$BODY" \
  --arg baseRefName "$BASE_REF" \
  --arg baseRefOid "$BASE_SHA" \
  --arg headRefName "$HEAD_BRANCH" \
  --arg headRefOid "$HEAD_SHA" \
  '{number: 0, title: $title, url: "(local run)", author: {login: $author}, body: $body,
    baseRefName: $baseRefName, baseRefOid: $baseRefOid, headRefName: $headRefName, headRefOid: $headRefOid}' \
  > "$WORK_DIR/pr.json"

RESOLVED_AGENTS=(claude)
RESOLVED_AGENTS_CSV="claude"

prepare_mcp_config
prepare_prompts
write_stream_formatters

(
  dir="$AGENTS_DIR/claude"
  while [ ! -s "$dir/live-guide-url.txt" ]; do sleep 1; done
  log_status "Live explainer URL: $(cat "$dir/live-guide-url.txt")"
) &
URL_WATCHER_PID="$!"

set +e
run_agent claude
set -e

kill "$URL_WATCHER_PID" 2>/dev/null || true
wait "$URL_WATCHER_PID" 2>/dev/null || true

AGENT_DIR="$AGENTS_DIR/claude"
STATUS="$(cat "$AGENT_DIR/status.txt" 2>/dev/null || echo "Unknown")"
log_status "Final status: $STATUS"
if [ -s "$AGENT_DIR/skip-reason.txt" ]; then
  log_status "Skip reason: $(cat "$AGENT_DIR/skip-reason.txt")"
fi
if [ -s "$AGENT_DIR/url.txt" ]; then
  log_status "Explainer URL: $(cat "$AGENT_DIR/url.txt")"
fi
log_status "Artifacts are in $(pwd)/$WORK_DIR"

[ "$STATUS" = "Done" ] || [ "$STATUS" = "Skipped" ]
