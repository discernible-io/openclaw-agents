#!/usr/bin/env node
/**
 * Runtime peer resolution smoke test (TokenPeerResolver 0.4.2+).
 * Peer must be absent from outbound.agents and peers.json before running.
 *
 * Usage:
 *   node test-runtime-peer-resolve.mjs --ext-dir <a2a> --creds <near.json> --peer <token_id>
 */
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { applyNearRoditEnv, applyRoditApiBaseEnv, parseNearCreds } from "./lib-rodit-env.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = arg("--ext-dir", "");
const credPath = arg("--creds", "");
const peerTokenId = String(arg("--peer", "")).trim().toLowerCase();

if (!extDir || !credPath || !/^[a-z]{12}$/.test(peerTokenId)) {
  process.stderr.write(
    "usage: test-runtime-peer-resolve.mjs --ext-dir <a2a> --creds <near.json> --peer <token_id>\n",
  );
  process.exit(2);
}

applyNearRoditEnv(parseNearCreds(credPath));
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "info";
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
await applyRoditApiBaseEnv({ extDir, credPath });

const { TokenPeerResolver } = await import(
  pathToFileURL(join(extDir, "dist/outbound/token-peer-resolver.js")).href
);

let resolveSource = "unknown";
const resolver = new TokenPeerResolver({
  stateDir: "/home/node/.openclaw",
  persist: true,
  logLevel: "info",
  onInfo: (msg) => {
    process.stderr.write(`${msg}\n`);
    if (msg.includes("from API /full")) {
      resolveSource = "api";
    } else if (msg.includes("on-chain fallback")) {
      resolveSource = "chain";
    }
  },
  onWarn: (msg) => process.stderr.write(`WARN: ${msg}\n`),
});

const cardUrl = await resolver.resolveAgentCardUrl(peerTokenId);
if (!cardUrl) {
  process.stderr.write(`FAIL: resolveAgentCardUrl returned null for ${peerTokenId}\n`);
  process.exit(1);
}

process.stdout.write(`OK: resolved ${peerTokenId}\n`);
process.stdout.write(`  source=${resolveSource}\n`);
process.stdout.write(`  cardUrl=${cardUrl}\n`);

const cardRes = await fetch(cardUrl);
if (!cardRes.ok) {
  process.stderr.write(`FAIL: Agent Card fetch HTTP ${cardRes.status}\n`);
  process.exit(1);
}
const card = await cardRes.json();
process.stdout.write(`  agentCard.name=${card?.name ?? "(none)"}\n`);
