#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

const WORKFLOW_PATH = ".github/workflows/scrimba-pr-explainer.yml";
const ACTION_REF = "scrimba/pr-explainer@main";
const CODEX_AUTH_PATH = join(homedir(), ".codex", "auth.json");

const colors = {
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
  blue: "\x1b[34m",
  reset: "\x1b[0m",
};

function color(code, text) {
  return output.isTTY ? `${code}${text}${colors.reset}` : text;
}

function title(text) {
  console.log("");
  console.log(color(colors.bold, color(colors.cyan, text)));
}

function description(text) {
  console.log(color(colors.dim, text));
}

function label(text) {
  return color(colors.blue, text);
}

function value(text) {
  return color(colors.green, text);
}

function code(text) {
  return color(colors.yellow, text);
}

function field(name, val) {
  console.log(`  ${label(`${name}:`)} ${val}`);
}

function statusValue(present, presentText = "found", missingText = "not found") {
  return present ? value(presentText) : color(colors.yellow, missingText);
}

function info(text) {
  console.log(`${color(colors.cyan, "[i]")} ${text}`);
}

function ok(text) {
  console.log(`${color(colors.green, "[ok]")} ${text}`);
}

function warn(text) {
  console.log(`${color(colors.yellow, "[!]")} ${text}`);
}

function fail(text) {
  console.log(`${color(colors.red, "[x]")} ${text}`);
}

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

function commandExists(cmd) {
  return spawnSync("sh", ["-c", `command -v ${cmd} >/dev/null 2>&1`]).status === 0;
}

async function ask(question, fallback = "") {
  const rl = readline.createInterface({ input, output });
  const suffix = fallback ? ` ${color(colors.dim, `[default: ${fallback}]`)}` : "";
  const answer = (await rl.question(`${color(colors.cyan, "?")} ${color(colors.bold, question)}${suffix}\n${color(colors.dim, "> ")}`)).trim();
  rl.close();
  return answer || fallback;
}

async function confirm(question, fallback = true) {
  const hint = fallback ? "Y/n" : "y/N";
  const answer = (await ask(`${question} ${color(colors.dim, `[${hint}]`)}`, "")).toLowerCase();
  if (!answer) return fallback;
  return answer === "y" || answer === "yes";
}

async function secretInput(question) {
  if (!input.isTTY) {
    return ask(question);
  }

  output.write(`${color(colors.cyan, "?")} ${color(colors.bold, question)}\n${color(colors.dim, "> ")}`);
  input.setRawMode(true);
  input.resume();
  input.setEncoding("utf8");

  let value = "";
  return await new Promise((resolve) => {
    const onData = (char) => {
      if (char === "\u0003") {
        output.write("\n");
        process.exit(130);
      }
      if (char === "\r" || char === "\n") {
        input.setRawMode(false);
        input.off("data", onData);
        output.write("\n");
        resolve(value.trim());
        return;
      }
      if (char === "\u007f") {
        value = value.slice(0, -1);
        return;
      }
      value += char;
      output.write("*");
    };
    input.on("data", onData);
  });
}

function normalizeAgents(value) {
  const seen = new Set();
  const agents = [];
  for (const raw of value.toLowerCase().replace(/[&;\s]+/g, ",").split(",")) {
    const agent = raw.trim();
    if (!agent) continue;
    if (!["claude", "codex"].includes(agent)) {
      throw new Error(`Unsupported agent "${agent}". Supported agents: claude, codex.`);
    }
    if (!seen.has(agent)) {
      seen.add(agent);
      agents.push(agent);
    }
  }
  if (!agents.length) {
    throw new Error("No agents selected.");
  }
  return agents;
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
  const agents = [];
  if (detected.claudeCli || detected.claudeToken) agents.push("claude");
  if (detected.codexCli || detected.codexAuth) agents.push("codex");
  return agents.length ? agents.join(",") : "claude";
}

function printDetection(detected) {
  title("Detected");
  description("Local tools and auth that can be used to configure the GitHub Action.");
  field("Claude Code CLI", statusValue(detected.claudeCli));
  field("Claude token env", statusValue(detected.claudeToken, "set", "not set"));
  field("Codex CLI", statusValue(detected.codexCli));
  field("Codex auth file", statusValue(detected.codexAuth, "~/.codex/auth.json", "not found"));
}

async function collectClaudeAuth(detected) {
  const envToken = process.env.SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN || process.env.CLAUDE_CODE_OAUTH_TOKEN || "";
  if (envToken) {
    return { token: envToken, source: "environment" };
  }

  title("Claude Setup");
  description("Claude in GitHub Actions needs a Claude Code OAuth token stored as a repository secret.");
  field("Create token", code("claude setup-token"));
  field("GitHub secret", code("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN"));
  console.log("");

  if (detected.claudeCli && await confirm("Run `claude setup-token` now?", true)) {
    run("claude", ["setup-token"], { stdio: "inherit" });
    console.log("");
    description("If Claude printed a token, paste it below so this installer can save it as a GitHub secret.");
  } else if (!detected.claudeCli) {
    warn("Claude Code CLI was not found.");
    description("Install Claude Code or run `claude setup-token` on a machine that has it, then set the GitHub secret.");
  }

  const token = await secretInput("CLAUDE_CODE_OAUTH_TOKEN (leave blank to set it yourself later)");
  if (token) {
    return { token, source: "prompt" };
  }

  warn("Claude selected without a token. The workflow will still be written, but Claude runs need the secret before they can work.");
  return { token: "", source: "manual" };
}

async function collectCodexAuth() {
  const envAuth = process.env.SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64 || process.env.CODEX_AUTH_JSON_B64 || "";
  if (envAuth) {
    return envAuth;
  }

  title("Codex Setup");
  description("Codex in GitHub Actions uses a base64 copy of your local Codex auth file.");
  field("Login command", code("codex login --device-auth"));
  field("Auth file", code("~/.codex/auth.json"));
  if (!existsSync(CODEX_AUTH_PATH)) {
    if (!commandExists("codex")) {
      throw new Error("Codex was selected, but the codex CLI is not installed and ~/.codex/auth.json was not found.");
    }
    warn("Codex auth was not found at ~/.codex/auth.json.");
    if (await confirm("Run `codex login --device-auth` now?", true)) {
      run("codex", ["login", "--device-auth"], { stdio: "inherit" });
    }
  }

  if (!existsSync(CODEX_AUTH_PATH)) {
    throw new Error("Codex auth.json still was not found. Run `codex login --device-auth`, then rerun init.");
  }

  return base64File(CODEX_AUTH_PATH);
}

async function configureGitHub(repo, agents, auth) {
  title("GitHub Repository Settings");
  description("The workflow reads these repository settings at runtime. The installer can set them with GitHub CLI after you confirm.");
  field("Repository", value(repo));
  console.log("");
  console.log(label("Planned settings"));
  field("Variable", code(`SCRIMBA_PR_EXPLAINER_AGENTS=${agents.join(",")}`));
  if (agents.includes("claude") && auth.claude?.token) {
    field("Secret", code("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN"));
  } else if (agents.includes("claude")) {
    field("Manual secret", code("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN"));
  }
  if (agents.includes("codex")) {
    field("Secret", code("SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64"));
  }
  console.log("");

  const shouldSet = await confirm("Set available GitHub secrets and variables now?", true);
  if (!shouldSet) {
    warn("Skipped GitHub settings.");
    console.log("");
    console.log(label("Run these manually"));
    printManualGitHubCommands(agents, auth);
    return;
  }

  setVariable("SCRIMBA_PR_EXPLAINER_AGENTS", agents.join(","));
  ok(`Set variable SCRIMBA_PR_EXPLAINER_AGENTS=${agents.join(",")}`);

  if (agents.includes("claude") && auth.claude?.token) {
    setSecret("SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN", auth.claude.token);
    ok("Set secret SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
  } else if (agents.includes("claude")) {
    warn("Claude token was not provided, so SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN was not set.");
    console.log(label("Run this when you have a token"));
    console.log("  gh secret set SCRIMBA_PR_EXPLAINER_CLAUDE_CODE_OAUTH_TOKEN");
  }
  if (agents.includes("codex")) {
    setSecret("SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64", auth.codexAuthB64);
    ok("Set secret SCRIMBA_PR_EXPLAINER_CODEX_AUTH_JSON_B64");
  }

  if (await confirm("Allow PR explainers to run on fork PRs?", false)) {
    setVariable("SCRIMBA_PR_EXPLAINER_ALLOW_FORKS", "true");
    ok("Set variable SCRIMBA_PR_EXPLAINER_ALLOW_FORKS=true");
  }
}

async function writeWorkflow() {
  title("Workflow");
  description("The workflow file is generated locally. Review it, then commit it when you are ready.");
  field("Path", code(WORKFLOW_PATH));
  if (existsSync(WORKFLOW_PATH)) {
    const overwrite = await confirm(`${WORKFLOW_PATH} already exists. Overwrite?`, false);
    if (!overwrite) {
      warn("Skipped workflow write.");
      return false;
    }
  }

  mkdirSync(dirname(WORKFLOW_PATH), { recursive: true });
  writeFileSync(WORKFLOW_PATH, workflowYaml());
  ok(`Wrote ${WORKFLOW_PATH}`);
  return true;
}

async function init() {
  title("Scrimba PR Explainer");
  description("This adds a GitHub Action that comments on PRs with Scrimba explainer links.");
  field("Agents", `${code("claude")}, ${code("codex")}, or both`);
  field("Action ref", code(ACTION_REF));

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
  printDetection(detected);

  title("Agents");
  description("Choose one or more agents. Multiple agents run in parallel and each gets its own explainer link in the PR comment.");
  field("Supported", `${code("claude")}, ${code("codex")}`);
  field("One agent", code("claude"));
  field("Multiple agents", `${code("claude,codex")} or ${code("claude codex")}`);
  const suggested = suggestedAgents(detected);
  field("Recommended", code(suggested));
  const agents = normalizeAgents(await ask("Agents to run", suggested));
  field("Selected", value(agents.join(",")));

  const auth = {};
  if (agents.includes("claude")) {
    auth.claude = await collectClaudeAuth(detected);
  }
  if (agents.includes("codex")) {
    auth.codexAuthB64 = await collectCodexAuth();
  }

  await configureGitHub(repo, agents, auth);
  await writeWorkflow();

  title("Done");
  description("The installer is finished. It did not commit anything.");
  console.log(label("Next commands"));
  console.log(`  git add ${WORKFLOW_PATH}`);
  console.log('  git commit -m "Add Scrimba PR Explainer"');
  console.log("  git push");
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
  fail(error.message || String(error));
  process.exit(1);
});
