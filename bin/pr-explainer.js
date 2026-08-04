#!/usr/bin/env node
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import {
  cancel,
  confirm,
  intro,
  isCancel,
  log,
  note,
  outro,
  password,
  spinner,
} from "@clack/prompts";

const WORKFLOW_PATH = ".github/workflows/scrimba-pr-explainer.yml";
const ACTION_REF = "scrimba/pr-explainer@main";

function exitOnInterrupt() {
  cancel("Installation cancelled.");
  process.exit(130);
}

function run(cmd, args, options = {}) {
  const res = spawnSync(cmd, args, {
    encoding: "utf8",
    stdio: options.stdio ?? "pipe",
    input: options.input,
  });
  if (res.signal === "SIGINT" || res.signal === "SIGTERM") {
    exitOnInterrupt();
  }
  if (res.error) {
    throw res.error;
  }
  if (res.status !== 0) {
    const detail = (res.stderr || res.stdout || "").trim();
    throw new Error(`${cmd} ${args.join(" ")} failed${detail ? `:\n${detail}` : ""}`);
  }
  return (res.stdout || "").trim();
}

function runClaudeSetupToken() {
  return new Promise((resolve) => {
    const child = spawn("claude", ["setup-token"], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";

    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      output += chunk;
    });
    child.stderr?.on("data", (chunk) => {
      output += chunk;
    });
    child.on("error", () => {
      resolve("");
    });
    child.on("close", (code, signal) => {
      // Ctrl+C lands on the child while it owns the terminal; treat it as
      // the user cancelling the whole install, not a failed token attempt.
      if (signal === "SIGINT" || signal === "SIGTERM" || code === 130) {
        exitOnInterrupt();
      }
      resolve(extractClaudeToken(output));
    });
  });
}

function extractClaudeToken(output) {
  const lines = output.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line.startsWith("sk-ant-oat")) continue;

    let token = line;
    for (let j = i + 1; j < lines.length; j += 1) {
      const part = lines[j].trim();
      if (!part) break;
      if (!/^[A-Za-z0-9_-]+$/.test(part)) break;
      token += part;
    }

    if (/^sk-ant-oat\d+-[A-Za-z0-9_-]+$/.test(token)) return token;
  }
  return "";
}

function commandExists(cmd) {
  return spawnSync("sh", ["-c", `command -v ${cmd} >/dev/null 2>&1`]).status === 0;
}

function unwrapPrompt(value) {
  if (isCancel(value)) {
    cancel("Installation cancelled.");
    process.exit(0);
  }
  return value;
}

function workflowYaml() {
  return `name: Scrimba PR Explainer

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
  group: scrimba-pr-explainer-\${{ github.event.pull_request.number || inputs.pr_number || github.ref }}
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
        uses: ${ACTION_REF}
        with:
          # allow-forks stays false because fork PRs can contain prompt
          # injection: the agent that builds the explainer reads PR content
          # with access to the checked-out repository and any secrets passed
          # to this job. Only set it to true if you trust every fork PR that
          # can reach this workflow.
          allow-forks: false
          pr-number: \${{ inputs.pr_number || '' }}
        env:
          GH_TOKEN: \${{ github.token }}
          SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN: \${{ secrets.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN }}
`;
}

function setSecret(name, value) {
  run("gh", ["secret", "set", name], { input: value });
}

function logManualGitHubCommands() {
  note(`Get a token:
  \`claude setup-token\`

Set it as the GitHub secret:
  \`gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN\``, "GitHub settings");
}

function requireGitRepo() {
  if (!commandExists("git")) {
    throw new Error("git is required. Run init from a local checkout of the repository.");
  }
  try {
    run("git", ["rev-parse", "--is-inside-work-tree"]);
  } catch {
    throw new Error("Run init from inside a git repository.");
  }
}

function detectGitHub() {
  if (!commandExists("gh")) {
    return { available: false, repo: "", reason: "GitHub CLI was not found." };
  }
  try {
    run("gh", ["auth", "status"]);
  } catch {
    return { available: false, repo: "", reason: "GitHub CLI is not authenticated." };
  }
  try {
    const repo = run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
    return { available: true, repo, reason: "" };
  } catch {
    return { available: false, repo: "", reason: "GitHub CLI could not resolve this repository." };
  }
}

async function collectClaudeAuth() {
  const envToken = process.env.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN || process.env.CLAUDE_CODE_OAUTH_TOKEN || "";
  if (envToken) {
    return { token: envToken, source: "environment" };
  }

  if (commandExists("claude")) {
    const s = spinner();
    s.start("Getting a Claude token via `claude setup-token`");
    const token = await runClaudeSetupToken();
    if (token) {
      s.stop("Claude token created");
      return { token, source: "setup-token" };
    }
    s.error("Could not read a token from Claude Code");
    log.warn("Run `claude setup-token` yourself, then paste the token below.");
  } else {
    log.warn("Claude Code CLI was not found. Paste a token you already have, or rerun this after installing Claude Code.");
  }

  const token = unwrapPrompt(await password({
    message: "Claude token",
    mask: "*",
  })).trim();
  if (token) {
    return { token, source: "prompt" };
  }

  log.warn("No token provided. The workflow will still be written, but runs need the secret before they can work.");
  return { token: "", source: "manual" };
}

async function configureGitHub(github) {
  if (!github.available) {
    log.warn(`${github.reason} Skipping automatic GitHub setup.`);
    logManualGitHubCommands();
    return;
  }

  const shouldSet = unwrapPrompt(await confirm({
    message: `Set the Claude token secret on ${github.repo} now?`,
    initialValue: true,
  }));
  if (!shouldSet) {
    log.warn("Skipped GitHub settings.");
    logManualGitHubCommands();
    return;
  }

  const auth = await collectClaudeAuth();
  if (!auth.token) {
    log.warn("Claude token was not provided, so SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN was not set.");
    log.info("Run this when you have a token:\n  gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
    return;
  }

  const s = spinner();
  try {
    s.start("Setting the GitHub repository secret");
    setSecret("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN", auth.token);
    s.clear();
    log.success(`GitHub repository ${github.repo} updated:\nsecret SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN`);
  } catch (error) {
    s.error("Failed to set the GitHub repository secret");
    throw error;
  }
}

async function writeWorkflow() {
  if (existsSync(WORKFLOW_PATH)) {
    const overwrite = unwrapPrompt(await confirm({
      message: `${WORKFLOW_PATH} already exists. Overwrite?`,
      initialValue: false,
    }));
    if (!overwrite) {
      log.warn("Skipped workflow write.");
      return false;
    }
  }

  mkdirSync(dirname(WORKFLOW_PATH), { recursive: true });
  writeFileSync(WORKFLOW_PATH, workflowYaml());
  log.success(`Wrote ${WORKFLOW_PATH}`);
  return true;
}

async function init() {
  process.on("SIGINT", exitOnInterrupt);
  process.on("SIGTERM", exitOnInterrupt);

  intro("Scrimba PR Explainer");

  requireGitRepo();

  const github = detectGitHub();

  note(`This installer adds a GitHub Action that creates a Scrimba explainer video for each pull request, using Claude Code.

It can also set up the required GitHub secret.`);

  await writeWorkflow();
  await configureGitHub(github);

  log.info(`Next:\n  git add ${WORKFLOW_PATH}\n  git commit -m "Add Scrimba PR Explainer"\n  git push`);
  outro("Done. No files were committed.");
}

async function main() {
  const [command] = process.argv.slice(2);
  if (command === "help" || command === "--help" || command === "-h") {
    console.log("Usage: npx pr-explainer [init]");
    return;
  }
  if (command && command !== "init") {
    throw new Error(`Unknown command "${command}". Expected: init`);
  }
  await init();
}

main().catch((error) => {
  log.error(error.message || String(error));
  process.exit(1);
});
