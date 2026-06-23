#!/usr/bin/env node
/**
 * P2P webhook test: peer signs at origin, local agent verifies (RODiT x-signature + x-timestamp).
 * For bidirectional tests with /hooks/_receipts verification, use test-webhooks-p2p-suite.mjs
 * or: ./identyclaw.sh test-webhook-p2p agent-b agent-a
 *
 * Usage:
 *   node scripts/test-webhooks-p2p.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --peer-creds /path/to/agent-a/near-credentials.json \
 *     --local https://agent-b.dev.identyclaw.com:7443
 */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = arg("--ext-dir");
const peerCreds = arg("--peer-creds");
const localBase = arg("--local");
const path = arg("--path", "hooks/wake");

if (!extDir || !peerCreds || !localBase) {
  console.error(
    "Usage: node scripts/test-webhooks-p2p.mjs --ext-dir <a2a> --peer-creds <peer.json> --local <agent-base> [--path hooks/wake]",
  );
  process.exit(2);
}

const script = join(dirname(fileURLToPath(import.meta.url)), "test-rodit-webhooks.mjs");
const result = spawnSync(
  process.execPath,
  [
    script,
    "--ext-dir",
    extDir,
    "--creds",
    peerCreds,
    "--signer-creds",
    peerCreds,
    "--target",
    localBase,
    "--path",
    path,
  ],
  { stdio: "inherit", env: { ...process.env, NODE_TLS_REJECT_UNAUTHORIZED: "0" } },
);

process.exit(result.status ?? 1);
