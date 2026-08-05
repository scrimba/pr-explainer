# Scrimba PR Video Explainer

Create Scrimba explainer videos for GitHub pull requests with Claude Code.

The action checks out the PR, lets Claude Code inspect the code and diff, creates a Scrimba video explainer through the Scrimba MCP server, and keeps one PR comment updated with the latest explainer link.

Example video: https://scrimba.com/explain/guide0t4l29d7l

## Quick Start

```bash
cd your-repo
npx pr-explainer
```

`npx scrimba/pr-explainer` works too — npx resolves it as the GitHub repo, so it runs the same installer from the default branch.

The installer:

- verifies it is running inside a git repository
- writes `.github/workflows/scrimba-pr-explainer.yml`
- optionally sets the required GitHub secret, minting a token via `claude setup-token` when the Claude Code CLI is available
- prints the manual setup commands when automatic GitHub setup is unavailable or skipped
- does not commit anything

## Requirements

- A git repository hosted on GitHub with Actions enabled
- `git`
- Node.js 20 or newer for the installer
- Claude Code with a Claude Code OAuth token
- Optional: GitHub CLI installed and authenticated with `gh auth login` if you want the installer to set the repo secret for you

This action is designed for subscription-based CLI auth. You do not need LLM API keys.

## What Gets Installed

The generated workflow runs on:

- `pull_request`: opened, synchronize, reopened, ready for review
- `workflow_dispatch`: manual runs

Draft PRs are skipped: the workflow's job condition avoids spinning up a runner for them, and the action itself exits early if the resolved PR is still a draft. The explainer is created when a PR is opened ready for review, on pushes to a ready PR, and the moment a draft is marked ready for review.

The explainer is a helper, not a merge gate: the generated workflow runs the action with `continue-on-error: true`, so a failed explainer never blocks merging — the PR comment reports the failure and the check still passes.

It posts one PR comment that updates as the agent:

- starts
- writes a live Scrimba explainer URL
- skips a tiny PR
- finishes
- fails

## Workflow Example

The installer writes this shape of workflow:

```yaml
name: Scrimba PR Explainer

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      pr_number:
        description: PR number to explain when running manually
        required: false
        type: string

permissions:
  contents: read
  pull-requests: write
  issues: write

concurrency:
  group: scrimba-pr-explainer-${{ github.event.pull_request.number || inputs.pr_number || github.ref }}
  cancel-in-progress: true

jobs:
  explain:
    if: github.event_name != 'pull_request' || github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      # The explainer is a helper, not a merge gate. When the agent can't
      # build one, the PR comment says so and this check still passes.
      - name: Create Scrimba PR explainer
        continue-on-error: true
        uses: scrimba/pr-explainer@<ref>
        with:
          # allow-forks stays false because fork PRs can contain prompt
          # injection: the agent that builds the explainer reads PR content
          # with access to the checked-out repository and any secrets passed
          # to this job. Only set it to true if you trust every fork PR that
          # can reach this workflow.
          allow-forks: false
          pr-number: ${{ inputs.pr_number || '' }}
        env:
          GH_TOKEN: ${{ github.token }}
          SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN }}
```

The action handles checkout, Node setup, PR metadata, prompt logging, agent execution, and PR comments. The generated workflow owns everything contextual: triggers, token permissions, concurrency, workflow-dispatch inputs, action inputs, and secrets.

Replace `<ref>` with the action ref you want to run, such as `main` while testing unreleased changes or a versioned ref after release.

## Claude Auth

Create a Claude Code OAuth token:

```bash
claude setup-token
```

Then store it as a GitHub Actions secret:

```bash
gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN
```

The installer does both of these for you when the Claude Code CLI and an authenticated GitHub CLI are available. If either is unavailable or you skip automatic setup, it prints the manual commands.

## Codex

Codex support has been removed for now. Subscription-based Codex auth cannot survive ephemeral CI runners: Codex refresh tokens are single-use, so a static copy of `~/.codex/auth.json` stored as a secret breaks as soon as any copy of it refreshes — your local Codex CLI, or a CI run after the session goes stale (roughly 8 days). OpenAI's own guidance for durable CI auth is API keys or a persistent `CODEX_HOME`.

See https://github.com/scrimba/pr-explainer/issues/2 for the details and the plan to bring it back properly.

## Action Inputs

These are `with:` inputs on `uses: scrimba/pr-explainer@<ref>`.

| Input | Default | Description |
|---|---:|---|
| `agents` | `""` | Agents to run. Only `claude` is currently supported; empty defaults to `claude`. |
| `pr-number` | `""` | PR number to explain. Empty resolves the PR from the triggering event. |
| `allow-forks` | `"false"` | Set to `true` to allow PR explainers on fork PRs. |

## Secrets

| Secret | Required | Description |
|---|---|---|
| `SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN` | Yes | Token from `claude setup-token`. |

## Fork PRs

Fork PRs are skipped by default.

To allow them, set the action input in your workflow:

```yaml
with:
  allow-forks: true
```

Only enable this for repositories where you trust fork PRs not to execute prompt injections. These explainers are created by an agent using PR content, and that agent has access to the checked-out repository and any secrets passed to the job. The generated workflow carries this warning as a comment right above the `allow-forks` line, so it is in front of anyone about to flip it.

## Manual Runs

The generated workflow supports `workflow_dispatch`.

Use it when you want to regenerate an explainer without pushing a new commit:

- choose the `Scrimba PR Explainer` workflow in GitHub Actions
- click `Run workflow`
- enter a PR number

## Troubleshooting

Missing Claude secret:

```text
Missing SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN secret for Claude.
```

Run:

```bash
claude setup-token
gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN
```

No PR comment appears:

- check the PR is not a draft — draft PRs are skipped by design
- check the workflow has `issues: write`
- check the job has `GH_TOKEN: ${{ github.token }}`
- check the workflow is running on a PR from the same repository, or enable fork PRs explicitly

## Development

Validate the action and CLI:

```bash
npm run check
npm pack --dry-run
```

### Test locally

Generate an explainer for a local branch without GitHub:

```bash
# current branch vs auto-detected base, on a locally running Scrimba
scripts/run-local.sh /path/to/repo --scrimba-server=https://local.scrimba.tech:3009/

# explicit base
scripts/run-local.sh /path/to/repo --scrimba-server=https://local.scrimba.tech:3009/ --base main
```

The branch checked out in the target repo is treated as the PR head, and PR metadata is synthesized from git: the title comes from the first branch commit, the description from the commit messages. It runs the exact same prompts and agent invocation as the action — no PR comment is posted, and the explainer URL prints as soon as the stream starts.

- Auth: uses your local Claude Code login, or `SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN` when set.
- `--scrimba-server` is required, so a local run never streams anywhere by accident. Give it the base URL of the Scrimba server (plain-http works too); the MCP path is derived from it. Pass `--scrimba-server=https://scrimba.com` to deliberately create a real unlisted explainer on production.
- Prompts, agent streams, and the diff land in `.scrimba-pr-explainer/` inside the target repo — inspect them there, and delete the directory when done.

Test unreleased changes from GitHub:

```bash
npx github:scrimba/pr-explainer
```

During development, the installer may generate workflows that use `scrimba/pr-explainer@main`. For a stable release, use a versioned action ref such as `scrimba/pr-explainer@v1`.

Publish the npm installer:

```bash
npm login
npm publish
```

After publishing, verify the public installer:

```bash
npx pr-explainer
```

Publish the GitHub Action ref documented in this README:

```bash
git push origin main
git tag -f <ref>
git push origin <ref> --force
```
