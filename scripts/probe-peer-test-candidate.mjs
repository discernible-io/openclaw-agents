#!/usr/bin/env node
/**
 * Probe a peer Passport token_id for constitution test capabilities.
 *
 * Prints one JSON object to stdout:
 *   { tokenId, name, a2aBase, peerEmail, hasA2a, hasEmail, source }
 *
 * Usage:
 *   probe-peer-test-candidate.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>
 */
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";
import {
  resolvePeerGatewayBase,
  tryIdentityFullToGatewayBase,
} from "./lib-peer-gateway-url.mjs";
import { peerEmailFromIdentity } from "./lib-peer-identity.mjs";
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
    "usage: probe-peer-test-candidate.mjs <plugin-ext-dir> <credentials.json> <peer-token-id>\n",
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

let identity = null;
let a2aBase = "";
let gatewaySource = "";
let peerEmail = "";
let name = "";

if (fetchIdentityFull) {
  try {
    identity = await fetchIdentityFull(peerTokenId);
    a2aBase = tryIdentityFullToGatewayBase(identity, peerTokenId) || "";
    if (a2aBase) {
      gatewaySource = "api";
    }
    peerEmail = peerEmailFromIdentity(identity);
    name = String(
      identity?.dn?.commonName || identity?.dn?.cn || identity?.name || "",
    ).trim();
  } catch {
    identity = null;
  }
}

if (!a2aBase) {
  try {
    const result = await resolvePeerGatewayBase(peerTokenId, {
      fetchIdentityFull,
      fetchPeerRoditByTokenId,
    });
    a2aBase = result.base;
    gatewaySource = result.source;
    if (!identity && fetchIdentityFull) {
      try {
        identity = await fetchIdentityFull(peerTokenId);
        peerEmail = peerEmailFromIdentity(identity);
        name = String(
          identity?.dn?.commonName || identity?.dn?.cn || identity?.name || "",
        ).trim();
      } catch {
        // keep partial result
      }
    }
  } catch {
    // no A2A base
  }
}

if (!peerEmail && identity) {
  peerEmail = peerEmailFromIdentity(identity);
}

process.stdout.write(
  JSON.stringify({
    tokenId: peerTokenId,
    name,
    a2aBase: a2aBase || "",
    peerEmail: peerEmail || "",
    hasA2a: Boolean(a2aBase),
    hasEmail: Boolean(peerEmail),
    source: gatewaySource || (a2aBase ? "api" : ""),
  }),
);
