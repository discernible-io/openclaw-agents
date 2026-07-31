#!/usr/bin/env node
/**
 * Unit tests for lib-a2a-webhook-smoke-responder.mjs (no live agents).
 *
 * Run: node scripts/test-a2a-webhook-smoke-responder-unit.mjs
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  extractSmokeFromTask,
  parseWebhookSmokeInstruction,
  taskAlreadyDelivered,
} from "./lib-a2a-webhook-smoke-responder.mjs";
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

const smokeLine =
  'IDENTYCLAW_SMOKE inbound webhook test. Call tool send_rodit_webhook exactly once with: ' +
  'peerId="PeerTokenId12", text="marker-abc", delaySeconds=0, hookPath="hooks/wake"';

process.stdout.write("A2A webhook smoke responder (unit)\n\n");

runCase("parseWebhookSmokeInstruction valid", () => {
  const parsed = parseWebhookSmokeInstruction(smokeLine);
  assert.ok(parsed);
  assert.equal(parsed.peerId, "peertokenid12");
  assert.equal(parsed.text, "marker-abc");
  assert.equal(parsed.delaySeconds, 0);
  assert.equal(parsed.hookPath, "hooks/wake");
});

runCase("parseWebhookSmokeInstruction malformed", () => {
  assert.equal(parseWebhookSmokeInstruction("not a smoke instruction"), null);
});

runCase("extractSmokeFromTask from fixture", () => {
  const fixturePath = join(__dirname, "fixtures/a2a-inbound-task-webhook-smoke.json");
  const taskJson = JSON.parse(readFileSync(fixturePath, "utf8"));
  const extracted = extractSmokeFromTask(taskJson);
  assert.ok(extracted);
  assert.equal(extracted.taskId, "task-smoke-fixture-001");
  assert.equal(extracted.messageId, "msg-smoke-001");
  assert.equal(extracted.instruction.peerId, "abc123def456");
  assert.equal(extracted.instruction.hookPath, "hooks/custom-smoke");
});

runCase("taskAlreadyDelivered false when no artifacts", () => {
  const taskJson = { artifacts: [] };
  assert.equal(taskAlreadyDelivered(taskJson, "marker-xyz"), false);
});

runCase("taskAlreadyDelivered true when artifact reports ok", () => {
  const taskJson = {
    artifacts: [
      {
        parts: [{ text: '{"ok":true,"marker":"marker-xyz"}' }],
      },
    ],
  };
  assert.equal(taskAlreadyDelivered(taskJson, "marker-xyz"), true);
});

runCase("taskAlreadyDelivered true on send_rodit_webhook tool ok", () => {
  const taskJson = {
    artifacts: [
      {
        parts: [{ text: 'send_rodit_webhook result: {"ok":true}' }],
      },
    ],
  };
  assert.equal(taskAlreadyDelivered(taskJson, "any-marker"), true);
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
