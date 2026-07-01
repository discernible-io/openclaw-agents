#!/usr/bin/env node
/**
 * Discover live remote agents via GET /api/agents, resolve gateway URLs
 * (GET /full → on-chain fallback), and verify liveness (agent-card HTTP 200).
 *
 * Usage:
 *   node discover-live-api-peers.mjs <ext-dir> <creds.json> \
 *     [--api-base <url>] [--exclude <token_id> ...] [--concurrency N] [--timeout-ms N]
 *
 * Prints one JSON object for openclaw.json outbound.agents:
 *   {"tokenId":{"url":"https://host/.well-known/agent-card.json","loginBaseUrl":"https://host"},...}
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { fetchPublicAgentTokenIds } from "./lib-discover-agents.mjs";
import { resolvePeerGatewayBase } from "./lib-peer-gateway-url.mjs";
import {
  applyNearRoditEnv,
  loadRoditAuthBe,
  parseNearCreds,
  resolveRoditApiBaseUrl,
} from "./lib-rodit-env.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = process.argv[2];
const credPath = process.argv[3];
if (!extDir || !credPath) {
  process.stderr.write(
    "usage: discover-live-api-peers.mjs <ext-dir> <creds.json> [--api-base <url>] [--exclude <token_id> ...]\n",
  );
  process.exit(2);
}

const concurrency = Math.min(Math.max(Number(arg("--concurrency", "6")) || 6, 1), 20);
const timeoutMs = Math.min(Math.max(Number(arg("--timeout-ms", "12000")) || 12000, 2000), 60000);
const exclude = new Set();
for (let i = 4; i < process.argv.length; i += 1) {
  if (process.argv[i] === "--exclude" && process.argv[i + 1]) {
    exclude.add(String(process.argv[i + 1]).trim().toLowerCase());
    i += 1;
  }
}

const creds = parseNearCreds(credPath);
applyNearRoditEnv(creds);
const identityApiBaseUrl =
  normalizeApiBase(arg("--api-base", "")) ||
  (await resolveRoditApiBaseUrl({ extDir, credPath }));
process.env.IDENTYCLAW_BASE_URL = identityApiBaseUrl;

const { RoditClient } = loadRoditAuthBe(extDir);

let fetchIdentityFull = null;
const apiClientPath = join(extDir, "dist/auth/identyclaw-api-client.js");
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

function normalizeApiBase(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

async function probeAgentCardLive(base) {
  const cardUrl = `${String(base).replace(/\/$/, "")}/.well-known/agent-card.json`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(cardUrl, { signal: controller.signal });
    if (!res.ok) {
      return false;
    }
    const body = await res.json().catch(() => null);
    return Boolean(body && (body.url || body.name));
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function resolveLivePeer(tokenId) {
  let result;
  try {
    result = await resolvePeerGatewayBase(tokenId, {
      fetchIdentityFull,
      fetchPeerRoditByTokenId,
    });
  } catch {
    return null;
  }
  const base = String(result?.base || "").replace(/\/$/, "");
  if (!base) {
    return null;
  }
  const live = await probeAgentCardLive(base);
  if (!live) {
    return null;
  }
  return {
    tokenId,
    url: `${base}/.well-known/agent-card.json`,
    loginBaseUrl: base,
    source: result.source,
  };
}

async function mapWithConcurrency(items, limit, fn) {
  const out = [];
  let index = 0;
  async function worker() {
    while (index < items.length) {
      const i = index;
      index += 1;
      out[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, () => worker()));
  return out;
}

const listed = await fetchPublicAgentTokenIds(identityApiBaseUrl, { exclude });
const candidates = (listed.tokenIds || []).filter((tid) => tid && !exclude.has(tid));

process.stderr.write(
  `discover-live-api-peers: GET /api/agents → ${candidates.length} remote candidate(s); probing agent-card liveness (concurrency=${concurrency})\n`,
);

const resolved = await mapWithConcurrency(candidates, concurrency, resolveLivePeer);
const peers = {};
let liveCount = 0;
for (const entry of resolved) {
  if (!entry) continue;
  peers[entry.tokenId] = {
    url: entry.url,
    loginBaseUrl: entry.loginBaseUrl,
  };
  liveCount += 1;
  process.stderr.write(`  live peer ${entry.tokenId} @ ${entry.loginBaseUrl} (${entry.source})\n`);
}

process.stderr.write(
  `discover-live-api-peers: ${liveCount} live peer(s) of ${candidates.length} probed\n`,
);
process.stdout.write(JSON.stringify(peers));
