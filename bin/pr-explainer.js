#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import {
  cancel,
  confirm,
  intro,
  isCancel,
  log,
  multiselect,
  note,
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
    child.on("close", () => {
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

function workflowYaml(agents, allowForks) {
  const agentsValue = agents.join(",");
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
      agents:
        description: Override agents for this run, e.g. claude,codex
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
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - name: Create Scrimba PR explainer
        uses: ${ACTION_REF}
        with:
          agents: \${{ inputs.agents || '${agentsValue}' }}
          pr-number: \${{ inputs.pr_number || '' }}
          allow-forks: ${allowForks}
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
  run("gh", ["secret", "set", name], { input: value });
}

function logManualGitHubCommands(agents) {
  let body = "";
  if (agents.includes("claude")) {
    body += `Claude:

 * Get token:
  \`claude setup-token\`

 * Set token:
  \`gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN\``;
  }
  if (agents.includes("codex")) {
    if (body) body += "\n\n";
    body += `Codex:

 * Log in with:
  \`codex login --device-auth\`

 * Set token via:
  \`gh secret set SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 --body "$(base64 < ~/.codex/auth.json | tr -d '\\n')"\``;
  }
  note(body, "GitHub settings");
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
    const token = await runClaudeSetupToken();
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

  if (existsSync(CODEX_AUTH_PATH)) {
    const mode = unwrapPrompt(await select({
      message: "Found Codex authentication at ~/.codex/auth.json. What should we use for GitHub Actions?",
      initialValue: "detected",
      options: [
        { value: "detected", label: "Use the detected Codex auth file" },
        { value: "login", label: "Log in with Codex now" },
      ],
    }));

    if (mode === "detected") {
      return base64File(CODEX_AUTH_PATH);
    }
  } else if (!commandExists("codex")) {
    throw new Error("Codex was selected, but the codex CLI is not installed and ~/.codex/auth.json was not found.");
  } else {
    log.warn("Codex auth was not found at ~/.codex/auth.json.");
  }

  run("codex", ["login", "--device-auth"], { stdio: "inherit" });

  if (!existsSync(CODEX_AUTH_PATH)) {
    throw new Error("Codex auth.json still was not found. Run `codex login --device-auth`, then rerun init.");
  }

  return base64File(CODEX_AUTH_PATH);
}

async function collectAuth(agents, detected) {
  const auth = {};
  if (agents.includes("claude")) {
    auth.claude = await collectClaudeAuth(detected);
  }
  if (agents.includes("codex")) {
    auth.codexAuthB64 = await collectCodexAuth();
  }
  return auth;
}

async function configureGitHub(github, agents, detected) {
  if (!github.available) {
    log.warn(`${github.reason} Skipping automatic GitHub setup.`);
    logManualGitHubCommands(agents);
    return;
  }

  const shouldSet = unwrapPrompt(await confirm({
    message: `Set GitHub secrets on ${github.repo} now?`,
    initialValue: true,
  }));
  if (!shouldSet) {
    log.warn("Skipped GitHub settings.");
    logManualGitHubCommands(agents);
    return;
  }

  const auth = await collectAuth(agents, detected);
  let configured = "";
  const s = spinner();
  try {
    s.start("Setting GitHub repository settings");
    if (agents.includes("claude") && auth.claude?.token) {
      setSecret("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN", auth.claude.token);
      configured += "secret SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN";
    }
    if (agents.includes("codex")) {
      setSecret("SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64", auth.codexAuthB64);
      if (configured) configured += "\n";
      configured += "secret SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64";
    }
    s.clear();
    if (configured) {
      log.success(`GitHub repository ${github.repo} updated:\n${configured}`);
    }
  } catch (error) {
    s.error("Failed to set GitHub repository settings");
    throw error;
  }

  if (agents.includes("claude") && !auth.claude?.token) {
    log.warn("Claude token was not provided, so SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN was not set.");
    log.info("Run this when you have a token:\n  gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
  }
}

async function askAllowForks() {
  note("Fork PRs can contain prompt injection. These explainers are created by your selected agent, using PR content, with access to the checked-out repository. Only enable this if you trust the PRs that will run this workflow.", "Fork PR Safety");
  return unwrapPrompt(await confirm({
    message: "Allow PR explainers to run on fork PRs?",
    initialValue: false,
  }));
}

async function writeWorkflow(agents, allowForks) {
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
  writeFileSync(WORKFLOW_PATH, workflowYaml(agents, allowForks));
  log.success(`Wrote ${WORKFLOW_PATH}`);
  return true;
}

async function init() {
  intro("Scrimba PR Explainer");

  requireGitRepo();

  const github = detectGitHub();
  const detected = detectedAgents();

  note(`This installer adds a GitHub Action that creates Scrimba PR explainer videos.

It can also set up the required GitHub secrets.`);

  let n = []

  if (detected.claudeCli || detected.claudeToken) {
    n.push("  Claude Code.");
  }
  if (detected.codexCli || detected.codexAuth) {
    n.push("  Codex.");
  }

  if (n.length) {
    n.unshift("Detected supported agents locally:");
  }

  if (n.length) {
    log.info(n.join("\n"));
  }

  if (!n.length) {
    log.warn("No supported agents detected locally.");
  }

  const suggested = suggestedAgents(detected);
  const agents = unwrapPrompt(await multiselect({
    message: "Which agent(s) do you want to use?",
    required: true,
    initialValues: [suggested],
    options: [
      {
        value: "claude",
        label: "Claude Code",
      },
      {
        value: "codex",
        label: "Codex",
      },
    ],
  }));

  const allowForks = await askAllowForks();
  await writeWorkflow(agents, allowForks);
  await configureGitHub(github, agents, detected);

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
