#!/usr/bin/env node
/**
 * Probe a remote peer for constitution test capabilities (A2A base + Passport email).
 *
 * Usage:
 *   node probe-test-candidate-peer.mjs <ext-dir> <creds.json> <peer-token-id> [--a2a-base <url>]
 *
 * Prints one JSON line: {"a2aBase":"https://...|null","peerEmail":"user@domain|null"}
 */
import { fetchPeerIdentityFull, peerEmailFromIdentity } from "./lib-peer-identity.mjs";
import { resolvePeerGatewayBase } from "./lib-peer-gateway-url.mjs";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  applyNearRoditEnv,
  loadRoditAuthBe,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = process.argv[2];
const credPath = process.argv[3];
const peerTokenId = String(process.argv[4] || "")
  .trim()
  .toLowerCase();
const a2aBaseArg = (arg("--a2a-base", "") || "").replace(/\/$/, "");

if (!extDir || !credPath || !/^[a-z]{12}$/.test(peerTokenId)) {
  process.stderr.write(
    "usage: probe-test-candidate-peer.mjs <ext-dir> <creds.json> <peer-token-id> [--a2a-base <url>]\n",
  );
  process.exit(2);
}

const nearCreds = parseNearCreds(credPath);
applyNearRoditEnv(nearCreds);
const identityApiBaseUrl = await resolveRoditApiBaseUrl({ extDir, credPath });
process.env.IDENTYCLAW_BASE_URL = identityApiBaseUrl;

let a2aBase = a2aBaseArg || "";
if (!a2aBase) {
  const { RoditClient } = loadRoditAuthBe(extDir);
  let fetchIdentityFull = null;
  const apiClientPath = join(extDir, "dist/auth/identyclaw-api-client.js");
  if (existsSync(apiClientPath)) {
    const { fetchTokenIdentityFull } = await import(pathToFileURL(apiClientPath).href);
    fetchIdentityFull = (tokenId) =>
      fetchTokenIdentityFull(tokenId, {
        logLevel: process.env.LOG_LEVEL || "error",
        identityApiBaseUrl,
      });
  }
  async function fetchPeerRoditByTokenId(tokenId) {
    const client = await RoditClient.create({ role: "client" });
    return client.getBlockchainService().nearorg_rpc_tokenfromroditid(tokenId);
  }
  try {
    const result = await resolvePeerGatewayBase(peerTokenId, {
      fetchIdentityFull,
      fetchPeerRoditByTokenId,
    });
    a2aBase = result.base || "";
  } catch {
    a2aBase = "";
  }
}

let peerEmail = "";
try {
  const { identity } = await fetchPeerIdentityFull(extDir, credPath, peerTokenId, identityApiBaseUrl);
  peerEmail = peerEmailFromIdentity(identity);
} catch {
  peerEmail = "";
}

process.stdout.write(
  JSON.stringify({
    a2aBase: a2aBase || null,
    peerEmail: peerEmail || null,
  }),
);
