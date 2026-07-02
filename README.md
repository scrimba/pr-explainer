# Scrimba PR Video Explainer

Create Scrimba explainer videos for GitHub pull requests with Claude Code, Codex, or both.

The action checks out the PR, lets the selected agent inspect the code and diff, creates a Scrimba video explainer through the Scrimba MCP server, and keeps one PR comment updated with the latest explainer links.

Example video: https://scrimba.com/explain/guide0t4l29d7l

## Quick Start

```bash
cd your-repo
npx @scrimba/pr-explainer init
```

The init command:

- verifies it is running inside a git repository
- detects Claude Code and Codex locally
- asks whether to use Claude, Codex, or both
- writes `.github/workflows/scrimba-pr-explainer.yml`
- optionally sets the required GitHub variables and secrets when `gh` is available and authenticated
- prints the manual setup commands when automatic GitHub setup is unavailable or skipped
- does not commit anything

## Requirements

- A git repository hosted on GitHub with Actions enabled
- `git`
- Node.js 20 or newer for the init command
- At least one supported agent:
  - Claude Code with a Claude Code OAuth token
  - Codex with `~/.codex/auth.json`
- Optional: GitHub CLI installed and authenticated with `gh auth login` if you want the installer to set repo variables and secrets for you

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

Multiple agents run in parallel, each producing its own video explainer link.

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
      agent:
        description: Singular alias for agents, e.g. claude
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

      - uses: scrimba/pr-explainer@<ref>
        with:
          agents: ${{ github.event.inputs.agents || github.event.inputs.agent || vars.SCRIMBA_PR_EXPLAINER_AGENTS || vars.SCRIMBA_PR_EXPLAINER_AGENT }}
          pr-number: ${{ github.event.inputs.pr_number || '' }}
          mcp-url: ${{ vars.SCRIMBA_PR_EXPLAINER_MCP_URL || 'https://scrimba.com/explain/mcp' }}
          allow-forks: ${{ vars.SCRIMBA_PR_EXPLAINER_ALLOW_FORKS || 'false' }}
        env:
          GH_TOKEN: ${{ github.token }}
          SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN }}
          SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64: ${{ secrets.SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 }}
```

Use `npx @scrimba/pr-explainer init` for the full workflow, including checkout ref resolution, manual PR selection, fork protection, concurrency, and MCP URL configuration.

Replace `<ref>` with the action ref you want to run, such as `main` while testing unreleased changes or a versioned ref after release.

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

If GitHub CLI is available, the init command can run `claude setup-token` for you, accept a pasted token, and save the token as the GitHub secret. If GitHub CLI is unavailable or you skip automatic setup, it prints the manual commands.

## Codex Auth

Sign in with Codex:

```bash
codex login --device-auth
```

Then store the Codex auth file as a GitHub Actions secret:

```bash
gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body "$(base64 < ~/.codex/auth.json | tr -d '\n')"
```

If GitHub CLI is available, the init command can use the detected `~/.codex/auth.json`, or let you log in with Codex again and use the new auth file. It then saves the selected auth file as the GitHub secret. If GitHub CLI is unavailable or you skip automatic setup, it prints the manual commands.

## Action Inputs

These are `with:` inputs on `uses: scrimba/pr-explainer@<ref>`.

| Input | Default | Description |
|---|---:|---|
| `agents` | `""` | Comma-separated agents to run, such as `claude,codex`. |
| `agent` | `""` | Singular alias for `agents`, such as `claude`. |
| `pr-number` | `""` | PR number to explain when running manually. |
| `mcp-url` | `https://scrimba.com/explain/mcp` | Scrimba MCP server URL. |
| `allow-forks` | `false` | Set to `true` to allow explainers on fork PRs. |

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

Only enable this for repositories where you trust fork PRs not to execute prompt injections. These explainers are created by your selected agent using PR content, and that agent has access to the checked-out repository and any secrets passed to the job.

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

Test unreleased changes from GitHub:

```bash
npx github:scrimba/pr-explainer init
```

During development, the installer may generate workflows that use `scrimba/pr-explainer@main`. For a stable release, use a versioned action ref such as `scrimba/pr-explainer@v1`.

Publish the npm init command:

```bash
npm login
npm publish --access public
```

After publishing, verify the public installer:

```bash
npx @scrimba/pr-explainer init
```

Publish the GitHub Action ref documented in this README:

```bash
git push origin main
git tag -f <ref>
git push origin <ref> --force
```
