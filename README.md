# Scrimba PR Explainer

Create Scrimba explainers for pull requests from GitHub Actions.

## Quick Start

```bash
cd your-repo
npx @scrimba/pr-explainer init
```

The init command:

- detects the GitHub repo with `gh`
- detects Claude Code and Codex locally
- asks which agents to run
- helps you log in or provide auth, including `claude setup-token` and `codex login --device-auth`
- asks before setting GitHub secrets and variables
- writes `.github/workflows/scrimba-pr-explainer.yml`
- does not commit

## What Gets Installed

The generated workflow uses:

```yaml
uses: scrimba/pr-explainer@v1
```

It runs on PR open, sync, reopen, and ready-for-review. It updates one PR comment as each selected agent starts, posts a live guide URL, skips, finishes, or fails.

## Agents

Set one or more agents:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_AGENTS --body 'claude,codex'
```

Singular forms are aliases for one selected agent:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_AGENT --body claude
```

Manual runs can use either `agents` or `agent`.

## Secrets

Claude:

```bash
claude setup-token
gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN --body "$CLAUDE_CODE_OAUTH_TOKEN"
```

You can also skip Claude secret setup during `init` and set this yourself later.

Codex:

```bash
gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body "$(base64 < ~/.codex/auth.json | tr -d '\n')"
```

## Fork PRs

Fork PRs are skipped by default. To opt in:

```bash
gh variable set SCRIMBA_PR_EXPLAINER_ALLOW_FORKS --body true
```

Only enable this if you understand that PR-controlled code and prompts can influence agents that have access to job secrets.
