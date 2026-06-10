#!/usr/bin/env node
/**
 * Probe this agent's RODiT owner_id for inbound P2P JWT validation (p2pAudience).
 * Uses the same getRoditOwnConfig path as the A2A plugin.
 *
 * Usage: probe-rodit-p2p-audience.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
    process.stderr.write("usage: probe-rodit-p2p-audience.mjs <plugin-ext-dir> <credentials.json>\n");
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
process.env.IDENTYCLAW_BASE_URL = process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";
process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID ||
    process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
    "genaaaa-identyclaw-com.near";
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const { getRoditOwnConfig } = await import(
    join(pluginExtDir, "dist/auth/rodit-own-config.js")
);

const config = await getRoditOwnConfig("error");
const ownerId = config?.own_rodit?.owner_id;
if (typeof ownerId !== "string" || !ownerId.trim()) {
    process.stderr.write("own_rodit.owner_id missing\n");
    process.exit(1);
}

process.stdout.write(ownerId.trim());
