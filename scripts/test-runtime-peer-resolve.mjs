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
import { createTally, reportFinding } from "./lib-test-report.mjs";

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

const tally = createTally();
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
  onWarn: (msg) => process.stderr.write(`note: ${msg}\n`),
});

process.stdout.write(`Runtime peer resolution smoke\n  peer token_id: ${peerTokenId}\n\n`);

const cardUrl = await resolver.resolveAgentCardUrl(peerTokenId);
if (!cardUrl) {
  tally.add(reportFinding(`TokenPeerResolver.resolveAgentCardUrl(${peerTokenId})`, false, "returned null"));
} else {
  tally.add(
    reportFinding(
      `TokenPeerResolver.resolveAgentCardUrl(${peerTokenId})`,
      true,
      `source=${resolveSource}, cardUrl=${cardUrl}`,
    ),
  );

  const cardRes = await fetch(cardUrl);
  if (!cardRes.ok) {
    tally.add(reportFinding(`GET ${cardUrl}`, false, `HTTP ${cardRes.status}`));
  } else {
    const card = await cardRes.json();
    tally.add(
      reportFinding(
        `GET ${cardUrl}`,
        true,
        `agentCard.name=${card?.name ?? "(none)"}`,
      ),
    );
  }
}

tally.printSummary("Summary");
process.exit(tally.exitCode());
