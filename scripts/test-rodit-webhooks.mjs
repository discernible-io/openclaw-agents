#!/usr/bin/env node
/**
 * RODiT webhook ingress test (positive + negative) — same signing as clienttest-idc.
 *
 * Usage:
 *   node scripts/test-rodit-webhooks.mjs \
 *     --creds /path/to/near-credentials.json \
 *     --target https://agent-b.dihola.io:4443/hooks/wake \
 *     [--signer-creds /other/agent/creds.json]
 */
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { loadNearCreds } from "./lib-rodit-webhook-test.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credsPath = arg("--creds");
const signerCredsPath = arg("--signer-creds", credsPath);
const target = arg("--target");
const agentPath = arg("--path", "hooks/wake");

if (!credsPath || !target || !extDir) {
  console.error(
    "Usage: node scripts/test-rodit-webhooks.mjs --ext-dir <a2a-plugin> --creds <near-creds.json> --target <base-url> [--path hooks/wake|hooks/agent] [--signer-creds <json>]",
  );
  process.exit(2);
}

const base = target.replace(/\/+$/, "");
const url = `${base}/${agentPath.replace(/^\/+/, "")}`;

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

function record(label, ok, detail) {
  const mark = ok ? "PASS" : "FAIL";
  console.log(`${mark}  ${label}${detail ? ` — ${detail}` : ""}`);
  return ok;
}

const receiver = loadNearCreds(credsPath);
const signer = loadNearCreds(signerCredsPath);

let passed = 0;
let failed = 0;

function tally(ok) {
  if (ok) passed += 1;
  else failed += 1;
}

console.log(`RODiT webhook tests → POST ${url}`);
console.log(`  signer token_id: ${signer.accountId.slice(0, 8)}…`);
console.log(`  receiver creds:  ${receiver.accountId.slice(0, 8)}…`);
console.log("");

const unsigned = await postWebhook(JSON.stringify({ text: "unsigned-smoke", mode: "now" }));
tally(record("unsigned POST rejected", unsigned.status === 400 || unsigned.status === 401, `HTTP ${unsigned.status}`));

const garbage = await postWebhook(JSON.stringify({ text: "garbage-sig", mode: "now" }), {
  "x-signature": "deadbeef",
  "x-timestamp": Date.now().toString(),
  "x-rodit-token-id": signer.accountId,
});
tally(record("invalid signature rejected", garbage.status === 401, `HTTP ${garbage.status}`));

let sdkOk = false;
let sdkDetail = "";
try {
  const sdkResult = await sendSignedWebhookViaRodit(
    signerCredsPath,
    base,
    agentPath,
    "identyclaw rodit webhook smoke",
  );
  sdkOk = sdkResult?.isValid === true;
  sdkDetail = sdkOk ? `requestId=${sdkResult.requestId || "?"}` : JSON.stringify(sdkResult?.error || sdkResult);
} catch (err) {
  sdkDetail = err instanceof Error ? err.message : String(err);
}
tally(record("signed POST via rodit-auth-be", sdkOk, sdkDetail));

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
