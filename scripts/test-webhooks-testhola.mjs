#!/usr/bin/env node
/**
 * Webhook test via IdentyClaw /api/testhola (same pattern as clienttest-idc).
 * API validates HOLA, then sends RODiT-signed webhooks to the caller's webhook_url.
 *
 * Usage:
 *   node scripts/test-webhooks-testhola.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /path/to/near-credentials.json \
 *     --agent-base https://agent-d.dev.identyclaw.com:7443 \
 *     [--api-base <url>]  # default: Passport subjectuniqueidentifier_url via RoditClient
 */
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { pathToFileURL } from "node:url";
import {
  applyNearRoditEnv,
  normalizeApiBaseUrl,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
let credPath = resolve(arg("--creds", ""));
const agentBase = (arg("--agent-base", "") || arg("--agent-dase", "")).replace(/\/$/, "");
const apiBaseArg = arg("--api-base", "");

if (!extDir || !agentBase) {
  console.error(
    "Usage: node scripts/test-webhooks-testhola.mjs --ext-dir <a2a-plugin> --creds <near.json> --agent-base <url> [--api-base <url>]",
  );
  process.exit(2);
}

if (credPath.includes("*")) {
  const dir = dirname(credPath);
  const hit = readdirSync(dir).find((f) => f.endsWith(".json"));
  credPath = hit ? join(dir, hit) : credPath;
}

const nearCreds = parseNearCreds(credPath);
applyNearRoditEnv(nearCreds);
const { privateKey } = nearCreds;
const apiBase = apiBaseArg
  ? normalizeApiBaseUrl(apiBaseArg)
  : await resolveRoditApiBaseUrl({ extDir, credPath });
process.env.IDENTYCLAW_BASE_URL = apiBase;

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const nacl = require("tweetnacl");
const bs58 = require("bs58");
const { RoditClient } = require("@rodit/rodit-auth-be");

const HOLA_CHECKSUM_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ";
const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const TESTHOLA_EVENTS = new Set([
  "testhola_validation_success",
  "testhola_validation_failed",
  "testhola_response_failed",
]);

function secretKeyBytes(nearPrivateKey) {
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  if (decoded.length !== 64 && decoded.length < 32) {
    throw new Error(`Invalid NEAR private key length: ${decoded.length}`);
  }
  return new Uint8Array(decoded);
}

function bytesToBase32(bytes) {
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return output;
}

function computeHolaChecksum(messagePrefix) {
  let sum = 0;
  for (let i = 0; i < messagePrefix.length; i++) sum += messagePrefix.charCodeAt(i);
  return HOLA_CHECKSUM_ALPHABET[sum % 23];
}

function signMessageWithEd25519(message, secretKey) {
  const messageBytes = new TextEncoder().encode(message);
  const signatureBytes = nacl.sign.detached(messageBytes, secretKey);
  return bytesToBase32(signatureBytes);
}

async function fetchNoncetsFromApi(client) {
  try {
    const data = await client.request("GET", "/api/holanonce16ts");
    return {
      noncetsHex: data.noncetsHex || "4F9A3C7E2D1B9A4C",
      timestamp: data.timestamp || new Date().toISOString(),
    };
  } catch {
    return { noncetsHex: "4F9A3C7E2D1B9A4C", timestamp: new Date().toISOString() };
  }
}

async function generateValidHola(client, secretKey) {
  const configObject = await client.getConfigOwnRodit();
  const tokenId = configObject?.own_rodit?.token_id;
  if (!tokenId) throw new Error("Unable to resolve tokenId from RoditClient config");

  const recipient = "MUNDO";
  const { noncetsHex, timestamp } = await fetchNoncetsFromApi(client);
  const messageWithoutSigRaw = `HOLA/${recipient}/${String(tokenId).toLowerCase()}/${timestamp}/${noncetsHex.toUpperCase()}/API.IDENTYCLAW.COM/`;
  const messageForSigning = messageWithoutSigRaw.toUpperCase();
  const signature = signMessageWithEd25519(messageForSigning, secretKey);
  const checksum = computeHolaChecksum(`${messageForSigning}${signature}/`);
  return `${messageForSigning}${signature}/${checksum}`;
}

function record(surface, matchesContract, detail) {
  return reportFinding(surface, matchesContract, detail);
}

const tally = createTally();

async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms));
}

async function clearReceipts() {
  await fetch(`${agentBase}/hooks/_receipts`, { method: "DELETE" });
}

async function fetchReceipts() {
  const res = await fetch(`${agentBase}/hooks/_receipts`);
  if (!res.ok) return [];
  const body = await res.json();
  return Array.isArray(body.receipts) ? body.receipts : [];
}

console.log(`Webhook testhola flow`);
console.log(`  API:   POST ${apiBase}/api/testhola`);
console.log(`  Agent: ${agentBase} (webhook_url must point here)`);
console.log("");

const client = await RoditClient.create({ role: "client" });
const ownConfig = await client.getConfigOwnRodit();
const registeredWebhook = (ownConfig?.own_rodit?.metadata?.webhook_url || "").replace(/\/$/, "");
const expectedWebhook = agentBase.replace(/\/$/, "");
if (registeredWebhook && registeredWebhook !== expectedWebhook) {
  console.log(`WARN  Passport webhook_url mismatch`);
  console.log(`      registered: ${registeredWebhook}`);
  console.log(`      expected:   ${expectedWebhook}`);
  console.log(`      /api/testhola will deliver to registered URL, not this agent`);
  console.log("");
}

const login = await client.login_server();
const jwt = login?.jwt_token;
if (!jwt) throw new Error(login?.error || "login_server failed");

const secretKey = secretKeyBytes(privateKey);
const hola = await generateValidHola(client, secretKey);

await clearReceipts();

const testholaRes = await fetch(`${apiBase}/api/testhola`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    authorization: `Bearer ${jwt}`,
    "x-request-id": `identyclaw-webhook-test-${Date.now()}`,
  },
  body: JSON.stringify({ hola }),
});
const testholaBody = await testholaRes.json().catch(() => ({}));

tally.add(
  record(
    "POST /api/testhola",
    testholaRes.status === 200 && testholaBody.valid === true,
    `HTTP ${testholaRes.status} valid=${testholaBody.valid}`,
  ),
);

const requestId = testholaBody.requestId || null;
let receipts = [];
for (let i = 0; i < 30; i++) {
  receipts = await fetchReceipts();
  const hits = receipts.filter(
    (r) => (!requestId || r.requestId === requestId) && TESTHOLA_EVENTS.has(r.event || ""),
  );
  if (hits.length >= 2) break;
  await sleep(200);
}

const wake = receipts.find((r) => r.path === "/hooks/wake");
const agentHook = receipts.find((r) => r.path === "/hooks/agent");
const testholaReceipts = receipts.filter((r) => TESTHOLA_EVENTS.has(r.event || ""));

const webhookUrlOk = !registeredWebhook || registeredWebhook === expectedWebhook;
if (!webhookUrlOk) {
  tally.add(
    record(
      "Passport metadata.webhook_url",
      false,
      `registered ${registeredWebhook}, agent ingress ${expectedWebhook}`,
    ),
  );
} else {
  tally.add(
    record("POST /hooks/wake after testhola", !!wake, wake ? `event=${wake.event}` : "no receipt"),
  );
  tally.add(
    record(
      "POST /hooks/agent after testhola",
      !!agentHook,
      agentHook ? `event=${agentHook.event}` : "no receipt",
    ),
  );
  tally.add(
    record(
      "GET /hooks/_receipts testhola events",
      testholaReceipts.length > 0,
      `${testholaReceipts.length} receipt(s)${requestId ? ` requestId=${requestId}` : ""}`,
    ),
  );
}

if (!wake && testholaBody.valid && webhookUrlOk) {
  console.log("");
  console.log(`Hint: testhola returned valid but no receipts — check ingress reachability from ${apiBase}`);
}
if (!webhookUrlOk) {
  console.log("");
  console.log("Update Passport metadata webhook_url (on-chain) to:");
  console.log(`  ${expectedWebhook}`);
}

const { passed, notPassed } = tally.counts();
console.log(`Results: ${passed} passed, ${notPassed} not-passed`);
process.exit(tally.exitCode());
