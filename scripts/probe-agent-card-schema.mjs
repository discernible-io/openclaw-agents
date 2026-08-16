#!/usr/bin/env node
/**
 * Fetch or read an Agent Card JSON document and validate schema.
 *
 * Usage:
 *   curl -sk URL | node scripts/probe-agent-card-schema.mjs --label local
 *   node scripts/probe-agent-card-schema.mjs --label local --url https://agent:8443/.well-known/agent-card.json
 *   node scripts/probe-agent-card-schema.mjs --label local --file /path/to/card.json
 */
import { readFileSync } from "node:fs";
import { validateAgentCard } from "./lib-agent-card-validate.mjs";
import { reportFinding } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const label = arg("--label", "agent-card");
const url = arg("--url", "");
const file = arg("--file", "");

async function loadCard() {
  if (file) {
    return JSON.parse(readFileSync(file, "utf8"));
  }
  if (url) {
    const res = await fetch(url);
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} fetching ${url}: ${text.slice(0, 200)}`);
    }
    return JSON.parse(text);
  }
  const stdin = readFileSync(0, "utf8");
  if (!stdin.trim()) {
    throw new Error("no input — pass --url, --file, or pipe JSON on stdin");
  }
  return JSON.parse(stdin);
}

const card = await loadCard();
const result = validateAgentCard(card);
const detail = result.ok ? `protocolVersion=${card.protocolVersion}` : result.errors.join("; ");
const ok = reportFinding(`GET /.well-known/agent-card.json schema (${label})`, result.ok, detail);
process.exit(ok ? 0 : 1);
