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
import { createTally, reportFinding, reportSkip } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const configPath = resolve(arg("--config", process.env.OPENCLAW_CONFIG || "/home/node/.openclaw/openclaw.json"));
const pluginDir = resolve(arg("--plugin-dir", "/home/node/.openclaw/extensions/identyclaw-webhooks/dist"));
const localId = arg("--local", arg("--sender", "local"));
const localTokenId = arg("--local-token-id", "");
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

const tally = createTally();

function record(surface, matchesContract, detail = "") {
  return reportFinding(surface, matchesContract, detail);
}

function tallySection(matchesContract) {
  tally.add(matchesContract);
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
  let ok = record("send_rodit_webhook to peer", outbound.deliveredOk, outbound.deliveredDetail);
  ok = record("GET peer /hooks/_receipts", outbound.peerReceivedOk, outbound.peerReceivedDetail) && ok;
  tallySection(ok);
} catch (err) {
  record("send_rodit_webhook to peer", false, err.message);
  record("GET peer /hooks/_receipts", false, "not run after send error");
  tallySection(false);
}

process.stdout.write("\n--- Inbound: we receive webhooks from peer ---\n");
if (skipInbound) {
  reportSkip("inbound P2P webhook section", "--skip-inbound");
  tally.addSkip();
} else if (!localBase) {
  const why = "no --local-base (our ingress URL for receipt check)";
  if (requireInbound) {
    record("peer send_rodit_webhook to local gateway", false, why);
    record("GET local /hooks/_receipts", false, "required but not run");
    tallySection(false);
  } else {
    reportSkip("inbound P2P webhook section", why);
    tally.addSkip();
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
            localTokenId: localTokenId || undefined,
            peerId,
            peerBase,
            localBase,
            localCredsPath,
            hookPath,
            delaySeconds: 0,
          });
    process.stdout.write(`    probe: POST ${inbound.hookUrl || localBase + "/" + hookPath}\n`);
    let ok = record("peer send_rodit_webhook to local gateway", inbound.peerDeliveredOk, inbound.peerDeliveredDetail);
    ok = record("GET local /hooks/_receipts", inbound.weReceivedOk, inbound.weReceivedDetail) && ok;
    tallySection(ok);
  } catch (err) {
    record("peer send_rodit_webhook to local gateway", false, err.message);
    record("GET local /hooks/_receipts", false, "not run after send error");
    tallySection(false);
  }
}

tally.printSummary("Summary");
process.exit(tally.exitCode());
