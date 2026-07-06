#!/usr/bin/env node
/**
 * A2A messaging E2E: message/send → tasks/get on a live peer gateway.
 * Uses rodit-auth-be only as a black box for P2P JWT (already tested upstream).
 *
 * Usage:
 *   node scripts/test-a2a-messaging-e2e.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /path/to/near.json \
 *     --peer-base https://peer.example:7443 \
 *     [--marker-prefix a2a-messaging]
 */
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { applyNearRoditEnv, parseNearCreds } from "./lib-rodit-env.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const peerBase = (arg("--peer-base", "") || "").replace(/\/$/, "");
const markerPrefix = arg("--marker-prefix", "a2a-messaging");
const pollTimeoutMs = Number(arg("--poll-timeout-ms", "60000")) || 60000;
const pollIntervalMs = Number(arg("--poll-interval-ms", "2000")) || 2000;

if (!extDir || !credPath || !peerBase) {
  process.stderr.write(
    "usage: test-a2a-messaging-e2e.mjs --ext-dir <a2a-plugin> --creds <near.json> --peer-base <base-url>\n",
  );
  process.exit(2);
}

applyNearRoditEnv(parseNearCreds(credPath));

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient, login_server } = require("@rodit/rodit-auth-be");

const tally = createTally();
const marker = `${markerPrefix}-${Date.now()}`;

async function getOwnConfig() {
  const client = await RoditClient.create({ role: "client" });
  return client.getConfigOwnRodit();
}

async function p2pJwt(targetBase) {
  const ownConfig = await getOwnConfig();
  const base = targetBase.replace(/\/$/, "");
  const cfg = {
    ...ownConfig,
    own_rodit: {
      ...ownConfig.own_rodit,
      metadata: {
        ...ownConfig.own_rodit.metadata,
        subjectuniqueidentifier_url: base,
      },
    },
  };
  const result = await login_server(cfg, {
    loginPath: "/api/login",
    timestampPath: "/api/login/timestamp",
  });
  if (!result?.jwt_token) {
    throw new Error(result?.error || "P2P login_server failed");
  }
  return result.jwt_token;
}

async function postA2a(jwt, body) {
  const res = await fetch(`${peerBase}/a2a`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, json, text };
}

function extractTaskId(sendJson) {
  const result = sendJson?.result;
  if (!result || typeof result !== "object") return "";
  const task = result.task || result;
  return String(task.id || task.taskId || "").trim();
}

function taskHistoryContainsMarker(taskJson, needle) {
  const history = taskJson?.history;
  if (!Array.isArray(history)) return false;
  for (const entry of history) {
    for (const part of entry?.parts || []) {
      if (part?.kind === "text" && String(part.text || "").includes(needle)) {
        return true;
      }
    }
  }
  return false;
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

process.stdout.write(`A2A messaging E2E → ${peerBase}\n`);
process.stdout.write(`  marker: ${marker}\n\n`);

const jwt = await p2pJwt(peerBase);
const msgId = `a2a-msg-${Date.now()}`;
const sendBody = {
  jsonrpc: "2.0",
  id: msgId,
  method: "message/send",
  params: {
    message: {
      role: "user",
      parts: [{ kind: "text", text: `IDENTYCLAW_A2A_MESSAGING_E2E ${marker}` }],
      messageId: msgId,
    },
  },
};

const send = await postA2a(jwt, sendBody);
const sendOk = send.status >= 200 && send.status < 300;
tally.add(
  reportFinding(
    "POST /a2a message/send",
    sendOk,
    sendOk ? `HTTP ${send.status}` : `HTTP ${send.status} ${String(send.text).slice(0, 200)}`,
  ),
);

let taskId = "";
if (sendOk) {
  taskId = extractTaskId(send.json);
  tally.add(
    reportFinding(
      "message/send result.task.id present",
      Boolean(taskId),
      taskId ? `taskId=${taskId}` : `body=${JSON.stringify(send.json).slice(0, 300)}`,
    ),
  );
}

if (taskId) {
  const deadline = Date.now() + pollTimeoutMs;
  let retrieved = false;
  let lastDetail = "";

  while (Date.now() < deadline) {
    const getBody = {
      jsonrpc: "2.0",
      id: `get-${taskId}`,
      method: "tasks/get",
      params: { id: taskId },
    };
    const get = await postA2a(jwt, getBody);
    if (get.status >= 200 && get.status < 300 && taskHistoryContainsMarker(get.json?.result, marker)) {
      retrieved = true;
      lastDetail = `HTTP ${get.status} history contains marker`;
      break;
    }
    lastDetail = `HTTP ${get.status} ${JSON.stringify(get.json).slice(0, 200)}`;
    await sleep(pollIntervalMs);
  }

  tally.add(reportFinding("tasks/get returns task with marker", retrieved, lastDetail));
}

tally.printSummary("Summary");
process.exit(tally.exitCode());
