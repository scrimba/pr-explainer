#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=".scrimba-pr-explainer"
AGENTS_DIR="$WORK_DIR/agents"
DEFAULT_MCP_URL="https://scrimba.com/explain/mcp"
# Pinned to the MCP host in prepare_mcp_config so PR content cannot smuggle a
# foreign explainer URL into the comment.
EXPLAINER_URL_REGEX=""

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
    raw_agents="claude"
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
      claude) ;;
      codex)
        echo "::error::Codex support has been removed for now: subscription-based Codex auth cannot survive ephemeral CI runners. See https://github.com/scrimba/pr-explainer/issues/2."
        exit 1
        ;;
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
  elif ! PR_NUMBER="$(gh pr view --json number --jq .number 2>/dev/null)"; then
    echo "::error::No PR to explain: this run was not triggered by a pull request, no pr-number input was given, and $GITHUB_REF has no open PR. Enter a PR number when dispatching the workflow manually."
    exit 1
  fi

  gh pr view "$PR_NUMBER" \
    --json number,title,body,url,baseRefName,baseRefOid,headRefName,headRefOid,author,files,isCrossRepository,isDraft \
    > "$WORK_DIR/pr.json"

  BASE_SHA="$(jq -r .baseRefOid "$WORK_DIR/pr.json")"
  HEAD_SHA="$(jq -r .headRefOid "$WORK_DIR/pr.json")"
  IS_CROSS_REPOSITORY="$(jq -r .isCrossRepository "$WORK_DIR/pr.json")"
  IS_DRAFT="$(jq -r .isDraft "$WORK_DIR/pr.json")"

  jq -r '.files[] | "- \(.path) (+\(.additions)/-\(.deletions))"' "$WORK_DIR/pr.json" > "$WORK_DIR/diffstat.txt"
  gh pr diff "$PR_NUMBER" --patch --color never > "$WORK_DIR/pr.diff"

  log_status "Explaining PR #$PR_NUMBER at $HEAD_SHA"
}

enforce_draft_policy() {
  if [ "${IS_DRAFT:-false}" = "true" ]; then
    log_status "PR #$PR_NUMBER is a draft; skipping. An explainer is created when it is opened as or marked ready for review."
    exit 0
  fi
}

enforce_fork_policy() {
  if [ "${IS_CROSS_REPOSITORY:-false}" = "true" ] && [ "${SCRIMBA_PR_EXPLAINER_ALLOW_FORKS:-}" != "true" ]; then
    echo "::error::PR #$PR_NUMBER is from a fork. Set the allow-forks action input to true only if you trust fork PR content not to prompt-inject the selected agent."
    exit 1
  fi
}

resolve_linked_issues() {
  : > "$WORK_DIR/linked-issues.md"
  local numbers issue
  numbers="$(gh pr view "$PR_NUMBER" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[].number' 2>/dev/null | head -n 3 || true)"
  for issue in $numbers; do
    {
      echo "Issue #$issue:"
      gh issue view "$issue" --json title,body \
        --jq '"Title: \(.title)\n\(.body // "(no body)")"' 2>/dev/null | head -c 4000 || true
      echo
      echo
    } >> "$WORK_DIR/linked-issues.md"
  done
}

prepare_mcp_config() {
  MCP_URL="${SCRIMBA_PR_EXPLAINER_MCP_URL:-$DEFAULT_MCP_URL}"
  [ -n "$MCP_URL" ] || MCP_URL="$DEFAULT_MCP_URL"

  local mcp_scheme mcp_host mcp_host_re
  case "$MCP_URL" in
    http://*) mcp_scheme="http" ;;
    *) mcp_scheme="https" ;;
  esac
  mcp_host="$(printf '%s' "$MCP_URL" | sed -E 's#^[A-Za-z]+://##; s#[/?].*$##')"
  mcp_host_re="$(printf '%s' "$mcp_host" | sed 's/\./\\./g')"
  EXPLAINER_URL_REGEX="${mcp_scheme}://${mcp_host_re}/explain/[A-Za-z0-9_-]+(\?claim=[A-Za-z0-9_-]+)?"

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
}

prepare_prompts() {
  mkdir -p "$AGENTS_DIR"

  cat > "$WORK_DIR/system-prompt.base.md" <<'EOF'
You are creating a Scrimba PR Explainer: a short narrated video that helps human reviewers review a pull request well. The viewer is a busy teammate deciding whether to approve, what to push back on, and what to test. Every slide must either build their understanding of the change or sharpen their review.

You are running inside a checkout of the repository at the PR merge commit.

The user message contains the complete PR data: metadata, description, linked issues, and diffstat. The full unified diff is on disk at .scrimba-pr-explainer/pr.diff — read and search that file. Do not re-fetch any of this from GitHub.

You also have the full repo, git history, the gh CLI, rg, and web search. Do not rely only on the diff: read the changed files as they exist at HEAD, the surrounding code, existing usage of touched functions, and nearby tests to reconstruct intent.

## First: decide whether this PR deserves an explainer

Skip when a narrated walkthrough adds nothing over glancing at the diff:
- a one-line copy or UX text change, trivial typo, formatting-only, comment-only, or metadata-only change
- a tiny config value change, a lockfile-only change, or a dependency bump with no behavior change in this repo
- generated files only, or any change with no meaningful behavior, flow, boundary, or review risk to explain

Do not skip when the PR changes behavior, security, data flow, public API, schema/persistence, permissions, billing/accounting, CI/deploy behavior, or multiple connected files.

If you skip, do not call any Scrimba MCP tool. End your final response with exactly:
SCRIMBA_PR_EXPLAINER_SKIP_REASON=<one short sentence>

## Review the PR

Do the review first. The explainer is authored from the review's verified results, never from first impressions of the diff.

You are a code reviewer.
1. Understand the changes and their consequences.
2. Explain what has changed clearly and plainly using standard language.
3. Report every verified concern that negatively affects these qualities: correctness, maintainability, scalability, consistency, reliability, readability.

Apply every quality within the holistic context of the entire codebase, not just the single file or change. Consider the entire system and how it is affected by the change: a code change can be correct but still be the wrong one because it is in the wrong place, it is repeated, it does not follow system conventions, it is un-understandable, it is highly (and unnecessarily) coupled, or it is short-sighted and does not consider where the system as a whole is heading.

Your review lenses are ways of looking at the code that let you determine what is good or bad. You have three.

### Lens 1: Holistic architecture

Holistic architecture considers changes in the context of the entire system and how the whole system is made better or worse by the change.

Non-holistic changes are code smells that are either hacks, bandaids, or patch work. If a change is any of those, the underlying models, architecture, abstractions, or foundations are most likely wrong and should be fixed instead. For example: a delay that does not fix the underlying race, a guard that avoids an undiagnosed failure, a retry papering over a bug, a protective if that hides a broken invariant, a parallel implementation that leaks responsibility across a boundary.

If you see a code smell, determine the root cause of why that smell is there — it usually leads to a more systemic holistic concern that is the real problem.

### Lens 2: Flows

A flow is a sequence of execution: an entry point, the key steps through the code, and the result.

Identify flows that were added, modified, or removed. Ask:
- Does the flow make sense end to end?
- Does it duplicate an existing path?
- Does it preserve important side effects, validation, persistence, accounting, or cleanup?
- Does it handle edge cases and error paths?
- Do tests cover the behavior that changed?
- Is it overengineered?

### Lens 3: Boundaries

A boundary is a layer or module responsibility.

Identify boundaries that were crossed, added, removed, or clarified. Ask:
- Did responsibility move to the right owner?
- Did a layer start knowing too much about another layer?
- Did the change make the system easier or harder to reason about?
- Is the abstraction level consistent with nearby code?

### Review methodology

- Reconstruct intent from the PR title, body, commit messages, and linked issues.
- Trace real execution flows; do not speculate about what the code is used for or how the changes affect the system.
- Look for existing usage and check the change is consistent with it.
- If the project documents the area being changed (READMEs, design docs, comments), read that first — it defines what the change must fit. A change that follows the documented design is not a concern just because you would have designed it differently.
- Check that tests cover the changed behavior and that they are valid tests. You cannot run or modify code, so read each covering test and infer whether it would still pass if the change were broken or reverted — a test that cannot fail for this change does not cover it, and that is worth reporting.
- If behavior depends on an external API, library, provider, or current standard, verify it with docs or web search instead of memory.
- Ensure that root causes are being fixed.
- Always try to disprove any concern you raise, and omit it if it does not survive. A concern is demonstrated only when you can name a concrete input, state, or sequence that produces the wrong result. "This could happen" is not demonstrated. If you cannot produce one, drop the concern — do not keep it at a lower severity.
- Do not report vague "add tests" feedback. Explain the behavior that lacks coverage and what a valid test would prove.
- Do not suppress verified concerns because they seem minor or non-blocking. If it is real and relevant, it goes in the video.
- Rank the hunks: almost every PR has one or two load-bearing changes and many mechanical ones. Budget slides by review risk, not by diff size.
- Run targeted read-only checks when they settle a question quickly.

Ignore: style preferences unless they violate clear local patterns or harm readability; theoretical problems you cannot demonstrate; optimizations without actual performance relevance; internal API changes that are already handled and fit the project; generic cleanup that does not improve maintainability, consistency, or future change safety.

Do not modify repository files, stage changes, commit, reset, clean, format, update snapshots, or mutate project state. If creating an explainer, the only local file you may write is {{LIVE_GUIDE_URL_FILE}}.

## Create the explainer

Use the Scrimba MCP tools: start_explainer_stream, then append_explainer_chunk repeatedly, then finish_explainer_stream. Create exactly one explainer per run: one start_explainer_stream call, its chunks, and one finish_explainer_stream call. Never start a second stream — if a chunk fails, retry that chunk on the same stream. Call start_explainer_stream with visibility="unlisted" so the explainer stays viewable by anyone with the link after a team member claims it.

The start tool returns the full OPML authoring contract — follow it for all markup mechanics: slides, anchors, says, code refs, diff items, diagrams, layouts, CDATA, markup safety. The contract is written for lessons, though. You are making a PR review, and on matters of content this brief overrides it:
- Let the PR decide the explainer's length and shape. Use however many slides the review actually needs — no minimum section count, no padding toward lesson length.
- Quiz: optional, not required. Include one only when the PR has a genuinely instructive gotcha a reviewer might miss, and ask about this PR's actual behavior.
- Animations: use one when motion is the explanation — a flow moving through the system is the canonical case. Skip decorative motion.
- Images: never. Do not emit type="image" items — a PR review teaches from real code, diffs, and diagrams; generated imagery adds cost and noise without sharpening the review.
- Followups: still emit exactly two, but they generate new standalone explainers with no access to this repo — phrase them as general concept questions the PR touches, never repo-specific ones.

Immediately after start_explainer_stream returns, before pushing any content, write the claim URL (the one containing ?claim=) to this file:
{{LIVE_GUIDE_URL_FILE}}
Write exactly that one URL and nothing else. The GitHub PR comment shows it while the explainer is still rendering, so push your first chunk right away and keep pushing slide by slide — each item together with its say — so live viewers always have something to play next.

The explainer is the review, narrated — but it is a video, not a document. Every review idea must land as the explainer feature built for it. Reach for the visual first and hang the narration on it:

- Changed code always goes on a side-by-side diff slide (type="diff"). This is a PR review: the diff view is the default way to show any code this PR touched. Plain code slides are only for unchanged context the viewer needs.
- A flow through the system is an animation when motion is the explanation — a request travelling through its stages is the canonical case — or a small mermaid diagram when the shape matters more than the motion. Never a text list of steps.
- A boundary move is a before/after ownership picture: a small diagram, or the old and new owner code side by side.
- A finding shows the offending code on screen, with refs riding the exact lines as the say walks the failure.
- Mechanical bulk (renames, moved files, mass updates) is one list slide with one sentence — spend the saved time on the load-bearing hunks.
- Visible text is labels, not prose: a short title and a few short bullets at most. If a slide is mostly words, it should have been a diff, a diagram, or an animation — or should be cut.
- Keep each say tight: about three or four short sentences per item. If an idea needs more, the slide is carrying more than one idea — split it.

It covers, in order:

1. What the PR does and why. Lead with the human story: the problem or wish that existed, and what a user or developer actually experiences after the merge — make the viewer picture the before and the after. The purpose must land before any implementation. Open with an intro slide titled "PR #<number>: <short name>" (under about 45 characters — it becomes the video card title) and one sentence on what the PR achieves.

2. Flows. Narrate each important changed flow in execution order as a journey — the request lands here, gets its ticket, hands off there — showing the changed code as diff slides along the way. Show before and now, and say which side effects were preserved, removed, or added when that matters to the review. Purpose before mechanism on every slide; name changed contracts (API shapes, schemas, config, flags, permissions, migrations) and what must now change together with them.

3. Boundaries. When the PR moves responsibility, show who owned this before and who owns it now, and say why the new owner is — or is not — the natural home.

4. Holistic concerns. What the holistic architecture lens found: the change is locally correct but wrong for the system. Each concern must name both sides — what the change did in isolation, and the existing code, owner, or documented design it duplicated, bypassed, or patched around. Hold the fix to the same evidence bar as everything else: verify a better home exists in, or concretely fits, this codebase before recommending it. If you cannot name one, there is no concern — an observation about the design is not one. No generic tidy notes and no taste preferences.

5. Findings. Only verified issues that need fixing for correctness, safety, or runtime behavior — include every one, even if lower severity or non-blocking:
- P0: breaks users now.
- P1: breaks users under a condition that will occur.
- P2: a real defect with a limited blast radius.
- P3: correct today, but will mislead or trip the next person to touch it.
For each finding the narration covers the problem, the proof (what you read or checked that shows it), the impact, and a fix direction verified against this codebase. Narrate it as a short story of what goes wrong for whom — "a viewer presses play and hears nothing, because..." — never as a terse review nit. Put serious findings on their own slides with the offending code on screen and narration pointing at the exact lines.

6. Questions for the author. Close with the few concrete things a reviewer should check, test locally, or ask the author before merging. Ask a question only when the answer changes whether something is a concern, and say what answer would make it one. Never ask a question whose answer is in the code, tests, docs, or research.

Give flow, boundary, and concern slides titles that carry a bracketed verdict plus an action word, like "[better] Centralized: token refresh" or "[worse] Crossed: renderer now reads auth state". Verdicts: [beautiful] unusually clean improvement worth calling out, [better] clear improvement, [neutral] important shape change with no clear quality direction, [mixed] real tradeoff, [worse] regression or risk, [nightmare] severe architectural or operational danger. The verdict helps the viewer triage; the action word says what changed. A negative verdict usually deserves a matching holistic concern or finding — if it does not get one, the narration must say why it is only contextual.

Most PRs need only a few flow slides and often no boundary section at all — the verdict-tagged sections are for changes worth arguing about, not an inventory of everything the PR touched. Sections 3 through 6 exist only when the review found something for them — a PR with no boundary moves and no findings simply has fewer slides. But if there are no holistic concerns and no findings at all, say so plainly — a clean verdict is a useful verdict, not filler.

## Narration voice

The say narration carries the review; visible text stays short and scannable.
- Speak like a great teacher talking to a smart colleague who has not followed this work. Every sentence must pass the one-replay test: heard once at speed, the reviewer can picture what happens and why it matters.
- Any technical term you cannot avoid gets one short clause saying what it means. Never stack jargon: if a sentence needs three technical terms to parse, rewrite it as what actually happens in the running system.
- Analogies beat abstractions: when a mechanism has an everyday equivalent — a queue at a counter, a claim ticket, a relay handoff — teach through it, then ground it in the code.
- Explain through the real event, not through labels: "when a request hits X, it now goes through Y before Z" beats naming three modules in a row.
- Short sentences. One idea per sentence. Give a hard idea a beat before the next one.
- Use code refs heavily and precisely — the pointer should ride through the exact identifiers, calls, branches, and values as you speak them. Do not stack refs faster than a pointer could follow.
- State inferences as inferences: "this appears to be for X" when the reason is not in the code or PR description.
- No filler openings, no "in this PR we will", no praise padding. Start saying useful things immediately.

After finish_explainer_stream succeeds, end your final response with exactly:
SCRIMBA_PR_EXPLAINER_URL=<url>
EOF

  {
    echo "Pull request data:"
    echo
    jq -r '"PR #\(.number): \(.title)\nAuthor: \(.author.login)\nURL: \(.url)\nBase: \(.baseRefName) @ \(.baseRefOid)\nHead: \(.headRefName) @ \(.headRefOid)"' "$WORK_DIR/pr.json"
    echo
    echo "Description:"
    jq -r 'if (.body // "") == "" then "(none)" else .body end' "$WORK_DIR/pr.json"
    echo
    if [ -s "$WORK_DIR/linked-issues.md" ]; then
      echo "Linked issues:"
      cat "$WORK_DIR/linked-issues.md"
    fi
    echo "Diffstat:"
    cat "$WORK_DIR/diffstat.txt"
  } > "$WORK_DIR/prompt.user.md"

  for agent in "${RESOLVED_AGENTS[@]}"; do
    local dir="$AGENTS_DIR/$agent"
    mkdir -p "$dir"
    sed "s#{{LIVE_GUIDE_URL_FILE}}#$dir/live-guide-url.txt#g" "$WORK_DIR/system-prompt.base.md" > "$dir/system-prompt.md"
    cp "$WORK_DIR/prompt.user.md" "$dir/prompt.md"
    echo "Queued" > "$dir/status.txt"
    : > "$dir/url.txt"
    : > "$dir/skip-reason.txt"

    echo "::group::Agent system prompt ($agent)"
    cat "$dir/system-prompt.md"
    echo "::endgroup::"
    echo "::group::Agent user prompt ($agent)"
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

status_label() {
  case "$1" in
    Queued) printf '⏳ Queued' ;;
    Generating) printf '🎬 Generating' ;;
    Done) printf '✅ Done' ;;
    Skipped) printf '⏭️ Skipped' ;;
    Failed) printf '❌ Failed' ;;
    *) printf '%s' "$1" ;;
  esac
}

echo "<!-- scrimba-pr-explainer -->"
echo "### Scrimba PR Explainers"
echo
if [ -n "${SCRIMBA_PR_EXPLAINER_STARTED_AT:-}" ]; then
  echo "Generated for commit \`${SCRIMBA_PR_EXPLAINER_HEAD_SHA:0:7}\`, kicked off at $SCRIMBA_PR_EXPLAINER_STARTED_AT."
else
  echo "Generated for commit \`${SCRIMBA_PR_EXPLAINER_HEAD_SHA:0:7}\`."
fi
echo
echo "| Agent | Status | Explainer |"
echo "|---|---|---|"

IFS=',' read -r -a AGENTS <<< "$SCRIMBA_PR_EXPLAINER_AGENTS"
for agent in "${AGENTS[@]}"; do
  dir=".scrimba-pr-explainer/agents/$agent"
  status="$(cat "$dir/status.txt" 2>/dev/null || echo "Queued")"
  url="$(grep -Eom 1 "$SCRIMBA_PR_EXPLAINER_URL_REGEX" "$dir/url.txt" 2>/dev/null || true)"
  if [ -z "$url" ] && [ -s "$dir/live-guide-url.txt" ]; then
    url="$(grep -Eom 1 "$SCRIMBA_PR_EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" 2>/dev/null || true)"
  fi
  skip_reason="$(cat "$dir/skip-reason.txt" 2>/dev/null || true)"

  if [ -n "$url" ]; then
    explainer="[▶ Watch explainer]($url)"
  elif [ -n "$skip_reason" ]; then
    explainer="Skipped: $(cell "$skip_reason")"
  elif [ "$status" = "Failed" ]; then
    if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
      explainer="[Check workflow logs]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)"
    else
      explainer="Check workflow logs"
    fi
  else
    explainer="Waiting for link..."
  fi

  echo "| \`$(cell "$agent")\` | $(cell "$(status_label "$status")") | $explainer |"
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
  SCRIMBA_PR_EXPLAINER_URL_REGEX="$EXPLAINER_URL_REGEX" \
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
  local sources=("$dir/live-guide-url.txt" "$dir/$agent-stream.jsonl" "$dir/agent-output.txt")

  skip_reason="$(sed -nE 's/^(\[assistant\] )?SCRIMBA_PR_EXPLAINER_SKIP_REASON=//p' "$dir/agent-output.txt" 2>/dev/null | tail -n 1)"
  if [ -n "$skip_reason" ]; then
    printf '%s\n' "$skip_reason" > "$dir/skip-reason.txt"
  fi

  if [ -s "$dir/live-guide-url.txt" ]; then
    grep -Eom 1 "$EXPLAINER_URL_REGEX" "$dir/live-guide-url.txt" > "$dir/url.txt" 2>/dev/null || true
  fi

  guide_url="$(grep -hEo "$EXPLAINER_URL_REGEX" "${sources[@]}" 2>/dev/null | grep '?claim=' | tail -n 1 || true)"
  if [ -z "$guide_url" ]; then
    guide_url="$(grep -hEo "$EXPLAINER_URL_REGEX" "${sources[@]}" 2>/dev/null | tail -n 1 || true)"
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
      # In CI the secret is always set; local runs fall back to the
      # machine's own Claude Code login when it is not.
      if [ -n "${SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN"
      fi
      claude -p \
        --output-format stream-json \
        --verbose \
        --no-session-persistence \
        --strict-mcp-config \
        --mcp-config "$WORK_DIR/claude.mcp.json" \
        --system-prompt-file "$dir/system-prompt.md" \
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
  enforce_draft_policy
  enforce_fork_policy
  resolve_linked_issues
  prepare_mcp_config
  prepare_prompts
  write_comment_helpers
  install_agent_clis
  write_stream_formatters

  export SCRIMBA_PR_EXPLAINER_AGENTS="$RESOLVED_AGENTS_CSV"
  export SCRIMBA_PR_EXPLAINER_HEAD_SHA="$HEAD_SHA"
  export SCRIMBA_PR_EXPLAINER_PR_NUMBER="$PR_NUMBER"
  export SCRIMBA_PR_EXPLAINER_STARTED_AT="$(date -u '+%a, %d %b %Y %H:%M GMT')"

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

# Allow scripts/run-local.sh to source this file for its functions without
# running the CI entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
