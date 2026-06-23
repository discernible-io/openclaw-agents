#!/usr/bin/env node
/**
 * Probe own Passport RODiT token_id (12-char Passport ID) via rodit-auth-be.
 *
 * Usage: probe-rodit-own-token-id.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Env: NEAR_CONTRACT_ID, IDENTYCLAW_BASE_URL (optional)
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
    process.stderr.write("usage: probe-rodit-own-token-id.mjs <plugin-ext-dir> <credentials.json>\n");
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

const pkgPath = join(pluginExtDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient } = require("@rodit/rodit-auth-be");

const client = await RoditClient.create({ role: "client" });
const config = await client.getConfigOwnRodit();
const tokenId = config?.own_rodit?.token_id;
if (typeof tokenId !== "string" || !tokenId.trim()) {
    process.stderr.write("own_rodit.token_id missing from passport config\n");
    process.exit(1);
}

process.stdout.write(tokenId.trim());
