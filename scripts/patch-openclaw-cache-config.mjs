#!/usr/bin/env node
/**
 * Patch openclaw.json with sticky OpenRouter session_id + cacheTrace diagnostics.
 *
 * Usage:
 *   node scripts/patch-openclaw-cache-config.mjs <openclaw.json> \
 *     [--session-id identyclaw] [--cache-trace 1|0] [--openrouter 1|0]
 */
import { readFileSync, writeFileSync, chmodSync } from "node:fs";
import { applyOpenclawCacheConfig } from "./lib-openclaw-cache-config.mjs";

function parseArgs(argv) {
  const out = {
    path: "",
    sessionId: "identyclaw",
    cacheTrace: true,
    openrouterEnabled: true,
  };
  const args = [...argv];
  out.path = args.shift() || "";
  while (args.length) {
    const a = args.shift();
    if (a === "--session-id") out.sessionId = args.shift() ?? "";
    else if (a === "--cache-trace") out.cacheTrace = (args.shift() ?? "1") !== "0";
    else if (a === "--openrouter") out.openrouterEnabled = (args.shift() ?? "1") !== "0";
    else throw new Error(`Unknown arg: ${a}`);
  }
  return out;
}

const opts = parseArgs(process.argv.slice(2));
if (!opts.path) {
  process.stderr.write(
    "usage: patch-openclaw-cache-config.mjs <openclaw.json> [--session-id ID] [--cache-trace 1|0] [--openrouter 1|0]\n",
  );
  process.exit(2);
}

const data = JSON.parse(readFileSync(opts.path, "utf8"));
applyOpenclawCacheConfig(data, {
  sessionId: opts.sessionId,
  cacheTrace: opts.cacheTrace,
  openrouterEnabled: opts.openrouterEnabled,
});
writeFileSync(opts.path, `${JSON.stringify(data, null, 2)}\n`, "utf8");
try {
  chmodSync(opts.path, 0o600);
} catch {
  // ignore chmod failures on exotic FS
}
