#!/usr/bin/env node
/**
 * Deterministic inbound A2A email HOLA smoke responder (runs inside an agent container).
 *
 * Polls a2a/inbound/tasks/*.json for IDENTYCLAW_SMOKE HOLA email instructions and
 * sends the probe via himalaya without relying on the LLM.
 */
import { resolve } from "node:path";
import { respondToA2aHolaSmoke } from "./lib-a2a-hola-smoke-responder.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const credPath = resolve(arg("--creds", ""));
const extDir = resolve(arg("--ext-dir", "/home/node/.openclaw/extensions/identyclaw-a2a"));
const tasksDir = resolve(arg("--tasks-dir", "/home/node/.openclaw/a2a/inbound/tasks"));
const statePath = resolve(arg("--state", "/home/node/.openclaw/cron/a2a-hola-smoke-state.json"));
const fromEmail = arg("--from-email", "");
const fromName = arg("--from-name", fromEmail);
const ownTokenId = arg("--own-token-id", "");
const dryRun = process.argv.includes("--dry-run");

if (!credPath || !fromEmail) {
  process.stderr.write(
    "usage: respond-a2a-hola-smoke.mjs --creds <near.json> --from-email <addr> " +
      "[--from-name <name>] [--own-token-id <id>] [--ext-dir path] [--tasks-dir path] [--state path] [--dry-run]\n",
  );
  process.exit(2);
}

const { actions, handledCount } = await respondToA2aHolaSmoke({
  credPath,
  extDir,
  tasksDir,
  statePath,
  fromEmail,
  fromName,
  ownTokenId,
  dryRun,
  logger: (a) => {
    process.stdout.write(
      `[a2a-hola-smoke] task=${a.taskId || "?"} to=${a.toEmail} subject=${a.subject} → ` +
        `${a.delivered ? "sent" : "failed"}${a.detail ? ` (${a.detail.slice(0, 120)})` : ""}\n`,
    );
  },
});

process.stdout.write(
  `[a2a-hola-smoke] ${actions.length} smoke task(s) seen, ${handledCount} sent` +
    `${dryRun ? " (dry-run)" : ""}\n`,
);
process.exit(0);
