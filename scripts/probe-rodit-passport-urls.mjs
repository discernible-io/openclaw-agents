#!/usr/bin/env node
/**
 * Probe own Passport fields via RoditClient.getConfigOwnRodit() (rodit-auth-be).
 * Used at bootstrap to self-configure public ingress base from metadata.webhook_url.
 *
 * Usage: probe-rodit-passport-urls.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Prints one JSON line: { webhook_url, api_base, owner_id, token_id, host, port }
 */
import { join } from "node:path";
import {
  apiBaseFromOwnRoditMeta,
  applyNearRoditEnv,
  loadRoditAuthBe,
  parseNearCreds,
} from "./lib-rodit-env.mjs";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
  process.stderr.write(
    "usage: probe-rodit-passport-urls.mjs <plugin-ext-dir> <credentials.json>\n",
  );
  process.exit(2);
}

const creds = parseNearCreds(credPath);
applyNearRoditEnv(creds);

const { RoditClient } = loadRoditAuthBe(pluginExtDir);

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
const apiBase = apiBaseFromOwnRoditMeta(meta);
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
