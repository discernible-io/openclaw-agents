#!/usr/bin/env node
/**
 * Resolve a peer Passport token_id to a public gateway base from on-chain RODiT
 * metadata.webhook_url (same field as probe-rodit-passport-urls.mjs and P2P JWT rodit_webhookurl).
 *
 * Usage: probe-identyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>
 * Prints one line: https://host:port (gateway base, no path)
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

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

function parseWebhookBase(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  try {
    const u = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    return `${u.protocol}//${u.host}`;
  } catch {
    return trimmed;
  }
}

const client = await RoditClient.create({ role: "client" });
const peerRodit = await client.getBlockchainService().nearorg_rpc_tokenfromroditid(peerTokenId);
const tokenId = String(peerRodit?.token_id || "").trim().toLowerCase();
if (!tokenId) {
  process.stderr.write(`no RODiT on chain for token_id ${peerTokenId}\n`);
  process.exit(1);
}

const publicBase = parseWebhookBase(peerRodit?.metadata?.webhook_url);
if (!publicBase || !/^https?:\/\//i.test(publicBase)) {
  process.stderr.write(
    `RODiT ${tokenId} has no usable metadata.webhook_url for A2A ingress\n`,
  );
  process.exit(1);
}

process.stdout.write(publicBase);
