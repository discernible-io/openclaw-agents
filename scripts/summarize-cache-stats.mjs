#!/usr/bin/env node
/**
 * Summarize prompt-cache hit metrics for one OpenClaw agent state dir.
 *
 * Usage:
 *   node scripts/summarize-cache-stats.mjs --state-dir DIR --agent ID [--json]
 *
 * Reads under DIR: openclaw.json, agents/.../sessions/sessions.json,
 * agents/.../sessions/*.jsonl, logs/cache-trace.jsonl
 */
import { readdirSync, readFileSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  formatCacheStatsLine,
  readConfiguredSessionId,
  summarizeAgentCacheStats,
} from "./lib-openclaw-cache-config.mjs";

function parseArgs(argv) {
  const out = { stateDir: "", agentId: "", json: false };
  const args = [...argv];
  while (args.length) {
    const a = args.shift();
    if (a === "--state-dir") out.stateDir = args.shift() || "";
    else if (a === "--agent") out.agentId = args.shift() || "";
    else if (a === "--json") out.json = true;
    else throw new Error(`Unknown arg: ${a}`);
  }
  return out;
}

function safeRead(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function listSessionJsonl(stateDir) {
  const agentsRoot = join(stateDir, "agents");
  const out = [];
  if (!existsSync(agentsRoot)) return out;
  let agentDirs = [];
  try {
    agentDirs = readdirSync(agentsRoot);
  } catch {
    return out;
  }
  for (const agent of agentDirs) {
    const sessionsDir = join(agentsRoot, agent, "sessions");
    if (!existsSync(sessionsDir)) continue;
    let files = [];
    try {
      files = readdirSync(sessionsDir);
    } catch {
      continue;
    }
    for (const f of files) {
      if (!f.endsWith(".jsonl")) continue;
      const p = join(sessionsDir, f);
      try {
        if (!statSync(p).isFile()) continue;
      } catch {
        continue;
      }
      const text = safeRead(p);
      if (text) out.push(text);
    }
  }
  return out;
}

function findSessionsJson(stateDir) {
  const agentsRoot = join(stateDir, "agents");
  if (!existsSync(agentsRoot)) return "";
  let agentDirs = [];
  try {
    agentDirs = readdirSync(agentsRoot);
  } catch {
    return "";
  }
  for (const agent of agentDirs) {
    const p = join(agentsRoot, agent, "sessions", "sessions.json");
    if (existsSync(p)) {
      const text = safeRead(p);
      if (text) return text;
    }
  }
  return "";
}

const opts = parseArgs(process.argv.slice(2));
if (!opts.stateDir || !opts.agentId) {
  process.stderr.write(
    "usage: summarize-cache-stats.mjs --state-dir <dir> --agent <id> [--json]\n",
  );
  process.exit(2);
}

const openclawPath = join(opts.stateDir, "openclaw.json");
let sessionId = "";
let cacheTraceEnabled = false;
if (existsSync(openclawPath)) {
  try {
    const cfg = JSON.parse(safeRead(openclawPath) || "{}");
    sessionId = readConfiguredSessionId(cfg);
    cacheTraceEnabled = Boolean(cfg?.diagnostics?.cacheTrace?.enabled);
  } catch {
    // ignore
  }
}

const summary = summarizeAgentCacheStats({
  agentId: opts.agentId,
  sessionId,
  cacheTraceEnabled,
  sessionsJson: findSessionsJson(opts.stateDir),
  jsonlTexts: listSessionJsonl(opts.stateDir),
  cacheTraceText: safeRead(join(opts.stateDir, "logs", "cache-trace.jsonl")),
});

if (opts.json) {
  process.stdout.write(`${JSON.stringify(summary)}\n`);
} else {
  process.stdout.write(`${formatCacheStatsLine(summary)}\n`);
  if (summary.turns === 0) {
    process.stdout.write(
      "  (no usage rows yet — chat once, or enable /usage full; DeepSeek may need a short delay before cached_tokens appear)\n",
    );
  }
}
