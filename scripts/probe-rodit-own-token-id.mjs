#!/usr/bin/env node
/**
 * Probe own Passport RODiT token_id (12-char Passport ID) via rodit-auth-be.
 *
 * Usage: probe-rodit-own-token-id.mjs <plugin-ext-dir> <host-path-to-near-credentials.json>
 * Env: NEAR_CONTRACT_ID (optional)
 */
import { applyNearRoditEnv, loadRoditAuthBe, parseNearCreds } from "./lib-rodit-env.mjs";

const pluginExtDir = process.argv[2];
const credPath = process.argv[3];
if (!pluginExtDir || !credPath) {
  process.stderr.write("usage: probe-rodit-own-token-id.mjs <plugin-ext-dir> <credentials.json>\n");
  process.exit(2);
}

applyNearRoditEnv(parseNearCreds(credPath));
const { RoditClient } = loadRoditAuthBe(pluginExtDir);

const client = await RoditClient.create({ role: "client" });
const config = await client.getConfigOwnRodit();
const tokenId = config?.own_rodit?.token_id;
if (typeof tokenId !== "string" || !tokenId.trim()) {
  process.stderr.write("own_rodit.token_id missing from passport config\n");
  process.exit(1);
}

process.stdout.write(tokenId.trim());
