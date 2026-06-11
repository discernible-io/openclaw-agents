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
import { resolve } from "node:path";
import { runP2pWebhookSend } from "./lib-rodit-webhook-test.mjs";

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

function record(label, ok, detail = "") {
  const mark = ok ? "PASS" : "FAIL";
  const line = detail ? `${mark}  ${label} — ${detail}` : `${mark}  ${label}`;
  process.stdout.write(`${line}\n`);
  return ok;
}

async function runDirection(directionLabel, credsPath, recvBase, senderLabel, receiverLabel) {
  process.stdout.write(`\n==> ${directionLabel}\n`);
  const result = await runP2pWebhookSend({
    extDir,
    signerCredsPath: credsPath,
    receiverBase: recvBase,
    hookPath,
    senderLabel,
    receiverLabel,
  });
  process.stdout.write(`    signer:   ${result.signerId.slice(0, 12)}… (${senderLabel})\n`);
  process.stdout.write(`    receiver: ${recvBase}/${hookPath} (${receiverLabel})\n`);
  let ok = record(`${directionLabel}: signed POST accepted`, result.postOk, result.postDetail);
  ok = record(`${directionLabel}: receiver recorded webhook`, result.receiptOk, result.receiptDetail) && ok;
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

tally(await runDirection(`P2P webhook ${senderId} → ${receiverId}`, signerCredsPath, receiverBase, senderId, receiverId));

if (reverseSignerCreds && reverseReceiverBase) {
  tally(
    await runDirection(
      `P2P webhook ${receiverId} → ${senderId} (reply)`,
      reverseSignerCreds,
      reverseReceiverBase,
      receiverId,
      senderId,
    ),
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
