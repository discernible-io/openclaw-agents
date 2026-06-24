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
import { createRequire } from "node:module";
import { readFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import { resolvePeerGatewayBase } from "./lib-peer-gateway-url.mjs";

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

const creds = JSON.parse(readFileSync(credPath, "utf8"));
const accountId = creds.implicit_account_id || creds.account_id || "";
const privateKey = creds.private_key || "";
if (!accountId || !privateKey) {
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
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const pkgPath = join(pluginExtDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient } = require("@rodit/rodit-auth-be");

let fetchIdentityFull = null;
const apiClientPath = join(pluginExtDir, "dist/auth/identyclaw-api-client.js");
if (existsSync(apiClientPath)) {
  const { fetchTokenIdentityFull } = await import(pathToFileURL(apiClientPath).href);
  fetchIdentityFull = (tokenId) =>
    fetchTokenIdentityFull(tokenId, {
      logLevel: process.env.LOG_LEVEL || "error",
      identityApiBaseUrl: process.env.IDENTYCLAW_BASE_URL,
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

if (result.source === "chain") {
  process.stderr.write(
    `(${peerTokenId}: peer base from on-chain metadata.webhook_url — API /full had no usable webhook_url)\n`,
  );
}

process.stdout.write(result.base);
