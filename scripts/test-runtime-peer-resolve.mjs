#!/usr/bin/env node
/**
 * Runtime peer resolution smoke test (TokenPeerResolver 0.4.2+).
 * Peer must be absent from outbound.agents and peers.json before running.
 *
 * Usage:
 *   node test-runtime-peer-resolve.mjs --ext-dir <a2a> --creds <near.json> --peer <token_id>
 */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

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

const creds = JSON.parse(readFileSync(credPath, "utf8"));
const accountId = creds.implicit_account_id || creds.account_id || "";
const privateKey = creds.private_key || "";
if (!accountId || !privateKey) {
  process.stderr.write("credentials missing account_id or private_key\n");
  process.exit(1);
}

process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
process.env.IDENTYCLAW_ACCOUNT_ID = accountId;
process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = privateKey;
process.env.IDENTYCLAW_BASE_URL =
  process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";
process.env.NEAR_CONTRACT_ID =
  process.env.NEAR_CONTRACT_ID ||
  process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
  "genaaaa-identyclaw-com.near";
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "info";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

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
