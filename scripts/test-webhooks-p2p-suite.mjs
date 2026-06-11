#!/usr/bin/env node
/**
 * P2P webhook suite: peer signs at origin with their NEAR key, remote agent verifies.
 *
 * Verifies delivery via GET /hooks/_receipts on the receiver (rodit-webhooks test helper).
 *
 * Usage:
 *   node scripts/test-webhooks-p2p-suite.mjs \
 *     --sender agent-b \
 *     --receiver agent-a \
 *     --signer-creds /path/to/sender-near.json \
 *     --receiver-base https://agent-a.dihola.io:9443 \
 *     [--path hooks/wake]
 *
 * Bidirectional (when peer creds are available for the return path):
 *   node scripts/test-webhooks-p2p-suite.mjs \
 *     --sender agent-b --receiver agent-a \
 *     --signer-creds ... --receiver-base https://agent-a... \
 *     --reverse-signer-creds /path/to/receiver-near.json \
 *     --reverse-receiver-base https://agent-b...
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
const senderId = arg("--sender", "sender");
const receiverId = arg("--receiver", "receiver");
const signerCredsPath = arg("--signer-creds");
const receiverBase = (arg("--receiver-base", "") || "").replace(/\/+$/, "");
const hookPath = arg("--path", "hooks/wake").replace(/^\/+/, "");
const reverseSignerCreds = arg("--reverse-signer-creds", "");
const reverseReceiverBase = (arg("--reverse-receiver-base", "") || "").replace(/\/+$/, "");

if (!signerCredsPath || !receiverBase || !extDir) {
  process.stderr.write(
    "usage: test-webhooks-p2p-suite.mjs --ext-dir <a2a> --signer-creds <near.json> " +
      "--receiver-base <https://peer-host:port> [--sender id] [--receiver id] " +
      "[--reverse-signer-creds <peer.json> --reverse-receiver-base <local-url>]\n",
  );
  process.exit(2);
}

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

async function fetchJson(url, init = {}) {
  const res = await fetch(url, init);
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, json, text };
}

function record(label, ok, detail = "") {
  const mark = ok ? "PASS" : "FAIL";
  const line = detail ? `${mark}  ${label} — ${detail}` : `${mark}  ${label}`;
  process.stdout.write(`${line}\n`);
  return ok;
}

async function clearReceipts(receiverBase) {
  const url = `${receiverBase}/hooks/_receipts`;
  await fetchJson(url, { method: "DELETE" });
}

async function getReceipts(receiverBase) {
  const url = `${receiverBase}/hooks/_receipts`;
  const { status, json, text } = await fetchJson(url);
  if (status !== 200 || !json?.ok) {
    const hint = text?.includes("<!DOCTYPE") ? " (got HTML — check receiver port/host)" : "";
    throw new Error(`GET ${url} failed: HTTP ${status}${hint}`);
  }
  return json.receipts ?? [];
}

async function runDirection(opts) {
  const {
    directionLabel,
    signerCredsPath: credsPath,
    receiverBase: recvBase,
    hookPath: path,
    senderLabel,
    receiverLabel,
  } = opts;

  const signer = loadNearCreds(credsPath);
  const signerKey = privateKeyBytes(signer.privateKey);
  const marker = `p2p-webhook-${senderLabel}-to-${receiverLabel}-${Date.now()}`;
  const payload = JSON.stringify({ text: marker, mode: "now", p2p: true, requestId: marker });
  const hookUrl = `${recvBase}/${path}`;

  process.stdout.write(`\n==> ${directionLabel}\n`);
  process.stdout.write(`    signer:   ${signer.accountId.slice(0, 12)}… (${senderLabel})\n`);
  process.stdout.write(`    receiver: ${hookUrl} (${receiverLabel})\n`);

  await clearReceipts(recvBase);

  const signed = signWebhookPayload(payload, signerKey);
  const post = await fetchJson(hookUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-signature": signed.signatureHex,
      "x-timestamp": signed.timestamp,
      "x-rodit-token-id": signer.accountId,
    },
    body: payload,
  });

  let ok = record(
    `${directionLabel}: signed POST accepted`,
    post.status === 200 && post.json?.ok === true,
    `HTTP ${post.status}${post.json?.ok === true ? "" : ` ${JSON.stringify(post.json)}`}`,
  );

  const receipts = await getReceipts(recvBase);
  const hit = receipts.find(
    (r) =>
      r.requestId === marker &&
      (r.path === `/${path}` || r.path === path || String(r.path || "").endsWith(path)),
  );
  ok =
    record(
      `${directionLabel}: receiver recorded webhook`,
      Boolean(hit),
      hit ? `receipt requestId=${marker} at ${hit.timestamp || "?"}` : `no matching receipt (${receipts.length} total)`,
    ) && ok;

  return ok;
}

let passed = 0;
let failed = 0;
let skipped = 0;

function tally(result) {
  if (result === "skip") skipped += 1;
  else if (result) passed += 1;
  else failed += 1;
}

process.stdout.write("P2P webhook suite\n");
process.stdout.write(`  ext-dir: ${extDir}\n`);

tally(
  (await runDirection({
    directionLabel: `P2P webhook ${senderId} → ${receiverId}`,
    signerCredsPath,
    receiverBase,
    hookPath,
    senderLabel: senderId,
    receiverLabel: receiverId,
  }))
    ? true
    : false,
);

if (reverseSignerCreds && reverseReceiverBase) {
  tally(
    (await runDirection({
      directionLabel: `P2P webhook ${receiverId} → ${senderId} (reply)`,
      signerCredsPath: reverseSignerCreds,
      receiverBase: reverseReceiverBase,
      hookPath,
      senderLabel: receiverId,
      receiverLabel: senderId,
    }))
      ? true
      : false,
  );
} else {
  process.stdout.write(
    `\nSKIP  reverse direction (${receiverId} → ${senderId}) — no --reverse-signer-creds / --reverse-receiver-base\n` +
      `      Place peer NEAR creds at ~/identyclaw-agents-app/secrets/peer-credentials/${receiverId}/*.json\n` +
      `      or pass --reverse-signer-creds explicitly.\n`,
  );
  tally("skip");
}

process.stdout.write(`\n--- Summary: ${passed} passed, ${failed} failed, ${skipped} skipped ---\n`);
process.exit(failed > 0 ? 1 : 0);
