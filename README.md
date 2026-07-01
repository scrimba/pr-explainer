# Scrimba PR Explainer

Create Scrimba explainers for GitHub pull requests with Claude Code, Codex, or both.

The action checks out the PR, lets the selected agent inspect the code and diff, creates a Scrimba explainer through the Scrimba MCP server, and keeps one PR comment updated with the latest explainer links.

## Quick Start

```bash
cd your-repo
npx @scrimba/pr-explainer init
```

If you are testing from GitHub before the npm package is published:

```bash
npx github:scrimba/pr-explainer init
```

The init command:

- detects the current GitHub repo with `gh`
- detects Claude Code and Codex locally
- asks whether to use Claude, Codex, or both
- helps create or collect auth for the selected agents
- asks before setting GitHub variables and secrets
- writes `.github/workflows/scrimba-pr-explainer.yml`
- does not commit anything

## Requirements

- A GitHub repository with Actions enabled
- GitHub CLI installed and authenticated: `gh auth login`
- Node.js 20 or newer for the init command
- At least one supported agent:
  - Claude Code with a Claude Code OAuth token
  - Codex with `~/.codex/auth.json`

This action is designed for subscription-based CLI auth. You do not need LLM API keys.

## What Gets Installed

The generated workflow runs on:

- `pull_request`: opened, synchronize, reopened, ready for review
- `workflow_dispatch`: manual runs

It posts one PR comment that updates as each selected agent:

- starts
- writes a live Scrimba explainer URL
- skips a tiny PR
- finishes
- fails

Multiple agents run in parallel.

## Workflow Example

The init command writes this shape of workflow:

```yaml
name: Scrimba PR Explainer

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
  workflow_dispatch:
    inputs:
      agents:
        description: Comma-separated agents to use, e.g. claude,codex
        required: false
        default: ""
        type: string
      pr_number:
        description: PR number to explain when running manually
        required: false
        type: string

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  explain:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 22

      - uses: scrimba/pr-explainer@main
        with:
          agents: ${{ vars.SCRIMBA_PR_EXPLAINER_AGENTS }}
        env:
          GH_TOKEN: ${{ github.token }}
          SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN }}
          SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64: ${{ secrets.SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 }}
```

Use `npx @scrimba/pr-explainer init` for the full workflow, including manual PR selection, fork protection, concurrency, and MCP URL configuration.

## Agent Setup

Set one or more agents:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_AGENTS --body 'claude,codex'
```

`SCRIMBA_PR_EXPLAINER_AGENT` is a singular alias for one selected agent:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_AGENT --body claude
```

When both are set, `SCRIMBA_PR_EXPLAINER_AGENTS` wins.

## Claude Auth

Create a Claude Code OAuth token:

```bash
claude setup-token
```

Then store it as a GitHub Actions secret:

```bash
gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN
```

The init command can also run `claude setup-token` for you, accept a pasted token, or let you skip Claude secret setup and do it later.

## Codex Auth

Sign in with Codex:

```bash
codex login --device-auth
```

Then store the Codex auth file as a GitHub Actions secret:

```bash
gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body "$(base64 < ~/.codex/auth.json | tr -d '\n')"
```

The init command can run the Codex login flow and set this secret for you.

## Action Inputs

These are `with:` inputs on `uses: scrimba/pr-explainer@main`.

| Input | Default | Description |
|---|---:|---|
| `agents` | `""` | Comma-separated agents to run, such as `claude,codex`. |
| `agent` | `""` | Singular alias for `agents`, such as `claude`. |
| `pr-number` | `""` | PR number to explain when running manually. |
| `mcp-url` | `https://scrimba.com/explain/mcp` | Scrimba MCP server URL. |

If `agents` and `agent` are both empty, the action chooses an agent from the available secrets, preferring Claude when both are absent.

## Repository Variables

These are GitHub repository variables used by the generated workflow.

| Variable | Description |
|---|---|
| `SCRIMBA_PR_EXPLAINER_AGENTS` | Comma-separated agents to run, such as `claude,codex`. |
| `SCRIMBA_PR_EXPLAINER_AGENT` | Singular alias for one agent. |
| `SCRIMBA_PR_EXPLAINER_MCP_URL` | Optional override for the Scrimba MCP URL. Defaults to production Scrimba. |
| `SCRIMBA_PR_EXPLAINER_ALLOW_FORKS` | Set to `true` to run on fork PRs. Defaults to disabled. |

The generated workflow maps `SCRIMBA_PR_EXPLAINER_MCP_URL` into the action's `mcp-url` input. If you write your own workflow and set `with: mcp-url`, that explicit input is what the action uses.

## Secrets

| Secret | Required when | Description |
|---|---|---|
| `SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN` | Using Claude | Token from `claude setup-token`. |
| `SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64` | Using Codex | Base64 encoded `~/.codex/auth.json`. |

## Fork PRs

Fork PRs are skipped by default.

To allow them:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_ALLOW_FORKS --body true
```

Only enable this for repositories where you are comfortable letting PR-controlled code and prompts influence agents that can read job secrets. GitHub hides secret values in the UI, but processes running inside a workflow job can read secrets that are passed to that job.

## Manual Runs

The generated workflow supports `workflow_dispatch`.

Use it when you want to regenerate an explainer without pushing a new commit:

- choose the `Scrimba PR Explainer` workflow in GitHub Actions
- click `Run workflow`
- enter a PR number
- optionally override `agents`

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

Missing Codex secret:

```text
Missing SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 secret for Codex.
```

Run:

```bash
codex login --device-auth
gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body "$(base64 < ~/.codex/auth.json | tr -d '\n')"
```

No PR comment appears:

- check the workflow has `issues: write`
- check the job has `GH_TOKEN: ${{ github.token }}`
- check the workflow is running on a PR from the same repository, or enable fork PRs explicitly

## Development

Validate the action and CLI:

```bash
npm run check
npm pack --dry-run
```

For a stable public release, move the generated workflow and docs from `@main` to `@v1`, then publish both the GitHub Action ref and the npm package:

```bash
git tag -f v1
git push origin main v1 --force
npm publish --access public
```
