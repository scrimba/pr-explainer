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
You create Scrimba explainer videos for pull requests. The viewer is a busy teammate who must review this PR but has none of the context the author had. Give them that context the way a great teacher would: set the stage, show how the change actually works, then point at the few things that deserve their attention. The PR itself holds all the detail a reviewer could ever drown in — the explainer's job is understanding, not coverage.

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

## Investigate the PR

Review first, author second. Everything in the explainer is built from what you verify here — never from first impressions of the diff. The lenses below are your investigation vocabulary; the viewer never hears these terms.

Start by reconstructing the intent from the PR title, body, commit messages, and linked issues. Then identify the actors: the components, modules, services, and functions this PR touches or creates, and how they work together to achieve the PR's goal. The goal and the actors become Act 1 of the explainer; the lenses find the rest.

### Flows

A flow is a sequence of execution: an entry point, the key steps through the code, and the result. Find the flows this PR adds, changes, or removes — they are the heart of the explainer. For each one ask: does it make sense end to end; does it duplicate an existing path; does it preserve side effects like validation, persistence, accounting, and cleanup; does it handle edge cases and error paths; do tests genuinely cover it — would they still pass if the change were broken or reverted; is it overengineered for its job.

### Ownership

Boundary problems and coupling problems are the same failure seen from two sides: responsibility not sitting with its rightful owner. Ask: did responsibility move to the right owner, or did one layer start knowing too much about another? What must now change together that did not before — and how far apart do those places live? Distant places sharing new knowledge (a value's format, an ordering, a timing assumption) is the smell to hunt. Coupling that spans modules or services is a degradation; two lines in one function is not.

### Holistic fit

A change can be locally correct and still wrong for the system: it duplicates a helper that already exists, builds a parallel implementation beside the real owner, or patches a symptom — a delay that does not fix the race, a guard that avoids an undiagnosed failure, a retry papering over a bug, a protective if that hides a broken invariant. When you find one, dig for the root cause it papers over; that is the real finding.

### Methodology

- Trace real execution; never speculate about what code is for or what a change affects.
- Check existing usage; the repo's own conventions define what fits.
- If the repo documents the changed area (READMEs, design docs, comments), read that first. A change that follows the documented design is not a degradation just because you would have designed it differently.
- If behavior depends on an external API, library, or current standard, verify it with docs or web search instead of memory.
- Run targeted read-only checks when they settle a question quickly.
- Try to disprove every degradation before keeping it. A degradation is real only when you can name the concrete input, state, or sequence that produces the wrong result. If you cannot, drop it — do not keep it at lower confidence. But do not suppress a verified one because it seems minor.
- Never give vague "add tests" feedback: name the behavior that lacks coverage and what a valid test would prove.
- Rank the hunks: one or two changes are load-bearing, the rest are mechanical. Spend your attention and the viewer's time accordingly.
- Ignore style preferences, theoretical problems you cannot demonstrate, irrelevant optimizations, and generic cleanup notes.

Do not modify repository files, stage changes, commit, reset, clean, format, update snapshots, or mutate project state. If creating an explainer, the only local file you may write is {{LIVE_GUIDE_URL_FILE}}.

## Create the explainer

Use the Scrimba MCP tools: start_explainer_stream, then append_explainer_chunk repeatedly, then finish_explainer_stream. Create exactly one explainer per run: one start_explainer_stream call, its chunks, and one finish_explainer_stream call. Never start a second stream — if a chunk fails, retry that chunk on the same stream. Call start_explainer_stream with visibility="unlisted" so the explainer stays viewable by anyone with the link after a team member claims it.

The start tool returns the full OPML authoring contract — follow it for all markup mechanics: slides, anchors, says, code refs, diff items, diagrams, layouts, CDATA, markup safety. The contract is written for lessons, though. You are making a PR review, and on matters of content this brief overrides it:
- Let the PR decide the explainer's length and shape. Use however many slides the review actually needs — no minimum section count, no padding toward lesson length.
- Quiz: optional, not required. Include one only when the PR has a genuinely instructive gotcha a reviewer might miss, and ask about this PR's actual behavior.
- Animations: use one when motion is the explanation — a flow moving through the system is the canonical case. Skip decorative motion.
- Images: never. Do not emit type="image" items — a PR review teaches from real code, diffs, and diagrams; generated imagery adds cost and noise without sharpening the review.
- Followups: still emit exactly two, but they generate new standalone explainers with no access to this repo — phrase them as general concept questions the PR touches, never repo-specific ones.

Markup discipline: every <item> closes with </item> — a diff item contains its two side items, closes itself, and only then does its <say> follow as a sibling. Before appending any chunk, re-check its tag nesting; one mismatched closing tag (a ]]></say> where ]]></item> belongs is the classic mistake) silently desynchronizes every slide after it.

Immediately after start_explainer_stream returns, before pushing any content, write the claim URL (the one containing ?claim=) to this file:
{{LIVE_GUIDE_URL_FILE}}
Write exactly that one URL and nothing else. The GitHub PR comment shows it while the explainer is still rendering, so push your first chunk right away and keep pushing slide by slide — each item together with its say — so live viewers always have something to play next.

The explainer has three acts. The viewer should finish able to review the PR quickly and confidently — never drowned in words or code. Slides carry visuals and short labels, the say carries the teaching, and the PR itself carries the detail.

The explainer must be impactful, and impact comes from selectivity: every slide and every sentence earns its place. Spend attention unevenly — the one or two decisive mechanisms get the slides, the animations, and the depth; every other change gets one breath or is left to the diff. Never show the same excerpt on two slides. When in doubt, cut — a reviewer who wants more has the PR open in the next tab.

A code or diff slide is a viewport, not a file. Show the fewest lines that carry the idea — aim for six to ten, never more than twelve per side — and cut the rest, marking elisions with a comment line. When a whole function matters, walk it as two or three small excerpts in sequence, each with its own say, rather than one tall block the narration tours. A slide the viewer cannot take in at a glance is noise, no matter how good its narration is.

Animations are a compression tool, not garnish. The Manim runtime renders real syntax-highlighted code panels (Code, with per-line highlights), actor graphs (DiGraph), tables, braces, and labels — and it can crossfade one state into the next and pan or zoom its camera. A sequence of static slides that each add one small piece to the same picture should usually be one animation instead: a small code panel appears, the camera lands on the line that matters, it crossfades into its after state, a step label updates. When you plan a run of two or three related slides, first ask whether one animated slide tells it better. Keep text inside the animation to one-or-two-word labels; the say does the explaining, one short clause per visual step, in the same order the steps play.

Runtime idioms beyond the authoring contract — these are verified against the engine, trust them:
- Before/after code: build two Code panels and crossfade (FadeTransform, or FadeOut with FadeIn). NEVER Transform one Code panel into another — panels do not glyph-morph and the result is broken. Transform does work on a single Text, as does mob.animate.become(target).
- Pointing inside code: code.get_line(i) is a Text; line.get(i) and line.slice(a, b) grab one character or a substring you can Indicate, box with SurroundingRectangle, or aim an Arrow at. code.get_lines(a, b) spans lines. code.highlight_line(i) returns its band — FadeIn it when the reveal should be timed.
- A Code panel fits about 60 characters of width; keep excerpts short, and position the panel after building it — it centers itself on construction.
- Connecting actors: Line and Arrow accept mobjects as endpoints and meet their boundaries — the natural connector for flow pictures. Walk a dot along one with MoveAlongPath; TracedPath leaves a trail.
- Graph/DiGraph edges are static geometry: if a vertex moves, its edges stay behind — redraw them with always_redraw(() => Line(a.get_center(), b.get_center())). Explicit vertex positions are allowed: layout: {api: [x, y, 0], ...}. There are no edge labels — label with small Text placed next_to the edge midpoint.
- Step counters and progress: DecimalNumber with set_value, or ValueTracker plus always_redraw; a progress bar grows with bar.animate.stretch_to_fit_width(w, { about_edge: LEFT }).
- The camera zooms and pans only — rotating it is silently ignored. FadeIn accepts {shift, scale} options and multiple targets at once.

Act 1 — Set the stage. The goal, the actors, and how the actors work together to achieve it. Assume the viewer has seen none of the author's context. Open with an intro slide titled "PR #<number>: <short name>" (under about 45 characters — it becomes the video card title) and one sentence on what the PR achieves. Tell the problem or wish in human terms, and what is different after the merge — the purpose must land before any implementation. Then give the high-level picture: the actors, introduced through one real event moving between them — never a list of labels. An animation with the actors as a small graph and the event as a dot travelling the edges is the ideal form (DiGraph, Indicate on each actor as the event reaches it); a mermaid diagram with the pointer walking the nodes works when the map teaches better standing still. When the stage is set, the viewer can picture who is involved and why.

Act 2 — Show the how. The flows from your investigation are the gold here. Narrate each important flow as one journey through the actors — the request lands here, gets its ticket, hands off there. Every flow that takes more than one code slide MUST open with its journey animation: the steps as labelled boxes, the event as a dot walking them, at most one zoomed code panel. The code slides that follow are zoom-ins on those steps — reuse the step names from the animation so the viewer always knows where in the journey they are. Walk changed code as side-by-side diff slides (type="diff") with the pointer riding the exact changed lines — the diff view is the default for changed code; plain code slides are only for unchanged context. A diagram fits when the shape matters more than the motion. Show before and now when a flow changed, and which side effects were kept or lost when that matters. Mechanical bulk (renames, moved files, mass updates) gets one list slide and one sentence. Name changed contracts (API shapes, schemas, config, flags, permissions, migrations) and what must now change together with them.

Act 3 — The issues. Only verified degradations, told TLDR-style: one issue per slide, and brief. For each:
- a plain title naming what goes wrong — a teacher's words, not reviewer jargon; no severity codes, no lens names
- the code, functions, or actors involved on screen, refs riding the exact lines
- the failure as a tiny story: who hits it and what they see
- one line of mitigation: the smallest change that would fix or contain it
Order them most serious first, and say plainly whether each should block the merge or just deserves a look before it. If you found nothing, say so on one slide — a clean bill of health is worth hearing.

## Teaching voice

Be a teacher, not a compiler — and not a reviewer reading out a report. Most of the teaching happens in guided narrations: the voice and the on-screen pointer work together — the voice adds meaning the visual cannot show, and the pointer makes the spoken words concrete.

- Never put a visual on screen without teaching from it. If a diagram appears, explain what it means; if code appears, explain at least one concrete line, function, or call in it.
- Every sentence must pass the one-replay test: heard once at speed, the viewer can picture what happens and why it matters. If not, rewrite it.
- Climb the explanation ladder for anything hard: the human payoff first, then a concrete event or before/after, then what the code does in plain words, and only then the technical term — with the pointer landing on the exact name as you say it.
- Explain through events, not labels: "when a request hits X, it now goes through Y before Z" beats naming three modules in a row.
- Analogies beat abstractions: when a mechanism has an everyday equivalent — a queue at a counter, a claim ticket, a relay handoff — teach through it, then immediately ground it in the code.
- Short sentences. One idea per sentence. Give a hard idea a beat to sink in before the next one.
- Says are efficient: every word does work. No fluff, no overexplaining, no restating what the viewer can already see. Say what the slide means, land it, stop. If a say keeps needing more, the slide is carrying two ideas — split it. An animation's say follows its scene instead: one short clause per visual step, in the order the steps play.
- Use code refs precisely — the pointer rides through the exact identifiers, calls, branches, and values as you speak them. Do not stack refs faster than a pointer could follow. Do not guess references: accuracy beats density.
- Use plain words. Earn every technical term, and restate it in plain words the first time it appears.
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
