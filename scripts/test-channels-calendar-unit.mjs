#!/usr/bin/env node
/**
 * Unit tests: Telegram/Discord channel wiring + local calendar/reminders.
 *
 * Run: node scripts/test-channels-calendar-unit.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const tally = createTally();
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

function bashLib(script, env = {}) {
  const result = spawnSync(
    "bash",
    ["-c", `source "${repoRoot}/scripts/lib.sh"\n${script}`],
    {
      encoding: "utf8",
      env: { ...process.env, ...env },
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `bash exited ${result.status}: ${(result.stderr || result.stdout || "").trim()}`,
    );
  }
  return (result.stdout || "").trim();
}

function writeMinimalOpenclaw(dir) {
  mkdirSync(join(dir, "secrets"), { recursive: true });
  mkdirSync(join(dir, "workspace"), { recursive: true });
  writeFileSync(
    join(dir, "openclaw.json"),
    JSON.stringify({ gateway: { port: 18789 }, channels: {} }, null, 2) + "\n",
  );
  chmodSync(join(dir, "openclaw.json"), 0o600);
}

process.stdout.write("Telegram / Discord / calendar (unit)\n\n");

runCase("agent_telegram_webhook_port is gateway + 2 in pod mode", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  try {
    writeFileSync(
      join(app, "env.local"),
      ["IDENTYCLAW_DEPLOY_MODE=pod", "AGENT_IDS=agent-a agent-l"].join("\n") + "\n",
    );
    const a = bashLib("agent_telegram_webhook_port agent-a", {
      IDENTYCLAW_APP_DIR: app,
      IDENTYCLAW_DEPLOY_MODE: "pod",
    });
    const l = bashLib("agent_telegram_webhook_port agent-l", {
      IDENTYCLAW_APP_DIR: app,
      IDENTYCLAW_DEPLOY_MODE: "pod",
    });
    assert.equal(a, "18791");
    assert.equal(l, "18813");
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("write_telegram_token enables channel via tokenFile (not botToken in json)", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    bashLib(`write_telegram_token "${dir}" "123456:TEST-TOKEN"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    const token = readFileSync(join(dir, "secrets", "TELEGRAM_BOT_TOKEN"), "utf8");
    assert.equal(token, "123456:TEST-TOKEN");
    const env = readFileSync(join(dir, ".env"), "utf8");
    assert.equal(env.includes("TELEGRAM_BOT_TOKEN=123456:TEST-TOKEN"), true);
    const cfg = JSON.parse(readFileSync(join(dir, "openclaw.json"), "utf8"));
    assert.equal(cfg.channels.telegram.enabled, true);
    assert.equal(
      cfg.channels.telegram.tokenFile,
      "/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN",
    );
    assert.equal(JSON.stringify(cfg).includes("123456:TEST-TOKEN"), false);
    assert.equal(cfg.channels.telegram.dmPolicy, "pairing");
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("write_telegram_token skips host mkdir when secrets are not writable", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    chmodSync(join(dir, "secrets"), 0o555);
    chmodSync(dir, 0o555);
    const result = spawnSync(
      "bash",
      [
        "-c",
        `source "${repoRoot}/scripts/lib.sh"\nwrite_telegram_token "${dir}" "123456:TEST-TOKEN" openclaw-missing-test-container`,
      ],
      {
        encoding: "utf8",
        env: { ...process.env, IDENTYCLAW_APP_DIR: app },
      },
    );
    assert.notEqual(result.status, 0);
    assert.match(
      `${result.stderr || ""}\n${result.stdout || ""}`,
      /not writable/,
    );
  } finally {
    chmodSync(join(dir, "secrets"), 0o755);
    chmodSync(dir, 0o755);
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("ensure_telegram_ready disables channel when token is missing", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    writeFileSync(
      join(dir, "openclaw.json"),
      JSON.stringify(
        { channels: { telegram: { enabled: true, botToken: "stale" } } },
        null,
        2,
      ) + "\n",
    );
    bashLib(`ensure_telegram_ready agent-a "${dir}"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    const cfg = JSON.parse(readFileSync(join(dir, "openclaw.json"), "utf8"));
    assert.equal(cfg.channels.telegram.enabled, false);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("ensure_telegram_webhook sets unique listener in pod mode", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeFileSync(
      join(app, "env.local"),
      [
        "IDENTYCLAW_DEPLOY_MODE=pod",
        "IDENTYCLAW_INGRESS_PORT=8443",
        "AGENT_IDS=agent-a",
        "AGENT_A_PUBLIC_HOST=agent-a.identyclaw.com",
        "AGENT_A_GATEWAY_PORT=18789",
      ].join("\n") + "\n",
    );
    writeMinimalOpenclaw(dir);
    bashLib(
      `write_telegram_token "${dir}" "123456:TEST-TOKEN"\nensure_telegram_webhook agent-a "${dir}"`,
      { IDENTYCLAW_APP_DIR: app, IDENTYCLAW_DEPLOY_MODE: "pod" },
    );
    const cfg = JSON.parse(readFileSync(join(dir, "openclaw.json"), "utf8"));
    assert.equal(
      cfg.channels.telegram.webhookUrl,
      "https://agent-a.identyclaw.com:8443/telegram-webhook",
    );
    assert.equal(cfg.channels.telegram.webhookPath, "/telegram-webhook");
    assert.equal(cfg.channels.telegram.webhookHost, "127.0.0.1");
    assert.equal(cfg.channels.telegram.webhookPort, 18791);
    assert.equal(typeof cfg.channels.telegram.webhookSecret, "string");
    assert.ok(cfg.channels.telegram.webhookSecret.length >= 16);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("ensure_telegram_webhook uses long polling in standalone", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    bashLib(
      `write_telegram_token "${dir}" "123456:TEST-TOKEN"\nensure_telegram_webhook agent-a "${dir}"`,
      { IDENTYCLAW_APP_DIR: app, IDENTYCLAW_DEPLOY_MODE: "standalone" },
    );
    const cfg = JSON.parse(readFileSync(join(dir, "openclaw.json"), "utf8"));
    assert.equal(cfg.channels.telegram.webhookUrl, undefined);
    assert.equal(cfg.channels.telegram.webhookPort, undefined);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("write_discord_token still enables Discord from secrets", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    bashLib(`write_discord_token "${dir}" "discord-test-token"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    assert.equal(
      readFileSync(join(dir, "secrets", "DISCORD_BOT_TOKEN"), "utf8"),
      "discord-test-token",
    );
    const cfg = JSON.parse(readFileSync(join(dir, "openclaw.json"), "utf8"));
    assert.equal(cfg.channels.discord.enabled, true);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("write_calendar_tooling installs skill, helper, and CALENDAR.md", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    writeMinimalOpenclaw(dir);
    bashLib(`write_calendar_tooling "${dir}"`, { IDENTYCLAW_APP_DIR: app });
    assert.equal(
      readFileSync(join(dir, "workspace", "skills", "calendar-reminders", "SKILL.md"), "utf8").includes(
        "calendar.sh",
      ),
      true,
    );
    assert.equal(
      readFileSync(join(dir, "workspace", "CALENDAR.md"), "utf8").includes("automations"),
      true,
    );
    const helper = join(dir, "workspace", "scripts", "calendar.sh");
    const add = spawnSync(
      "sh",
      [helper, "add", "--title", "Standup with spaces", "--at", "2099-01-01T09:00:00Z", "--remind", "10"],
      { encoding: "utf8", env: { ...process.env, OPENCLAW_HOME: dir } },
    );
    assert.equal(add.status, 0, add.stderr || add.stdout);
    const created = JSON.parse(add.stdout);
    assert.equal(created.title, "Standup with spaces");
    assert.equal(created.status, "active");
    const list = spawnSync("sh", [helper, "list"], {
      encoding: "utf8",
      env: { ...process.env, OPENCLAW_HOME: dir },
    });
    assert.equal(list.status, 0, list.stderr || list.stdout);
    const listed = JSON.parse(list.stdout);
    assert.equal(listed.count, 1);
    assert.equal(listed.events[0].id, created.id);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("rendered nginx proxies Telegram to the per-agent webhook listener", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  try {
    writeFileSync(
      join(app, "env.local"),
      [
        "IDENTYCLAW_DEPLOY_MODE=pod",
        "IDENTYCLAW_INGRESS_PORT=8443",
        "AGENT_IDS=agent-l",
        "AGENT_L_A2A_PUBLIC_BASE_URL=https://identyclaw-concierge.identyclaw.com:8443",
        "AGENT_L_GATEWAY_PORT=18789",
      ].join("\n") + "\n",
    );
    bashLib("prepare_pod_nginx_host_files", {
      IDENTYCLAW_APP_DIR: app,
      IDENTYCLAW_DEPLOY_MODE: "pod",
      REPO_ROOT: repoRoot,
    });
    const conf = readFileSync(join(app, "nginx", "nginx.conf"), "utf8");
    assert.equal(conf.includes("upstream openclaw_agent_l_telegram"), true);
    assert.equal(conf.includes("127.0.0.1:18813"), true);
    assert.equal(conf.includes("proxy_pass http://openclaw_agent_l_telegram;"), true);
    const telegramBlock = conf.split("location = /telegram-webhook")[1]?.split("location ")[0] || "";
    assert.equal(telegramBlock.includes("proxy_pass http://openclaw_agent_l;"), false);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("container-entrypoint retires leftover exec-approvals.json before the gateway starts", () => {
  const src = readFileSync(join(repoRoot, "scripts/container-entrypoint.sh"), "utf8");
  const image = readFileSync(join(repoRoot, "Containerfile.agent"), "utf8");
  assert.equal(src.includes("/home/node/.openclaw/exec-approvals.json"), true);
  assert.equal(src.includes("exec-approvals.json.identyclaw-retired"), true);
  assert.ok(
    src.indexOf("exec-approvals.json") < src.indexOf('exec tini -s -- "$@"'),
    "entrypoint must retire leftover JSON before exec tini",
  );
  assert.equal(image.includes("scripts/container-entrypoint.sh"), true);
});

runCase("container-entrypoint re-applies model routing from openclaw.json", () => {
  const src = readFileSync(join(repoRoot, "scripts/container-entrypoint.sh"), "utf8");
  const image = readFileSync(join(repoRoot, "Containerfile.agent"), "utf8");
  assert.equal(src.includes("/opt/identyclaw/patch-openclaw-model-routing.py"), true);
  assert.equal(src.includes("/home/node/.openclaw/openclaw.json"), true);
  assert.ok(
    src.indexOf("patch-openclaw-model-routing.py") < src.indexOf('exec tini -s -- "$@"'),
    "entrypoint must apply model routing before exec tini",
  );
  assert.equal(image.includes("scripts/lib-openclaw-model-routing.py"), true);
  assert.equal(image.includes("scripts/patch-openclaw-model-routing.py"), true);
  assert.equal(image.includes("/opt/identyclaw/lib-openclaw-model-routing.py"), true);
  assert.equal(image.includes("/opt/identyclaw/patch-openclaw-model-routing.py"), true);
});

runCase("container-entrypoint re-applies OpenRouter cache config after model routing", () => {
  const src = readFileSync(join(repoRoot, "scripts/container-entrypoint.sh"), "utf8");
  const image = readFileSync(join(repoRoot, "Containerfile.agent"), "utf8");
  assert.equal(src.includes("/opt/identyclaw/patch-openclaw-cache-config.mjs"), true);
  assert.ok(
    src.indexOf("patch-openclaw-model-routing.py") <
      src.indexOf("patch-openclaw-cache-config.mjs"),
    "cache config must run after model-routing so sticky session_id survives",
  );
  assert.ok(
    src.indexOf("patch-openclaw-cache-config.mjs") < src.indexOf('exec tini -s -- "$@"'),
    "entrypoint must apply cache config before exec tini",
  );
  assert.equal(image.includes("scripts/lib-openclaw-cache-config.mjs"), true);
  assert.equal(image.includes("scripts/patch-openclaw-cache-config.mjs"), true);
  assert.equal(image.includes("/opt/identyclaw/lib-openclaw-cache-config.mjs"), true);
  assert.equal(image.includes("/opt/identyclaw/patch-openclaw-cache-config.mjs"), true);
});

runCase("ensure_exec_allowlist retires leftover JSON inside the container even when the host cannot see it", () => {
  const src = readFileSync(join(repoRoot, "scripts/lib-agent-config.sh"), "utf8");
  const start = src.indexOf("ensure_exec_allowlist_harmless_bins()");
  const end = src.indexOf("retire_legacy_exec_approvals_one()");
  assert.ok(start >= 0 && end > start, "ensure_exec_allowlist_harmless_bins body not found");
  const body = src.slice(start, end);
  assert.equal(body.includes("_retire_legacy_exec_approvals_in_container"), true);
  assert.equal(body.includes("_retire_legacy_exec_approvals_json"), true);
  assert.ok(
    body.indexOf("_retire_legacy_exec_approvals_in_container") <
      body.indexOf("_retire_legacy_exec_approvals_json"),
    "must retire in-container before any host-path Python when a container exists",
  );
});

runCase("ensure_exec_allowlist_harmless_bins retires leftover JSON and does not recreate it", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const dir = join(app, "agents", "agent-a");
  try {
    mkdirSync(join(dir, "state"), { recursive: true });
    writeFileSync(
      join(dir, "exec-approvals.json"),
      JSON.stringify({ version: 1, agents: { main: { allowlist: [] } } }, null, 2) + "\n",
    );
    writeFileSync(join(dir, "state", "openclaw.sqlite"), "");
    bashLib(`ensure_exec_allowlist_harmless_bins "${dir}"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    assert.equal(existsSync(join(dir, "exec-approvals.json")), false);
    assert.equal(existsSync(join(dir, "exec-approvals.json.identyclaw-retired")), true);
    bashLib(`ensure_exec_allowlist_harmless_bins "${dir}"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    assert.equal(existsSync(join(dir, "exec-approvals.json")), false);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
