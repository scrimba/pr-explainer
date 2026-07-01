#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import {
  cancel,
  confirm,
  intro,
  isCancel,
  log,
  multiselect,
  outro,
  password,
  select,
  spinner,
} from "@clack/prompts";

const WORKFLOW_PATH = ".github/workflows/scrimba-pr-explainer.yml";
const ACTION_REF = "scrimba/pr-explainer@main";
const CODEX_AUTH_PATH = join(homedir(), ".codex", "auth.json");

function run(cmd, args, options = {}) {
  const res = spawnSync(cmd, args, {
    encoding: "utf8",
    stdio: options.stdio ?? "pipe",
    input: options.input,
  });
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
  const res = spawnSync("claude", ["setup-token"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  const output = `${res.stdout || ""}\n${res.stderr || ""}`;
  const token = extractClaudeToken(output);
  if (token) return token;
  if (res.error || res.status !== 0) {
    return "";
  }
  return "";
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

concurrency:
  group: scrimba-pr-explainer-\${{ github.event.pull_request.number || github.event.inputs.pr_number || github.ref }}
  cancel-in-progress: true

jobs:
  explain:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository || vars.SCRIMBA_PR_EXPLAINER_ALLOW_FORKS == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - name: Resolve checkout ref
        id: checkout-ref
        env:
          PR_NUMBER: \${{ github.event.inputs.pr_number || '' }}
        run: |
          if [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
            echo "ref=refs/pull/\${{ github.event.pull_request.number }}/merge" >> "$GITHUB_OUTPUT"
          elif [ -n "$PR_NUMBER" ]; then
            echo "ref=refs/pull/$PR_NUMBER/merge" >> "$GITHUB_OUTPUT"
          else
            echo "ref=$GITHUB_REF" >> "$GITHUB_OUTPUT"
          fi

      - name: Checkout
        uses: actions/checkout@v6
        with:
          fetch-depth: 0
          persist-credentials: false
          ref: \${{ steps.checkout-ref.outputs.ref }}

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: 22

      - name: Create Scrimba PR explainer
        uses: ${ACTION_REF}
        with:
          agents: \${{ github.event.inputs.agents || github.event.inputs.agent || vars.SCRIMBA_PR_EXPLAINER_AGENTS || vars.SCRIMBA_PR_EXPLAINER_AGENT }}
          pr-number: \${{ github.event.inputs.pr_number || '' }}
          mcp-url: \${{ vars.SCRIMBA_PR_EXPLAINER_MCP_URL || 'https://scrimba.com/explain/mcp' }}
        env:
          GH_TOKEN: \${{ github.token }}
          SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN: \${{ secrets.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN }}
          SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64: \${{ secrets.SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 }}
`;
}

function base64File(path) {
  return readFileSync(path).toString("base64");
}

function setSecret(name, value) {
  run("gh", ["secret", "set", name], { input: `${value}\n` });
}

function setVariable(name, value) {
  run("gh", ["variable", "set", name, "--body", value]);
}

function printManualGitHubCommands(agents, auth) {
  console.log(`  gh variable set SCRIMBA_PR_EXPLAINER_AGENTS --body '${agents.join(",")}'`);
  if (agents.includes("claude")) {
    if (!auth.claude?.token) {
      console.log("  claude setup-token");
    }
    console.log("  gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
  }
  if (agents.includes("codex")) {
    console.log("  gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body \"$(base64 < ~/.codex/auth.json | tr -d '\\n')\"");
  }
}

function detectRepo() {
  try {
    run("git", ["rev-parse", "--show-toplevel"]);
    return run("gh", ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
  } catch {
    throw new Error("Run init from inside a GitHub repository that `gh repo view` can resolve.");
  }
}

function detectedAgents() {
  const claudeCli = commandExists("claude");
  const codexCli = commandExists("codex");
  const codexAuth = existsSync(CODEX_AUTH_PATH);
  const claudeToken = Boolean(process.env.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN || process.env.CLAUDE_CODE_OAUTH_TOKEN);
  return { claudeCli, codexCli, codexAuth, claudeToken };
}

function suggestedAgents(detected) {
  if (detected.claudeCli || detected.claudeToken) return "claude";
  if (detected.codexCli || detected.codexAuth) return "codex";
  return "claude";
}

function detectedAgentNames(detected) {
  const found = [];
  if (detected.claudeCli || detected.claudeToken) found.push("claude");
  if (detected.codexCli || detected.codexAuth) found.push("codex");
  return found;
}

async function collectClaudeAuth(detected) {
  const envToken = process.env.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN || process.env.CLAUDE_CODE_OAUTH_TOKEN || "";
  if (envToken) {
    return { token: envToken, source: "environment" };
  }

  let mode = "provide";
  if (detected.claudeCli) {
    mode = unwrapPrompt(await select({
      message: "Claude needs an OAuth token in GitHub Actions. How should we get it?",
      initialValue: "setup",
      options: [
        { value: "setup", label: "Get token via Claude Code" },
        { value: "provide", label: "I will provide a token" },
      ],
    }));
  } else {
    log.warn("Claude Code CLI was not found. Paste a token you already have, or rerun this after installing Claude Code.");
  }

  if (mode === "setup") {
    const s = spinner();
    s.start("Getting Claude token");
    const token = runClaudeSetupToken();
    if (token) {
      s.stop("Claude token created");
      return { token, source: "setup-token" };
    }
    s.error("Could not read a token from Claude Code");
    log.warn("Run `claude setup-token` yourself, then paste the token below.");
  }

  const token = unwrapPrompt(await password({
    message: "Claude token",
    mask: "*",
  })).trim();
  if (token) {
    return { token, source: "prompt" };
  }

  log.warn("Claude selected without a token. The workflow will still be written, but Claude runs need the secret before they can work.");
  return { token: "", source: "manual" };
}

async function collectCodexAuth() {
  const envAuth = process.env.SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 || process.env.CODEX_AUTH_JSON_B64 || "";
  if (envAuth) {
    return envAuth;
  }

  if (!existsSync(CODEX_AUTH_PATH)) {
    if (!commandExists("codex")) {
      throw new Error("Codex was selected, but the codex CLI is not installed and ~/.codex/auth.json was not found.");
    }
    log.warn("Codex auth was not found at ~/.codex/auth.json.");
    const shouldLogin = unwrapPrompt(await confirm({
      message: "Run `codex login --device-auth` now?",
      initialValue: true,
    }));
    if (shouldLogin) {
      run("codex", ["login", "--device-auth"], { stdio: "inherit" });
    }
  }

  if (!existsSync(CODEX_AUTH_PATH)) {
    throw new Error("Codex auth.json still was not found. Run `codex login --device-auth`, then rerun init.");
  }

  return base64File(CODEX_AUTH_PATH);
}

async function configureGitHub(repo, agents, auth) {
  const shouldSet = unwrapPrompt(await confirm({
    message: `Set GitHub secrets and variables on ${repo} now?`,
    initialValue: true,
  }));
  if (!shouldSet) {
    log.warn("Skipped GitHub settings.");
    console.log("");
    log.info("Run these manually:");
    printManualGitHubCommands(agents, auth);
    return;
  }

  const s = spinner();
  s.start("Setting GitHub repository settings");
  try {
    setVariable("SCRIMBA_PR_EXPLAINER_AGENTS", agents.join(","));
    if (agents.includes("claude") && auth.claude?.token) {
      setSecret("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN", auth.claude.token);
    }
    if (agents.includes("codex")) {
      setSecret("SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64", auth.codexAuthB64);
    }
    s.stop("GitHub repository settings updated");
  } catch (error) {
    s.error("Failed to set GitHub repository settings");
    throw error;
  }

  if (agents.includes("claude") && !auth.claude?.token) {
    log.warn("Claude token was not provided, so SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN was not set.");
    log.info("Run this when you have a token:\n  gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
  }

  const allowForks = unwrapPrompt(await confirm({
    message: "Allow PR explainers to run on fork PRs?",
    initialValue: false,
  }));
  if (allowForks) {
    setVariable("SCRIMBA_PR_EXPLAINER_ALLOW_FORKS", "true");
    log.success("Set variable SCRIMBA_PR_EXPLAINER_ALLOW_FORKS=true");
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
  intro("Scrimba PR Explainer");

  if (!commandExists("git")) {
    throw new Error("git is required. Run init from a local checkout of the repository.");
  }
  if (!commandExists("gh")) {
    throw new Error("GitHub CLI is required. Install gh and authenticate with `gh auth login`.");
  }
  try {
    run("gh", ["auth", "status"]);
  } catch {
    throw new Error("GitHub CLI is installed but not authenticated. Run `gh auth login`, then rerun init.");
  }

  const repo = detectRepo();
  const detected = detectedAgents();
  const detectedNames = detectedAgentNames(detected);
  log.info([
    "Installs a PR explainer workflow.",
    "Detected:",
    ...(detectedNames.length ? detectedNames.map((agent) => `  ${agent}`) : ["  none"]),
    "Subscription required.",
  ].join("\n"));

  const suggested = suggestedAgents(detected);
  const agents = unwrapPrompt(await multiselect({
    message: "Which agent(s) do you want to use?",
    required: true,
    initialValues: [suggested],
    options: [
      {
        value: "claude",
        label: "Claude Code",
        hint: detected.claudeCli || detected.claudeToken ? "available" : "token required",
      },
      {
        value: "codex",
        label: "Codex",
        hint: detected.codexCli || detected.codexAuth ? "available" : "auth required",
      },
    ],
  }));

  const auth = {};
  if (agents.includes("claude")) {
    auth.claude = await collectClaudeAuth(detected);
  }
  if (agents.includes("codex")) {
    auth.codexAuthB64 = await collectCodexAuth();
  }

  await configureGitHub(repo, agents, auth);
  await writeWorkflow();

  log.info(`Next:\n  git add ${WORKFLOW_PATH}\n  git commit -m "Add Scrimba PR Explainer"\n  git push`);
  outro("Done. No files were committed.");
}

async function main() {
  const [command] = process.argv.slice(2);
  if (!command || command === "help" || command === "--help" || command === "-h") {
    console.log("Usage: npx @scrimba/pr-explainer init");
    return;
  }
  if (command !== "init") {
    throw new Error(`Unknown command "${command}". Expected: init`);
  }
  await init();
}

main().catch((error) => {
  log.error(error.message || String(error));
  process.exit(1);
});
