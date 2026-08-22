#!/usr/bin/env node
/**
 * Hotfix identyclaw_request so LLM-passed JSON string bodies are not
 * double-encoded.
 *
 * Models (especially qwen3-coder) often pass:
 *   body: "{\"body\": \"...\"}"
 * instead of:
 *   body: { body: "..." }
 *
 * apiRequest then does JSON.stringify(opts.body), producing a JSON *string*
 * literal. Federated APIs reject that as INVALID_JSON / Malformed JSON.
 *
 * Idempotent. Safe to run after plugin install / on agent start.
 *
 * Usage:
 *   node scripts/patch-identyclaw-request-body.mjs [--root /home/node/.openclaw] [--dry-run]
 */
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
let root = "/home/node/.openclaw";
let dryRun = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--root") root = args[++i] ?? root;
  else if (args[i] === "--dry-run") dryRun = true;
}

const MARK = "identyclaw-request-body-string-patch-v1";
const TARGET = path.join(
  root,
  "extensions/identyclaw-tools/dist/index.js",
);

const FROM = `    if (opts.body !== undefined && method !== "GET" && method !== "DELETE") {
        headers["content-type"] = "application/json";
        init.body = JSON.stringify(opts.body);
    }`;

const TO = `    if (opts.body !== undefined && method !== "GET" && method !== "DELETE") {
        headers["content-type"] = "application/json";
        // ${MARK}: coerce LLM-stringified JSON objects/arrays before stringify
        let bodyPayload = opts.body;
        if (typeof bodyPayload === "string") {
            const trimmed = bodyPayload.trim();
            if ((trimmed.startsWith("{") && trimmed.endsWith("}")) ||
                (trimmed.startsWith("[") && trimmed.endsWith("]"))) {
                try {
                    bodyPayload = JSON.parse(trimmed);
                }
                catch {
                    /* keep original string */
                }
            }
        }
        init.body = JSON.stringify(bodyPayload);
    }`;

if (!fs.existsSync(TARGET)) {
  console.log(`skip: missing ${TARGET}`);
  process.exit(0);
}

const text = fs.readFileSync(TARGET, "utf8");
if (text.includes(MARK)) {
  console.log(`ok: already patched ${TARGET}`);
  process.exit(0);
}
if (!text.includes(FROM)) {
  console.error(`fail: target pattern not found in ${TARGET}`);
  process.exit(1);
}

if (dryRun) {
  console.log(`dry-run: would patch ${TARGET}`);
  process.exit(0);
}

fs.writeFileSync(TARGET, text.replace(FROM, TO), "utf8");
console.log(`patched: ${TARGET}`);
