#!/usr/bin/env node
/**
 * Unit tests for lib-agent-card-validate.mjs.
 *
 * Run: node scripts/test-agent-card-validate-unit.mjs
 */
import assert from "node:assert/strict";
import { validateAgentCard } from "./lib-agent-card-validate.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

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

const validCard = {
  protocolVersion: "0.3.0",
  url: "https://agent.example.com:7443",
  capabilities: { streaming: true },
  skills: [{ id: "default", name: "Default Agent" }],
};

process.stdout.write("Agent card schema (unit)\n\n");

runCase("validateAgentCard accepts minimal valid card", () => {
  const result = validateAgentCard(validCard);
  assert.equal(result.ok, true);
  assert.equal(result.errors.length, 0);
});

runCase("validateAgentCard rejects missing protocolVersion", () => {
  const { protocolVersion: _ignored, ...rest } = validCard;
  const result = validateAgentCard(rest);
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((e) => e.includes("protocolVersion")));
});

runCase("validateAgentCard rejects wrong protocolVersion", () => {
  const result = validateAgentCard({ ...validCard, protocolVersion: "0.2.0" });
  assert.equal(result.ok, false);
});

runCase("validateAgentCard rejects empty skills", () => {
  const result = validateAgentCard({ ...validCard, skills: [] });
  assert.equal(result.ok, false);
});

runCase("validateAgentCard rejects skill missing id", () => {
  const result = validateAgentCard({ ...validCard, skills: [{ name: "No Id" }] });
  assert.equal(result.ok, false);
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
