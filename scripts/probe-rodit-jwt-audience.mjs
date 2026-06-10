#!/usr/bin/env node
/**
 * Probe IdentyClaw login_server JWT `aud` using the same rodit-auth-be path as the A2A plugin.
 * Used by bootstrap to set inbound.auth.audience (service RODiT owner_id), not the public URL.
 *
 * Usage: probe-rodit-jwt-audience.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Env: NEAR_CONTRACT_ID, LOG_LEVEL (optional)
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
    process.stderr.write("usage: probe-rodit-jwt-audience.mjs <plugin-ext-dir> <credentials.json>\n");
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
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const pkgPath = join(pluginExtDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient } = require("@rodit/rodit-auth-be");

const client = await RoditClient.create({ role: "client" });
const result = await client.login_server();
if (!result?.jwt_token) {
    process.stderr.write(`${result?.error || "login_server returned no jwt_token"}\n`);
    process.exit(1);
}

const payload = JSON.parse(
    Buffer.from(result.jwt_token.split(".")[1], "base64url").toString("utf8"),
);
const aud = payload.aud;
if (typeof aud !== "string" || !aud.trim()) {
    process.stderr.write("JWT missing aud claim\n");
    process.exit(1);
}

process.stdout.write(aud.trim());
