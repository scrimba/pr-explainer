#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=".scrimba-pr-explainer"
AGENTS_DIR="$WORK_DIR/agents"
DEFAULT_MCP_URL="https://scrimba.com/explain/mcp"
EXPLAINER_URL_REGEX='https://[A-Za-z0-9._:-]+/explain/[A-Za-z0-9_-]+(\?claim=[A-Za-z0-9_-]+)?'

log_status() {
  printf '[scrimba-pr-explainer] %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "::error::Missing required command: $1"
    exit 1
  fi
}

resolve_agents() {
  local raw_agents
  raw_agents="${SCRIMBA_PR_EXPLAINER_AGENTS:-}"

  if [ -z "$raw_agents" ]; then
    if [ -n "${SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      raw_agents="claude"
    elif [ -n "${SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64:-}" ]; then
      raw_agents="codex"
    else
      raw_agents="claude"
    fi
  fi

  local normalized
  normalized="$(printf '%s' "$raw_agents" | tr '[:upper:]' '[:lower:]' | tr '&; ' ',,,')"
  IFS=',' read -r -a CANDIDATES <<< "$normalized"

  RESOLVED_AGENTS=()
  for candidate in "${CANDIDATES[@]}"; do
    local agent duplicate existing
    agent="$(printf '%s' "$candidate" | xargs)"
    [ -n "$agent" ] || continue

    case "$agent" in
      claude|codex) ;;
      *)
        echo "::error::Unsupported Scrimba PR explainer agent: $agent"
        exit 1
        ;;
    esac

    duplicate=0
    for existing in "${RESOLVED_AGENTS[@]}"; do
      if [ "$existing" = "$agent" ]; then
        duplicate=1
        break
      fi
    done
    [ "$duplicate" = "0" ] && RESOLVED_AGENTS+=("$agent")
  done

  if [ "${#RESOLVED_AGENTS[@]}" -eq 0 ]; then
    echo "::error::No Scrimba PR explainer agents resolved."
    exit 1
  fi

  for agent in "${RESOLVED_AGENTS[@]}"; do
    if [ "$agent" = "claude" ] && [ -z "${SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      echo "::error::Missing SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN secret for Claude."
      exit 1
    fi
    if [ "$agent" = "codex" ] && [ -z "${SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64:-}" ]; then
      echo "::error::Missing SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 secret for Codex."
      exit 1
    fi
  done

  RESOLVED_AGENTS_CSV="$(IFS=,; echo "${RESOLVED_AGENTS[*]}")"
  log_status "Using agents: $RESOLVED_AGENTS_CSV"
}

resolve_pr_context() {
  mkdir -p "$WORK_DIR"

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
    PR_NUMBER="$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")"
  elif [ -n "${SCRIMBA_PR_EXPLAINER_PR_NUMBER:-}" ]; then
    PR_NUMBER="$SCRIMBA_PR_EXPLAINER_PR_NUMBER"
  else
    PR_NUMBER="$(gh pr view --json number --jq .number)"
  fi

  gh pr view "$PR_NUMBER" \
    --json number,title,body,url,baseRefName,baseRefOid,headRefName,headRefOid,author,files,isCrossRepository \
    > "$WORK_DIR/pr.json"

  BASE_SHA="$(jq -r .baseRefOid "$WORK_DIR/pr.json")"
  HEAD_SHA="$(jq -r .headRefOid "$WORK_DIR/pr.json")"
  IS_CROSS_REPOSITORY="$(jq -r .isCrossRepository "$WORK_DIR/pr.json")"

  jq -r '.files[] | "- \(.path) (+\(.additions)/-\(.deletions))"' "$WORK_DIR/pr.json" > "$WORK_DIR/diffstat.txt"
  gh pr diff "$PR_NUMBER" --patch --color never > "$WORK_DIR/pr.diff"

  log_status "Explaining PR #$PR_NUMBER at $HEAD_SHA"
}

enforce_fork_policy() {
  if [ "${IS_CROSS_REPOSITORY:-false}" = "true" ] && [ "${SCRIMBA_PR_EXPLAINER_ALLOW_FORKS:-}" != "true" ]; then
    echo "::error::PR #$PR_NUMBER is from a fork. Set the allow-forks action input to true only if you trust fork PR content not to prompt-inject the selected agent."
    exit 1
  fi
}

prepare_mcp_config() {
  MCP_URL="${SCRIMBA_PR_EXPLAINER_MCP_URL:-$DEFAULT_MCP_URL}"
  [ -n "$MCP_URL" ] || MCP_URL="$DEFAULT_MCP_URL"
  CODEX_HOME_DIR="${RUNNER_TEMP:-$WORK_DIR}/scrimba-pr-explainer-codex-home"

  echo "$MCP_URL" > "$WORK_DIR/mcp-url.txt"
  log_status "Using Scrimba MCP URL: $MCP_URL"

  cat > "$WORK_DIR/claude.mcp.json" <<EOF
{
  "mcpServers": {
    "scrimba": {
      "type": "http",
      "url": "$MCP_URL"
    }
  }
}
EOF

  mkdir -p "$CODEX_HOME_DIR"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
cli_auth_credentials_store = "file"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[mcp_servers.scrimba]
command = "npx"
args = ["-y", "mcp-remote@0.1.38", "$MCP_URL"]
required = true
startup_timeout_sec = 120
enabled_tools = [
  "start_explainer_stream",
  "append_explainer_chunk",
  "finish_explainer_stream"
]
default_tools_approval_mode = "approve"
tool_timeout_sec = 300
EOF
}

prepare_prompts() {
  mkdir -p "$AGENTS_DIR"

  cat > "$WORK_DIR/prompt.base.md" <<'EOF'
You are creating a Scrimba PR Explainer: a short, narrated, visual walkthrough that teaches a human what this PR does and why it matters.

Voice and teaching style — this defines the whole explainer:
- Explain like a great teacher talking to a smart colleague who has not followed this work — not like a senior dev writing a review. Plain human language; any technical term you cannot avoid gets one short clause saying what it means.
- Lead with the story: the problem that existed, what changes, and what a user or developer actually experiences after the merge. Motivation before mechanism, always.
- Make every idea something the viewer can SEE. One clear idea per slide. Use generated images (`<item type="image">`) to set scenes and land metaphors, diagrams for flows and architecture, and code snippets only where the exact code is the point — short and anchored.
- Analogies beat abstractions: when a mechanism has an everyday equivalent (a queue at a counter, a claim ticket, a thermostat, a relay race handoff), teach through it.
- Never stack jargon. If a sentence needs three technical terms to parse, rewrite it as what actually happens in the running system.

You are running inside a checkout of the repository at the PR merge commit. Use local file, git, gh, rg commands, web search, and GitHub resources as needed to understand the PR.

Do not rely only on the metadata in this prompt. Inspect the codebase, diff, existing usage, and nearby tests before deciding what to generate.

First decide whether this PR is worth a Scrimba explainer.

Skip explainer creation when the PR is too small or too mechanical to justify a narrated walkthrough, such as:
- a one-line copy or UX text change
- a tiny config value change
- a trivial typo, formatting-only change, or metadata-only change
- a change with no meaningful behavior, flow, boundary, or review risk to explain

Do not skip when the PR changes behavior, security, data flow, public API, CI/deploy behavior, billing/accounting, persistence, permissions, or multiple connected files.

If you skip, do not call the Scrimba MCP tools. End your final response with exactly:
SCRIMBA_PR_EXPLAINER_SKIP_REASON=<one short sentence>

If the PR is worth an explainer, use the Scrimba Explain MCP server to create it.

Immediately after the Scrimba MCP server gives you the link to the explainer, write the URL to this file:
{{LIVE_GUIDE_URL_FILE}}

Write exactly one URL into that file: the URL with the claim query parameter, not the plain explainer URL. Do this as soon as the URL is available so the GitHub PR comment can show the live guide while it is still generating.

Do not modify repository files, stage changes, commit, reset, clean, format, update snapshots, or mutate project state. If creating a guide, the only local file you may write is {{LIVE_GUIDE_URL_FILE}}.

Build the guide as three top-level sections:

1. What
- This must be the first generated content section.
- Open with the human story: the problem or wish that existed, and what life looks like after this PR merges. Make the viewer picture the before and the after — an image or metaphor slide works well here.
- Make the reviewer understand the purpose before any implementation details.

2. How
- Narrate the changed flows as journeys ("the request lands here, gets its ticket, then hands off to…"), and draw them as diagrams rather than listing files.
- Explain important boundary changes: which layer/module owns the responsibility now — and why that is the natural home for it.
- Explain important coupling only when it helps reviewers understand what must change together.
- Keep this proportional to the PR. Small PRs get a short explanation; larger connected changes get a deeper walkthrough.

3. Detected issues
- Include only verified issues or verified architectural concerns.
- Explain each issue as a short story of what goes wrong for whom ("a viewer presses play and hears nothing, because…"), not as a terse review nit.
- Use severity labels: P0, P1, P2, P3.
- P0: severe correctness, safety, data loss, security, or production danger.
- P1: likely user-visible regression, broken flow, security problem, or serious operational risk.
- P2: meaningful maintainability, test coverage, consistency, scalability, or edge-case risk.
- P3: small but real issue worth reviewer attention.
- If there are no verified issues, say that clearly.

Verification discipline:
- Trace real execution flows, not hypothetical flows that cannot happen.
- Search for existing usage and existing handling paths.
- Check nearby tests and whether they cover changed behavior.
- Run targeted read-only checks when feasible.
- If behavior depends on an external API, library, provider, or current standard, verify it with docs or research.
- Try to disprove concerns before presenting them. If the code already handles a concern, omit it.
- Do not report vague "add tests" feedback. Only mention missing tests when a risky behavior changed and a specific test would catch a regression.

Do not turn this into a markdown code review. Create a Scrimba explainer with narration and visual structure. Use code snippets, file anchors, diagrams, or short lists when they make the explainer clearer.

After finishing a guide, end your final response with exactly:
SCRIMBA_PR_EXPLAINER_URL=<url>

Pull request metadata:
EOF

  cat "$WORK_DIR/pr.json" >> "$WORK_DIR/prompt.base.md"
  {
    echo
    echo "Diffstat:"
    cat "$WORK_DIR/diffstat.txt"
  } >> "$WORK_DIR/prompt.base.md"

  for agent in "${RESOLVED_AGENTS[@]}"; do
    local dir="$AGENTS_DIR/$agent"
    mkdir -p "$dir"
    sed "s#{{LIVE_GUIDE_URL_FILE}}#$dir/live-guide-url.txt#g" "$WORK_DIR/prompt.base.md" > "$dir/prompt.md"
    echo "Queued" > "$dir/status.txt"
    : > "$dir/url.txt"
    : > "$dir/skip-reason.txt"

    echo "::group::Agent prompt ($agent)"
    cat "$dir/prompt.md"
    echo "::endgroup::"
  done
}

write_comment_helpers() {
  cat > "$WORK_DIR/render-comment.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

cell() {
  printf '%s' "$1" | tr '\n|' ' /'
}

echo "<!-- scrimba-pr-explainer -->"
echo "### Scrimba PR Explainers"
echo
echo "Generated for commit \`$SCRIMBA_PR_EXPLAINER_HEAD_SHA\`."
echo
echo "| Agent | Status | Explainer |"
echo "|---|---|---|"

IFS=',' read -r -a AGENTS <<< "$SCRIMBA_PR_EXPLAINER_AGENTS"
for agent in "${AGENTS[@]}"; do
  dir=".scrimba-pr-explainer/agents/$agent"
  status="$(cat "$dir/status.txt" 2>/dev/null || echo "Queued")"
  url="$(grep -Eom 1 'https://[A-Za-z0-9._:-]+/explain/[A-Za-z0-9_-]+(\?claim=[A-Za-z0-9_-]+)?' "$dir/url.txt" 2>/dev/null || true)"
  if [ -z "$url" ] && [ -s "$dir/live-guide-url.txt" ]; then
    url="$(grep -Eom 1 'https://[A-Za-z0-9._:-]+/explain/[A-Za-z0-9_-]+(\?claim=[A-Za-z0-9_-]+)?' "$dir/live-guide-url.txt" 2>/dev/null || true)"
  fi
  skip_reason="$(cat "$dir/skip-reason.txt" 2>/dev/null || true)"

  if [ -n "$url" ]; then
    explainer="[Open explainer]($url)"
  elif [ -n "$skip_reason" ]; then
    explainer="Skipped: $(cell "$skip_reason")"
  elif [ "$status" = "Failed" ]; then
    explainer="Check workflow logs"
  else
    explainer="Waiting for link..."
  fi

  echo "| \`$(cell "$agent")\` | $(cell "$status") | $explainer |"
done

echo
echo "This comment is updated on every PR push, and again as each selected agent starts, posts a live URL, skips, or finishes."
SCRIPT
  chmod +x "$WORK_DIR/render-comment.sh"

  cat > "$WORK_DIR/post-comment.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
MARKER="<!-- scrimba-pr-explainer -->"

COMMENT_ID="$(gh api "repos/$GITHUB_REPOSITORY/issues/$SCRIMBA_PR_EXPLAINER_PR_NUMBER/comments" \
  --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" 2>/dev/null | tail -n 1 || true)"

if [ -n "$COMMENT_ID" ]; then
  if ! jq -n --rawfile body .scrimba-pr-explainer/comment.md '{body:$body}' \
    | gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$COMMENT_ID" --input - >/dev/null; then
    echo "::warning::Could not update the Scrimba PR explainer comment."
  fi
else
  if ! jq -n --rawfile body .scrimba-pr-explainer/comment.md '{body:$body}' \
    | gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$SCRIMBA_PR_EXPLAINER_PR_NUMBER/comments" --input - >/dev/null; then
    echo "::warning::Could not create the Scrimba PR explainer comment."
  fi
fi
SCRIPT
  chmod +x "$WORK_DIR/post-comment.sh"
}

render_and_post_comment() {
  SCRIMBA_PR_EXPLAINER_AGENTS="$RESOLVED_AGENTS_CSV" \
  SCRIMBA_PR_EXPLAINER_HEAD_SHA="$HEAD_SHA" \
    "$WORK_DIR/render-comment.sh" > "$WORK_DIR/comment.md"

  SCRIMBA_PR_EXPLAINER_PR_NUMBER="$PR_NUMBER" \
    "$WORK_DIR/post-comment.sh"
}

install_agent_clis() {
  for agent in "${RESOLVED_AGENTS[@]}"; do
    case "$agent" in
      claude)
        if ! command -v claude >/dev/null 2>&1; then
          npm install -g @anthropic-ai/claude-code@latest
        fi
        ;;
      codex)
        if ! command -v codex >/dev/null 2>&1; then
          npm install -g @openai/codex@latest
        fi
        ;;
    esac
  done
}

write_stream_formatters() {
  cat > "$WORK_DIR/format-claude-stream.jq" <<'JQ'
def lines($prefix; $s):
  ($s // "" | tostring | gsub("\r"; "") | split("\n") | map(select(length > 0)) | .[:40][] | $prefix + .);

def oneline($s; $max):
  ($s // "" | tostring | gsub("[\r\n\t]+"; " ") | if length > $max then .[:$max] + "..." else . end);

def tool_summary:
  if .name == "append_explainer_chunk" then
    "[tool call] append_explainer_chunk (" + ((.input.opml // "" | tostring | length) | tostring) + " OPML chars)"
  elif .name == "start_explainer_stream" or .name == "start_guide_stream" then
    "[tool call] " + .name + " title=" + ((.input.title // "untitled") | tostring)
  elif .name == "finish_explainer_stream" or .name == "finish_guide_stream" then
    "[tool call] " + .name
  elif .name == "Write" then
    "[tool call] Write " + ((.input.file_path // .input.path // "file") | tostring)
  elif .name == "Bash" then
    "[tool call] Bash: " + oneline(.input.command; 300)
  elif .name == "Read" then
    "[tool call] Read " + ((.input.file_path // "") | tostring)
  elif .name == "WebSearch" then
    "[tool call] WebSearch: " + oneline(.input.query; 200)
  elif .name == "WebFetch" then
    "[tool call] WebFetch " + ((.input.url // "") | tostring)
  else
    "[tool call] " + (.name // "unknown") + " " + oneline(.input | tojson; 200)
  end;

if .type == "system" and .subtype == "thinking_tokens" then
  "[thinking tokens] " + ((.estimated_tokens // 0) | tostring) + " (+" + ((.estimated_tokens_delta // 0) | tostring) + ")"
elif .type == "assistant" then
  .message.content[]? |
    if .type == "thinking" then
      lines("[thinking] "; .thinking)
    elif .type == "tool_use" then
      tool_summary
    elif .type == "text" then
      lines("[assistant] "; .text)
    else
      empty
    end
elif .type == "user" and (.tool_use_result? != null) then
  if (.tool_use_result.is_error? // false) == true then
    lines("[tool error] "; ((.tool_use_result.stderr? // .tool_use_result.stdout? // "") | tostring))
  else
    "[tool result] " + oneline(.tool_use_result.stdout? // .tool_use_result.content? // "ok"; 200)
  end
elif .type == "rate_limit_event" then
  "[rate limit] " + (.rate_limit_info.status // "unknown")
elif .type == "result" then
  "[result] " + (.subtype // "done") + " duration=" + (((.duration_ms // 0) / 1000) | tostring) + "s turns=" + ((.num_turns // 0) | tostring)
else
  empty
end
JQ

  cat > "$WORK_DIR/format-codex-stream.jq" <<'JQ'
def lines($prefix; $s):
  ($s // "" | tostring | gsub("\r"; "") | split("\n") | map(select(length > 0)) | .[:40][] | $prefix + .);

def item_summary($item):
  if $item.type == "agent_message" then
    lines("[assistant] "; $item.text)
  elif $item.type == "reasoning" then
    lines("[reasoning] "; ($item.text // $item.summary // $item.content // ""))
  elif $item.type == "command_execution" then
    "[cmd " + (($item.status // "event") | tostring) + "] " + (($item.command // "") | tostring)
  elif $item.type == "mcp_tool_call" then
    "[mcp " + (($item.status // "event") | tostring) + "] " + (($item.server // "mcp") | tostring) + "." + (($item.tool // $item.name // "tool") | tostring)
  elif $item.type == "web_search" then
    "[web search] " + (($item.query // $item.status // "event") | tostring)
  elif $item.type == "file_change" then
    "[file change] " + (($item.path // $item.status // "event") | tostring)
  elif $item.type == "plan_update" then
    "[plan] " + (($item.status // "updated") | tostring)
  else
    "[item " + (($item.type // "unknown") | tostring) + "] " + (($item.status // "event") | tostring)
  end;

fromjson? |
  if . == null then
    empty
  elif .type == "thread.started" then
    "[thread] " + (.thread_id // "started")
  elif .type == "turn.started" then
    "[turn] started"
  elif .type == "turn.completed" then
    "[result] success input=" + ((.usage.input_tokens // 0) | tostring) + " output=" + ((.usage.output_tokens // 0) | tostring) + " reasoning=" + ((.usage.reasoning_output_tokens // 0) | tostring)
  elif .type == "turn.failed" then
    "[result] failed"
  elif .type == "error" then
    lines("[agent error] "; (.message // .error // "unknown error"))
  elif (.type | startswith("item.")) then
    item_summary(.item)
  else
    empty
  end
JQ
}

update_comment_if_changed() {
  local state="" signature agent dir status url skip
  for agent in "${RESOLVED_AGENTS[@]}"; do
    dir="$AGENTS_DIR/$agent"
    status="$(cat "$dir/status.txt" 2>/dev/null || true)"
    url="$(cat "$dir/url.txt" 2>/dev/null || true)"
    skip="$(cat "$dir/skip-reason.txt" 2>/dev/null || true)"
    state="${state}|${agent}|${status}|${url}|${skip}"
  done

  signature="$(printf '%s' "$state" | sha256sum | awk '{print $1}')"
  if [ "$signature" != "$(cat "$WORK_DIR/comment-signature.txt" 2>/dev/null || true)" ]; then
    printf '%s' "$signature" > "$WORK_DIR/comment-signature.txt"
    render_and_post_comment
  fi
}

watch_agent_progress() {
  for tick in $(seq 1 900); do
    for agent in "${RESOLVED_AGENTS[@]}"; do
      local dir="$AGENTS_DIR/$agent"
      if [ ! -s "$dir/url.txt" ] && [ -s "$dir/live-guide-url.txt" ]; then
        grep -Eom 1 "$EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" > "$dir/url.txt" 2>/dev/null || true
        if [ -s "$dir/url.txt" ]; then
          echo "Generating" > "$dir/status.txt"
          log_status "Live explainer URL detected for $agent; updating PR comment."
        fi
      fi
    done

    update_comment_if_changed

    if [ $((tick % 15)) -eq 0 ]; then
      for agent in "${RESOLVED_AGENTS[@]}"; do
        local dir="$AGENTS_DIR/$agent"
        local output_bytes status
        output_bytes="$(wc -c < "$dir/agent-output.txt" 2>/dev/null | tr -d ' ')"
        output_bytes="${output_bytes:-0}"
        status="$(cat "$dir/status.txt" 2>/dev/null || echo "Queued")"
        log_status "$agent is $status; captured ${output_bytes} bytes of agent output."
      done
    fi

    sleep 2
  done
  echo "::warning::Timed out waiting for explainer progress before the job timeout."
}

extract_agent_result() {
  local agent="$1"
  local dir="$AGENTS_DIR/$agent"
  local skip_reason guide_url

  skip_reason="$(sed -nE 's/^(\[assistant\] )?SCRIMBA_PR_EXPLAINER_SKIP_REASON=//p' "$dir/agent-output.txt" "$dir/agent-final.txt" 2>/dev/null | tail -n 1)"
  if [ -n "$skip_reason" ]; then
    printf '%s\n' "$skip_reason" > "$dir/skip-reason.txt"
  fi

  if [ -s "$dir/live-guide-url.txt" ]; then
    grep -Eom 1 "$EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" > "$dir/url.txt" 2>/dev/null || true
  fi

  guide_url="$(grep -hEo "$EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" "$dir/claude-stream.jsonl" "$dir/codex-stream.jsonl" "$dir/agent-output.txt" "$dir/agent-final.txt" 2>/dev/null | grep '?claim=' | tail -n 1 || true)"
  if [ -z "$guide_url" ]; then
    guide_url="$(grep -hEo "$EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" "$dir/claude-stream.jsonl" "$dir/codex-stream.jsonl" "$dir/agent-output.txt" "$dir/agent-final.txt" 2>/dev/null | tail -n 1 || true)"
  fi
  if [ -n "$guide_url" ]; then
    echo "$guide_url" > "$dir/url.txt"
  fi
}

run_agent() {
  local agent="$1"
  local dir="$AGENTS_DIR/$agent"
  local status=0
  mkdir -p "$dir"
  : > "$dir/agent-output.txt"
  : > "$dir/agent-stderr.txt"
  echo "Generating" > "$dir/status.txt"

  log_status "Starting agent: $agent"

  case "$agent" in
    claude)
      CLAUDE_CODE_OAUTH_TOKEN="$SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN" claude -p \
        --output-format stream-json \
        --verbose \
        --no-session-persistence \
        --strict-mcp-config \
        --mcp-config "$WORK_DIR/claude.mcp.json" \
        --permission-mode dontAsk \
        --allowedTools "mcp__scrimba__start_explainer_stream,mcp__scrimba__append_explainer_chunk,mcp__scrimba__finish_explainer_stream,Read,Bash,WebFetch,WebSearch,Write" \
        < "$dir/prompt.md" \
        2> >(tee "$dir/agent-stderr.txt" | sed -u "s/^/[$agent stderr] /" >&2) \
        | tee "$dir/claude-stream.jsonl" \
        | jq --unbuffered -r -f "$WORK_DIR/format-claude-stream.jq" \
        | tee "$dir/agent-output.txt" \
        | sed -u "s/^/[$agent] /"
      status="${PIPESTATUS[0]}"
      ;;
    codex)
      printf '%s' "$SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64" | base64 -d > "$CODEX_HOME_DIR/auth.json"
      CODEX_HOME="$CODEX_HOME_DIR" codex exec \
        --ephemeral \
        --cd "$GITHUB_WORKSPACE" \
        --sandbox danger-full-access \
        --json \
        --output-last-message "$dir/agent-final.txt" \
        - \
        < "$dir/prompt.md" \
        2> >(tee "$dir/agent-stderr.txt" | sed -u "s/^/[$agent stderr] /" >&2) \
        | tee "$dir/codex-stream.jsonl" \
        | jq --unbuffered -Rr -f "$WORK_DIR/format-codex-stream.jq" \
        | tee "$dir/agent-output.txt" \
        | sed -u "s/^/[$agent] /"
      status="${PIPESTATUS[0]}"
      if [ -s "$dir/agent-final.txt" ]; then
        {
          echo
          echo "----- final message -----"
          cat "$dir/agent-final.txt"
        } >> "$dir/agent-output.txt"
      fi
      ;;
    *)
      echo "::error::Unknown agent: $agent"
      status=1
      ;;
  esac

  echo "$status" > "$dir/exit-code.txt"
  extract_agent_result "$agent"

  if [ "$status" != "0" ]; then
    echo "Failed" > "$dir/status.txt"
  elif [ -s "$dir/skip-reason.txt" ]; then
    echo "Skipped" > "$dir/status.txt"
  elif [ -s "$dir/url.txt" ]; then
    echo "Done" > "$dir/status.txt"
  else
    echo "Failed" > "$dir/status.txt"
    echo "1" > "$dir/exit-code.txt"
  fi

  log_status "$agent exited with status $(cat "$dir/exit-code.txt") and final state $(cat "$dir/status.txt")"
  return 0
}

main() {
  require_cmd gh
  require_cmd git
  require_cmd jq
  require_cmd npm

  if [ -z "${GH_TOKEN:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="$GITHUB_TOKEN"
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::error::Set GH_TOKEN or GITHUB_TOKEN so the action can read PR data and post comments."
    exit 1
  fi

  mkdir -p "$WORK_DIR"
  resolve_agents
  resolve_pr_context
  enforce_fork_policy
  prepare_mcp_config
  prepare_prompts
  write_comment_helpers
  install_agent_clis
  write_stream_formatters

  export SCRIMBA_PR_EXPLAINER_AGENTS="$RESOLVED_AGENTS_CSV"
  export SCRIMBA_PR_EXPLAINER_HEAD_SHA="$HEAD_SHA"
  export SCRIMBA_PR_EXPLAINER_PR_NUMBER="$PR_NUMBER"

  for agent in "${RESOLVED_AGENTS[@]}"; do
    echo "Queued" > "$AGENTS_DIR/$agent/status.txt"
  done
  render_and_post_comment

  set +e
  watch_agent_progress &
  POLLER_PID="$!"

  RUNNERS=()
  for agent in "${RESOLVED_AGENTS[@]}"; do
    run_agent "$agent" &
    RUNNERS+=("$agent:$!")
  done

  for runner in "${RUNNERS[@]}"; do
    pid="${runner#*:}"
    wait "$pid" 2>/dev/null || true
  done

  if [ -n "${POLLER_PID:-}" ]; then
    kill "$POLLER_PID" 2>/dev/null || true
    wait "$POLLER_PID" 2>/dev/null || true
  fi

  update_comment_if_changed

  for agent in "${RESOLVED_AGENTS[@]}"; do
    echo "::group::Full agent transcript ($agent)"
    cat "$AGENTS_DIR/$agent/agent-output.txt" 2>/dev/null || true
    echo "::endgroup::"
    if [ -s "$AGENTS_DIR/$agent/agent-stderr.txt" ]; then
      echo "::group::Agent stderr ($agent)"
      cat "$AGENTS_DIR/$agent/agent-stderr.txt"
      echo "::endgroup::"
    fi
  done

  local overall_status=0
  for agent in "${RESOLVED_AGENTS[@]}"; do
    code="$(cat "$AGENTS_DIR/$agent/exit-code.txt" 2>/dev/null || echo 1)"
    if [ "$code" != "0" ]; then
      overall_status=1
    fi
  done

  exit "$overall_status"
}

main "$@"
