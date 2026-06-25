#!/usr/bin/env node
/**
 * Probe own Passport RODiT owner_id (inbound P2P JWT audience) via rodit-auth-be.
 *
 * Usage: probe-rodit-own-owner-id.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Env: NEAR_CONTRACT_ID, LOG_LEVEL (optional)
 */
import { applyNearRoditEnv, loadRoditAuthBe, parseNearCreds } from "./lib-rodit-env.mjs";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
  process.stderr.write("usage: probe-rodit-own-owner-id.mjs <plugin-ext-dir> <credentials.json>\n");
  process.exit(2);
}

applyNearRoditEnv(parseNearCreds(credPath));
const { RoditClient } = loadRoditAuthBe(pluginExtDir);

const client = await RoditClient.create({ role: "client" });
const config = await client.getConfigOwnRodit();
const ownerId = config?.own_rodit?.owner_id;
if (typeof ownerId !== "string" || !ownerId.trim()) {
  process.stderr.write("own_rodit.owner_id missing from passport config\n");
  process.exit(1);
}

process.stdout.write(ownerId.trim());
