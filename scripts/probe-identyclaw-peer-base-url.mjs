#!/usr/bin/env node
/**
 * Resolve a peer Passport token_id to a public gateway base.
 *
 * 1. IdentyClaw API GET /api/identity/token/{tokenId}/full → metadata.webhook_url
 * 2. Fallback: on-chain RODiT metadata.webhook_url (nearorg_rpc_tokenfromroditid)
 *
 * Usage: probe-identyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>
 * Prints one line: https://host:port (gateway base, no path)
 */
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { resolvePeerGatewayBase } from "./lib-peer-gateway-url.mjs";
import {
  applyNearRoditEnv,
  loadRoditAuthBe,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
const peerTokenId = String(process.argv[4] || "")
  .trim()
  .toLowerCase();
if (!pluginExtDir || !credPath || !/^[a-z]{12}$/.test(peerTokenId)) {
  process.stderr.write(
    "usage: probe-identyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>\n",
  );
  process.exit(2);
}

const creds = parseNearCreds(credPath);
applyNearRoditEnv(creds);
const identityApiBaseUrl = await resolveRoditApiBaseUrl({ extDir: pluginExtDir, credPath });
process.env.IDENTYCLAW_BASE_URL = identityApiBaseUrl;

const { RoditClient } = loadRoditAuthBe(pluginExtDir);

let fetchIdentityFull = null;
const apiClientPath = join(pluginExtDir, "dist/auth/identyclaw-api-client.js");
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

let result;
try {
  result = await resolvePeerGatewayBase(peerTokenId, {
    fetchIdentityFull,
    fetchPeerRoditByTokenId,
  });
} catch (err) {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
}

process.stdout.write(result.base);
