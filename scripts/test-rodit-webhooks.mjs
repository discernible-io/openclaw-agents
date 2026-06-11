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
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

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

const require = createRequire(pathToFileURL(join(extDir, "package.json")));
const nacl = require("tweetnacl");

function loadNearCreds(path) {
  const data = JSON.parse(readFileSync(path, "utf8"));
  const accountId = data.implicit_account_id || data.account_id || data.accountId;
  const privateKey = data.private_key || data.privateKey;
  if (!accountId || !privateKey) {
    throw new Error(`Missing account_id/private_key in ${path}`);
  }
  return { accountId: String(accountId).trim(), privateKey: String(privateKey).trim() };
}

function privateKeyBytes(nearPrivateKey) {
  const bs58 = require("bs58");
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  if (decoded.length !== 64 && decoded.length < 32) throw new Error("Invalid NEAR private key");
  return new Uint8Array(decoded);
}

function signerPublicKeyBase64url(tokenId) {
  return Buffer.from(tokenId.trim().toLowerCase(), "hex").toString("base64url");
}

function signWebhookPayload(payload, privateKey) {
  const timestamp = Date.now().toString();
  const payloadWithTimestamp = payload + timestamp;
  const hash = createHash("sha256").update(payloadWithTimestamp).digest();
  const signature = nacl.sign.detached(new Uint8Array(hash), privateKey);
  return {
    timestamp,
    signatureHex: Buffer.from(signature).toString("hex"),
  };
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
const signerKey = privateKeyBytes(signer.privateKey);

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
});
tally(record("invalid signature rejected", garbage.status === 401, `HTTP ${garbage.status}`));

const wakePayload = JSON.stringify({ text: "identyclaw rodit webhook smoke", mode: "now" });
const signed = signWebhookPayload(wakePayload, signerKey);
const ok = await postWebhook(wakePayload, {
  "x-signature": signed.signatureHex,
  "x-timestamp": signed.timestamp,
  "x-rodit-token-id": signer.accountId,
});
tally(
  record(
    "signed POST accepted",
    ok.status === 200 && ok.json?.ok === true,
    `HTTP ${ok.status} ${ok.json?.ok === true ? "" : JSON.stringify(ok.json)}`,
  ),
);

console.log("");
console.log(`Results: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
