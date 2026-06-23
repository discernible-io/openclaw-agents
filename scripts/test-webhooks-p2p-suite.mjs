#!/usr/bin/env node
/**
 * Bidirectional P2P webhook suite via send_rodit_webhook (same path peers use in production).
 *
 * Outbound — we deliver webhooks to the peer; verify peer /hooks/_receipts.
 * Inbound  — peer delivers webhooks to us; verify our /hooks/_receipts.
 *
 * Usage:
 *   node scripts/test-webhooks-p2p-suite.mjs \
 *     --local <local-passport-token-id> --peer <peer-passport-token-id> \
 *     --local-creds /path/to/local-near.json \
 *     --local-base https://agent-b.dev.identyclaw.com:7443 \
 *     --peer-base https://agent-a.dev.identyclaw.com:7443 \
 *     [--peer-creds /path/to/peer-near.json] \
 *     [--skip-inbound] [--require-inbound]
 */
import { resolve } from "node:path";
import {
  runInboundWebhookFromLivePeer,
  runInboundWebhookFromPeer,
  runOutboundWebhookToPeer,
} from "./lib-rodit-webhook-test.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const configPath = resolve(arg("--config", process.env.OPENCLAW_CONFIG || "/home/node/.openclaw/openclaw.json"));
const pluginDir = resolve(arg("--plugin-dir", "/home/node/.openclaw/extensions/identyclaw-webhooks/dist"));
const localId = arg("--local", arg("--sender", "local"));
const peerId = arg("--peer", arg("--receiver", "peer"));
const localCredsPath = arg("--local-creds", arg("--signer-creds", ""));
const peerCredsPath = arg("--peer-creds", arg("--reverse-signer-creds", ""));
const localBase = (arg("--local-base", arg("--reverse-receiver-base", "")) || "").replace(/\/+$/, "");
const peerBase = (arg("--peer-base", arg("--receiver-base", "")) || "").replace(/\/+$/, "");
const hookPath = arg("--path", "hooks/wake").replace(/^\/+/, "");
const skipInbound = process.argv.includes("--skip-inbound");
const requireInbound = process.argv.includes("--require-inbound");
const simulateInbound = process.argv.includes("--simulate-inbound");

if (!localCredsPath || !peerBase || !peerId) {
  process.stderr.write(
    "usage: test-webhooks-p2p-suite.mjs --local <passport-token-id> --peer <passport-token-id> " +
      "--local-creds <near.json> --peer-base <https://peer:port> " +
      "[--local-base <https://local:port>] [--peer-creds <peer.json>] " +
      "[--config openclaw.json] [--skip-inbound] [--require-inbound]\n",
  );
  process.exit(2);
}

function record(label, ok, detail = "") {
  const mark = ok ? "PASS" : "FAIL";
  const line = detail ? `${mark}  ${label} — ${detail}` : `${mark}  ${label}`;
  process.stdout.write(`${line}\n`);
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

process.stdout.write("P2P webhook suite (send_rodit_webhook)\n");
process.stdout.write(`  local:  ${localId} (${localBase || "n/a"})\n`);
process.stdout.write(`  peer:   ${peerId} (${peerBase})\n`);
process.stdout.write(`  config: ${configPath}\n`);

process.stdout.write("\n--- Outbound: we deliver webhooks to peer ---\n");
try {
  const outbound = await runOutboundWebhookToPeer({
    configPath,
    pluginDir,
    localId,
    peerId,
    localCredsPath,
    peerBase,
    hookPath,
    delaySeconds: 0,
  });
  process.stdout.write(`    POST ${outbound.hookUrl}\n`);
  let ok = record("outbound: we sent send_rodit_webhook to peer", outbound.deliveredOk, outbound.deliveredDetail);
  ok = record("outbound: peer recorded our webhook", outbound.peerReceivedOk, outbound.peerReceivedDetail) && ok;
  tally(ok);
} catch (err) {
  record("outbound: we sent send_rodit_webhook to peer", false, err.message);
  record("outbound: peer recorded our webhook", false, "skipped after send failure");
  tally(false);
}

process.stdout.write("\n--- Inbound: we receive webhooks from peer ---\n");
if (skipInbound) {
  process.stdout.write("SKIP  inbound section — --skip-inbound\n");
  tally("skip");
} else if (!localBase) {
  const why = "no --local-base (our ingress URL for receipt check)";
  process.stdout.write(`SKIP  inbound section — ${why}\n`);
  if (requireInbound) {
    record("inbound: peer sent send_rodit_webhook to us", false, why);
    record("inbound: we recorded peer webhook", false, "required but not run");
    tally(false);
  } else {
    tally("skip");
  }
} else {
  try {
    const inbound =
      simulateInbound && peerCredsPath
        ? await runInboundWebhookFromPeer({
            configPath,
            pluginDir,
            localId,
            peerId,
            peerCredsPath,
            localBase,
            hookPath,
            delaySeconds: 0,
          })
        : await runInboundWebhookFromLivePeer({
            localId,
            peerId,
            peerBase,
            localBase,
            localCredsPath,
            hookPath,
            delaySeconds: 0,
          });
    process.stdout.write(`    expect POST ${inbound.hookUrl || localBase + "/" + hookPath}\n`);
    let ok = record("inbound: peer sent send_rodit_webhook to us", inbound.peerDeliveredOk, inbound.peerDeliveredDetail);
    ok = record("inbound: we recorded peer webhook", inbound.weReceivedOk, inbound.weReceivedDetail) && ok;
    tally(ok);
  } catch (err) {
    record("inbound: peer sent send_rodit_webhook to us", false, err.message);
    record("inbound: we recorded peer webhook", false, "skipped after send failure");
    tally(false);
  }
}

process.stdout.write(`\n--- Summary: ${passed} passed, ${failed} failed, ${skipped} skipped ---\n`);
process.exit(failed > 0 ? 1 : 0);
