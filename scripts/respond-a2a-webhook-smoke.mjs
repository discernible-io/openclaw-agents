#!/usr/bin/env node
/**
 * Deterministic inbound A2A webhook smoke responder (runs inside an agent container).
 *
 * Polls a2a/inbound/tasks/*.json for IDENTYCLAW_SMOKE webhook instructions and
 * executes send_rodit_webhook without relying on the LLM.
 */
import { resolve } from "node:path";
import { respondToA2aWebhookSmoke } from "./lib-a2a-webhook-smoke-responder.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const credPath = resolve(arg("--creds", ""));
const configPath = resolve(arg("--config", "/home/node/.openclaw/openclaw.json"));
const tasksDir = resolve(arg("--tasks-dir", "/home/node/.openclaw/a2a/inbound/tasks"));
const statePath = resolve(arg("--state", "/home/node/.openclaw/cron/a2a-webhook-smoke-state.json"));
const sendScript = resolve(arg("--send-script", "/tmp/send-rodit-webhook.mjs"));
const dryRun = process.argv.includes("--dry-run");

if (!credPath) {
  process.stderr.write(
    "usage: respond-a2a-webhook-smoke.mjs --creds <near.json> " +
      "[--config openclaw.json] [--tasks-dir a2a/inbound/tasks] [--state path] [--dry-run]\n",
  );
  process.exit(2);
}

const { actions, handledCount } = respondToA2aWebhookSmoke({
  credPath,
  configPath,
  tasksDir,
  statePath,
  sendScript,
  dryRun,
  logger: (a) => {
    process.stdout.write(
      `[a2a-webhook-smoke] task=${a.taskId || "?"} peer=${a.peerId} marker=${a.marker} → ` +
        `${a.delivered ? "delivered" : "failed"}${a.detail ? ` (${a.detail.slice(0, 120)})` : ""}\n`,
    );
  },
});

process.stdout.write(
  `[a2a-webhook-smoke] ${actions.length} smoke task(s) seen, ${handledCount} delivered` +
    `${dryRun ? " (dry-run)" : ""}\n`,
);
process.exit(0);
