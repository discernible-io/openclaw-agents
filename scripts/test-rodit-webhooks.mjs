#!/usr/bin/env node
/**
 * RODiT webhook ingress test (positive + negative) — same signing as clienttest-idc.
 *
 * Usage:
 *   node scripts/test-rodit-webhooks.mjs \
 *     --creds /path/to/near-credentials.json \
 *     --target https://agent-d.dev.identyclaw.com:7443 \
 *     [--path hooks/wake|hooks/agent|hooks/wake,hooks/agent]
 */
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { loadNearCreds } from "./lib-rodit-webhook-test.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credsPath = arg("--creds");
const signerCredsPath = arg("--signer-creds", credsPath);
const target = arg("--target");
const paths = (arg("--path", "hooks/wake,hooks/agent") || "hooks/wake")
  .split(",")
  .map((p) => p.trim())
  .filter(Boolean);

if (!credsPath || !target || !extDir) {
  console.error(
    "Usage: node scripts/test-rodit-webhooks.mjs --ext-dir <a2a-plugin> --creds <near-creds.json> --target <base-url> [--path hooks/wake|hooks/agent|hooks/wake,hooks/agent] [--signer-creds <json>]",
  );
  process.exit(2);
}

const base = target.replace(/\/+$/, "");

function applyRoditEmbedEnv() {
  if (!process.env.LOG_LEVEL) process.env.LOG_LEVEL = "error";
  if (process.env.SUPPRESS_NO_CONFIG_WARNING === undefined) {
    process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
  }
  if (process.env.SUPPRESS_STRICTNESS_CHECK === undefined) {
    process.env.SUPPRESS_STRICTNESS_CHECK = "true";
  }
}

async function sendSignedWebhookViaRodit(signerCredsPath, receiverBase, hookPath, eventText) {
  process.env.NEAR_CREDENTIALS_FILE_PATH = signerCredsPath;
  applyRoditEmbedEnv();
  const require = createRequire(pathToFileURL(join(extDir, "package.json")));
  const { RoditClient } = require("@rodit/rodit-auth-be");
  const client = await RoditClient.create({ role: "client" });
  const signer = loadNearCreds(signerCredsPath);
  const webhookUrl = receiverBase.replace(/^https?:\/\//i, "").replace(/\/+$/, "");
  const endpoint = `/${hookPath.replace(/^\/+/, "")}`;
  const peerReq = { user: { rodit_webhookurl: webhookUrl } };
  const payload = {
    event: eventText,
    data: { mode: "now", token_id: signer.accountId, peerTokenId: signer.accountId },
  };
  return endpoint === "/hooks/wake"
    ? client.sendWakeHook(payload, peerReq)
    : client.sendWebhookToEndpoint(payload, endpoint, peerReq);
}

function record(surface, matchesContract, detail) {
  return reportFinding(surface, matchesContract, detail);
}

const receiver = loadNearCreds(credsPath);
const signer = loadNearCreds(signerCredsPath);

const tally = createTally();

async function runForPath(agentPath) {
  const url = `${base}/${agentPath.replace(/^\/+/, "")}`;
  const labelPrefix = agentPath.replace(/^\/+/, "");

  async function postWebhook(body, headers = {}) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body,
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { raw: text };
    }
    return { status: res.status, json };
  }

  console.log(`RODiT webhook tests → POST ${url}`);
  console.log(`  signer token_id: ${signer.accountId.slice(0, 8)}…`);
  console.log(`  receiver creds:  ${receiver.accountId.slice(0, 8)}…`);
  console.log("");

  const unsigned = await postWebhook(JSON.stringify({ text: "unsigned-smoke", mode: "now" }));
  tally.add(
    record(
      `POST /${labelPrefix} without RODiT signature`,
      unsigned.status === 400 || unsigned.status === 401,
      `HTTP ${unsigned.status}`,
    ),
  );

  const garbage = await postWebhook(JSON.stringify({ text: "garbage-sig", mode: "now" }), {
    "x-signature": "deadbeef",
    "x-timestamp": Date.now().toString(),
    "x-rodit-token-id": signer.accountId,
  });
  tally.add(
    record(
      `POST /${labelPrefix} with invalid x-signature`,
      garbage.status === 401,
      `HTTP ${garbage.status}`,
    ),
  );

  let sdkOk = false;
  let sdkDetail = "";
  try {
    const sdkResult = await sendSignedWebhookViaRodit(
      signerCredsPath,
      base,
      agentPath,
      `identyclaw rodit webhook smoke ${labelPrefix}`,
    );
    sdkOk = sdkResult?.isValid === true;
    sdkDetail = sdkOk ? `requestId=${sdkResult.requestId || "?"}` : JSON.stringify(sdkResult?.error || sdkResult);
  } catch (err) {
    sdkDetail = err instanceof Error ? err.message : String(err);
  }
  tally.add(record(`POST /${labelPrefix} with rodit-auth-be signature`, sdkOk, sdkDetail));
  console.log("");
}

for (const agentPath of paths) {
  await runForPath(agentPath);
}

const { passed, notPassed } = tally.counts();
console.log(`Results: ${passed} passed, ${notPassed} not-passed`);
process.exit(tally.exitCode());
