#!/usr/bin/env node
/**
 * Resolve a peer Passport token_id to a public gateway base via IdentyClaw API.
 * Mirrors identyclaw_get_agent_identity (GET /api/identity/token/{tokenId}/full).
 *
 * Usage: probe-idencyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>
 * Prints one line: https://host:port (gateway base, no path)
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
const peerTokenId = String(process.argv[4] || "")
  .trim()
  .toLowerCase();
if (!pluginExtDir || !credPath || !/^[a-z]{12}$/.test(peerTokenId)) {
  process.stderr.write(
    "usage: probe-idencyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>\n",
  );
  process.exit(2);
}

const creds = JSON.parse(readFileSync(credPath, "utf8"));
const accountId = creds.implicit_account_id || creds.account_id || "";
const privateKey = creds.private_key || "";
if (!accountId || !privateKey) {
  process.exit(1);
}

const apiBase = (process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com").replace(
  /\/+$/,
  "",
);

const pkgPath = join(pluginExtDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const nacl = require("tweetnacl");
const bs58 = require("bs58");

function secretKeyBytes(nearPrivateKey) {
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  return new Uint8Array(decoded);
}

function base64UrlEncode(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

async function apiLogin() {
  const tsResp = await fetch(`${apiBase}/api/login/timestamp`);
  if (!tsResp.ok) {
    process.exit(1);
  }
  const tsData = await tsResp.json();
  if (!Number.isFinite(tsData.timestamp) || !tsData.timestamp_iso) {
    process.exit(1);
  }
  const message = `${accountId}${tsData.timestamp_iso}`;
  const signingKey = secretKeyBytes(privateKey);
  const signature = nacl.sign.detached(new TextEncoder().encode(message), signingKey);
  const loginResp = await fetch(`${apiBase}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      accountid: accountId,
      timestamp: tsData.timestamp,
      base64url_signature: base64UrlEncode(signature),
    }),
  });
  if (!loginResp.ok) {
    process.exit(1);
  }
  const loginData = await loginResp.json();
  const jwt = loginData.jwt_token || loginData.token;
  if (!jwt) {
    process.exit(1);
  }
  return jwt;
}

function pickContactUri(payload) {
  if (!payload || typeof payload !== "object") {
    return "";
  }
  const candidates = [
    payload.contactUri,
    payload.contacturi,
    payload.contact_uri,
    payload.webhook_url,
    payload.webhookUrl,
    payload.metadata?.webhook_url,
    payload.metadata?.contactUri,
    payload.identity?.contactUri,
    payload.traits?.contactUri,
  ];
  for (const value of candidates) {
    const text = String(value || "").trim();
    if (text) {
      return text;
    }
  }
  return "";
}

function contactUriToPublicBase(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  try {
    const withScheme = trimmed.includes("://") ? trimmed : `https://${trimmed}`;
    const u = new URL(withScheme);
    if (!u.hostname) {
      return "";
    }
    return `${u.protocol}//${u.host}`.replace(/\/+$/, "");
  } catch {
    return "";
  }
}

const jwt = await apiLogin();
const identityResp = await fetch(
  `${apiBase}/api/identity/token/${encodeURIComponent(peerTokenId)}/full`,
  { headers: { authorization: `Bearer ${jwt}` } },
);
if (!identityResp.ok) {
  process.exit(1);
}
const identity = await identityResp.json();
const publicBase = contactUriToPublicBase(pickContactUri(identity));
if (!publicBase) {
  process.exit(1);
}
process.stdout.write(publicBase);
