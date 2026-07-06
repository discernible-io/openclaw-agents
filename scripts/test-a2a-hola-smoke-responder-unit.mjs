#!/usr/bin/env node
/**
 * Unit tests for lib-a2a-hola-smoke-responder.mjs (no live agents).
 *
 * Run: node scripts/test-a2a-hola-smoke-responder-unit.mjs
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  extractHolaSmokeFromTask,
  holaSmokeTaskAlreadyDelivered,
  parseHolaSmokeInstruction,
} from "./lib-a2a-hola-smoke-responder.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const tally = createTally();

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

const holaLine =
  'IDENTYCLAW_SMOKE inbound email HOLA test. Do exactly this: ' +
  '(1) call identyclaw_create_hola for recipient token_id "PeerTokenId12". ' +
  '(2) send an email via himalaya to "peer@example.com" with EXACT subject ' +
  '"IDENTYCLAW_HOLA_PROBE:hola-mail-in-123:good" and the HOLA line in the body. ' +
  "Reply with the subject line you sent.";

process.stdout.write("A2A HOLA smoke responder (unit)\n\n");

runCase("parseHolaSmokeInstruction valid", () => {
  const parsed = parseHolaSmokeInstruction(holaLine);
  assert.ok(parsed);
  assert.equal(parsed.recipientTokenId, "PeerTokenId12");
  assert.equal(parsed.toEmail, "peer@example.com");
  assert.equal(parsed.subject, "IDENTYCLAW_HOLA_PROBE:hola-mail-in-123:good");
});

runCase("parseHolaSmokeInstruction malformed", () => {
  assert.equal(parseHolaSmokeInstruction("not a hola smoke instruction"), null);
});

runCase("extractHolaSmokeFromTask from fixture", () => {
  const fixturePath = join(__dirname, "fixtures/a2a-inbound-task-hola-smoke.json");
  const taskJson = JSON.parse(readFileSync(fixturePath, "utf8"));
  const extracted = extractHolaSmokeFromTask(taskJson);
  assert.ok(extracted);
  assert.equal(extracted.taskId, "task-hola-smoke-fixture-001");
  assert.equal(extracted.messageId, "msg-hola-smoke-001");
  assert.equal(extracted.instruction.recipientTokenId, "lmsfckzncdbw");
  assert.equal(extracted.instruction.toEmail, "andrew@example.com");
});

runCase("holaSmokeTaskAlreadyDelivered false when no artifacts", () => {
  assert.equal(holaSmokeTaskAlreadyDelivered({ artifacts: [] }, "probe-subject"), false);
});

runCase("holaSmokeTaskAlreadyDelivered true when subject in artifact", () => {
  const taskJson = {
    artifacts: [{ parts: [{ text: "Sent IDENTYCLAW_HOLA_PROBE:hola-mail-in-1:good via himalaya" }] }],
  };
  assert.equal(
    holaSmokeTaskAlreadyDelivered(taskJson, "IDENTYCLAW_HOLA_PROBE:hola-mail-in-1:good"),
    true,
  );
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
