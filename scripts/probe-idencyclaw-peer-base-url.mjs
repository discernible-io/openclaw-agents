#!/usr/bin/env node
/**
 * Resolve a peer Passport token_id to a public gateway base via IdentyClaw API.
 * Mirrors identyclaw-a2a TokenPeerResolver (GET /api/identity/token/{tokenId}/full → dn.contactUri).
 *
 * Usage: probe-idencyclaw-peer-base-url.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>
 * Prints one line: https://host:port (gateway base, no path)
 */
import { createRequire } from "node:module";
import { readFileSync, existsSync } from "node:fs";
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
const bs58mod = require("bs58");
const bs58 = bs58mod.default || bs58mod;

function secretKeyBytes(nearPrivateKey) {
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  return new Uint8Array(decoded);
}

function base64UrlEncode(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

function normalizeGatewayBase(raw) {
  const trimmed = String(raw ?? "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  try {
    const url = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    return `${url.protocol}//${url.host}`;
  } catch {
    return trimmed;
  }
}

/** Same rules as identyclaw-a2a dist/auth/contact-uri.js */
function contactUriToGatewayBase(contactUri) {
  const trimmed = String(contactUri ?? "").trim();
  if (!trimmed) {
    return null;
  }
  if (/^https?:\/\//i.test(trimmed)) {
    const base = normalizeGatewayBase(trimmed);
    return base || null;
  }
  const firstColon = trimmed.indexOf(":");
  if (firstColon <= 0) {
    return null;
  }
  const scheme = trimmed.slice(0, firstColon).toLowerCase();
  const remainder = trimmed.slice(firstColon + 1);
  if (!remainder) {
    return null;
  }
  if (scheme === "mailto" || scheme === "email") {
    return null;
  }
  if (scheme !== "https" && scheme !== "http") {
    return null;
  }
  const secondColon = remainder.indexOf(":");
  const authority = secondColon >= 0 ? remainder.slice(0, secondColon) : remainder;
  const identifier = secondColon >= 0 ? remainder.slice(secondColon + 1) : "";
  if (!authority) {
    return null;
  }
  let url = `${scheme}://${authority}`;
  if (identifier) {
    if (/^\d+$/.test(identifier)) {
      url += `:${identifier}`;
    } else if (identifier.startsWith("/")) {
      url += identifier;
    } else if (/^https?:\/\//i.test(identifier)) {
      url = identifier;
    } else {
      url += `/${identifier.replace(/^\//, "")}`;
    }
  }
  const base = normalizeGatewayBase(url);
  return base || null;
}

function loadContactUriParser() {
  const candidates = [
    join(pluginExtDir, "dist/auth/contact-uri.js"),
    join(dirname(pluginExtDir), "identyclaw-a2a/dist/auth/contact-uri.js"),
  ];
  for (const candidate of candidates) {
    if (!existsSync(candidate)) {
      continue;
    }
    try {
      const mod = require(candidate);
      if (typeof mod.contactUriToGatewayBase === "function") {
        return mod.contactUriToGatewayBase.bind(mod);
      }
    } catch {
      // fall through
    }
  }
  return contactUriToGatewayBase;
}

const parseContactUri = loadContactUriParser();

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

const jwt = await apiLogin();
const identityResp = await fetch(
  `${apiBase}/api/identity/token/${encodeURIComponent(peerTokenId)}/full`,
  { headers: { authorization: `Bearer ${jwt}` } },
);
if (!identityResp.ok) {
  process.exit(1);
}
const identity = await identityResp.json();
const contactUri = identity?.dn?.contactUri;
if (!contactUri) {
  process.stderr.write(`identity for ${peerTokenId} has no dn.contactUri\n`);
  process.exit(1);
}
const publicBase = parseContactUri(contactUri);
if (!publicBase) {
  process.stderr.write(
    `identity for ${peerTokenId} has unsupported contactUri for A2A: ${contactUri}\n`,
  );
  process.exit(1);
}
process.stdout.write(publicBase);
