#!/usr/bin/env node
/**
 * Probe own Passport fields via RoditClient.getConfigOwnRodit() (rodit-auth-be).
 * Used at bootstrap to self-configure public ingress base from metadata.webhook_url.
 *
 * Usage: probe-rodit-passport-urls.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Prints one JSON line: { webhook_url, api_base, owner_id, token_id, host, port }
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
  process.stderr.write(
    "usage: probe-rodit-passport-urls.mjs <plugin-ext-dir> <credentials.json>\n",
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

function parseWebhookBase(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) return { webhook_url: "", host: "", port: "" };
  try {
    const u = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    const webhook_url = `${u.protocol}//${u.host}`;
    return {
      webhook_url,
      host: u.hostname,
      port: u.port || (u.protocol === "https:" ? "443" : "80"),
    };
  } catch {
    return { webhook_url: trimmed, host: "", port: "" };
  }
}

const client = await RoditClient.create({ role: "client" });
const own = await client.getConfigOwnRodit();
const meta = own?.own_rodit?.metadata ?? {};
const parsed = parseWebhookBase(meta.webhook_url);
const apiBase = String(meta.subjectuniqueidentifier_url || "").trim().replace(/\/+$/, "");
const ownerId = String(own?.own_rodit?.owner_id || "").trim();
const tokenId = String(own?.own_rodit?.token_id || "").trim();

process.stdout.write(
  JSON.stringify({
    webhook_url: parsed.webhook_url,
    host: parsed.host,
    port: parsed.port,
    api_base: apiBase,
    owner_id: ownerId,
    token_id: tokenId,
  }),
);
