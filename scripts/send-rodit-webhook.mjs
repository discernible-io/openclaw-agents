#!/usr/bin/env node
/**
 * CLI: sign and POST /hooks/wake to an A2A outbound peer after a delay.
 *
 * Usage:
 *   node scripts/send-rodit-webhook.mjs --peer agent-a [--text "ping"] [--delay 10]
 *     [--config /home/node/.openclaw/openclaw.json]
 *
 * Requires NEAR_CREDENTIALS_FILE_PATH (or --creds) and a2a outbound.agents in openclaw.json.
 */
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const peerId = arg("--peer");
const text = arg("--text", "");
const delaySeconds = Number(arg("--delay", "10"));
const hookPath = arg("--path", "hooks/wake");
const configPath = resolve(arg("--config", process.env.OPENCLAW_CONFIG || "/home/node/.openclaw/openclaw.json"));
const credsPath = arg("--creds", process.env.NEAR_CREDENTIALS_FILE_PATH || "");

if (!peerId) {
  process.stderr.write(
    "usage: send-rodit-webhook.mjs --peer <agent-id> [--text msg] [--delay seconds] " +
      "[--path hooks/wake] [--config openclaw.json] [--creds near.json]\n",
  );
  process.exit(2);
}

if (credsPath) {
  process.env.NEAR_CREDENTIALS_FILE_PATH = credsPath;
}

const pluginDir = resolve(arg("--plugin-dir", "/home/node/.openclaw/extensions/identyclaw-webhooks/dist"));
const { sendRoditWebhook } = await import(pathToFileURL(join(pluginDir, "send-rodit-webhook.js")).href);

const config = JSON.parse(readFileSync(configPath, "utf8"));

process.stdout.write(`send_rodit_webhook → peer=${peerId} delay=${delaySeconds}s (waiting…)\n`);

const result = await sendRoditWebhook({
  config,
  peerId,
  text: text || undefined,
  delaySeconds: Number.isFinite(delaySeconds) ? delaySeconds : 10,
  hookPath,
});

process.stdout.write(JSON.stringify(result, null, 2) + "\n");
process.exit(result.ok ? 0 : 1);
