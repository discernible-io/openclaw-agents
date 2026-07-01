#!/usr/bin/env node
/**
 * List public IdentyClaw agent Passport token_ids via GET /api/agents.
 *
 * Usage:
 *   node probe-list-api-agents.mjs [--api-base <url>] [--exclude <token_id> ...]
 *
 * Prints one JSON line: {"tokenIds":["abc..."],"apiBase":"https://api.identyclaw.com","pages":1}
 */
import { fetchPublicAgentTokenIds, normalizeApiBaseUrl } from "./lib-discover-agents.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const apiBaseArg = arg("--api-base", process.env.IDENTYCLAW_API_BASE_URL || process.env.IDENTYCLAW_BASE_URL || "");
const exclude = new Set();
for (let i = 2; i < process.argv.length; i += 1) {
  if (process.argv[i] === "--exclude" && process.argv[i + 1]) {
    exclude.add(String(process.argv[i + 1]).trim().toLowerCase());
    i += 1;
  }
}

const apiBase = normalizeApiBaseUrl(apiBaseArg);
if (!apiBase) {
  process.stderr.write(
    "usage: probe-list-api-agents.mjs [--api-base <url>] [--exclude <token_id> ...]\n",
  );
  process.exit(2);
}

try {
  const result = await fetchPublicAgentTokenIds(apiBase, { exclude });
  process.stdout.write(JSON.stringify(result));
} catch (err) {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
}
