#!/usr/bin/env node
/**
 * Unit tests for lib-hola.mjs format/parsing (no live API or rodit-auth-be).
 *
 * Run: node scripts/test-hola-format-unit.mjs
 */
import assert from "node:assert/strict";
import {
  buildCollaborationEnvelope,
  computeHolaChecksum,
  extractHolaFromText,
  formatEmailBody,
  tamperHolaChecksum,
} from "./lib-hola.mjs";
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

process.stdout.write("HOLA format/parsing (unit)\n\n");

runCase("computeHolaChecksum is deterministic", () => {
  const prefix = "HOLA/RECIPIENT/SIGNER/2026-01-01T00:00:00.000Z/ABCD/API.IDENTYCLAW.COM/SIG/";
  assert.equal(computeHolaChecksum(prefix), computeHolaChecksum(prefix));
  assert.match(computeHolaChecksum(prefix), /^[A-Z]$/);
});

runCase("computeHolaChecksum changes with input", () => {
  const a = computeHolaChecksum("HOLA/A/");
  const b = computeHolaChecksum("HOLA/B/");
  assert.notEqual(a, b);
});

runCase("tamperHolaChecksum alters trailing checksum char", () => {
  const hola = "HOLA/RECIPIENT/signer/2026-01-01T00:00:00.000Z/ABCD/API.IDENTYCLAW.COM/SIGBASE32/A";
  const tampered = tamperHolaChecksum(hola);
  assert.match(tampered, /^HOLA\//);
  assert.notEqual(tampered.at(-1), hola.at(-1));
  assert.equal(tampered.slice(0, -1), hola.slice(0, -1));
});

runCase("extractHolaFromText plain trailing line", () => {
  const hola = "HOLA/RECIPIENT/signer/2026-01-01T00:00:00.000Z/ABCD/API.IDENTYCLAW.COM/SIGBASE32/A";
  const text = `Hello\n\n${hola}`;
  assert.equal(extractHolaFromText(text), hola);
});

runCase("extractHolaFromText JSON envelope", () => {
  const hola = "HOLA/RECIPIENT/signer/2026-01-01T00:00:00.000Z/ABCD/API.IDENTYCLAW.COM/SIGBASE32/B";
  const text = `preamble\n{"schema":"identyclaw.collaboration.v1","hola":"${hola}"}\n`;
  assert.equal(extractHolaFromText(text), hola);
});

runCase("extractHolaFromText RFC 5322 soft line break", () => {
  const hola = "HOLA/RECIPIENT/signer/2026-01-01T00:00:00.000Z/ABCD/API.IDENTYCLAW.COM/SIGBASE32/C";
  const part1 = hola.slice(0, 40);
  const part2 = hola.slice(40);
  const text = `${part1}\r\n ${part2}`;
  assert.equal(extractHolaFromText(text), hola);
});

runCase("extractHolaFromText negative", () => {
  assert.equal(extractHolaFromText("no credential here"), "");
});

runCase("buildCollaborationEnvelope shape", () => {
  const env = buildCollaborationEnvelope({
    messageId: "msg-1",
    fromTokenId: "sender",
    toTokenId: "recipient",
    contactUri: "mailto:peer@example.com",
    hola: "HOLA/line",
    variant: "good",
    probeId: "probe-1",
  });
  assert.equal(env.schema, "identyclaw.collaboration.v1");
  assert.equal(env.task.type, "HOLA_PROBE");
  assert.equal(env.task.payload.variant, "good");
  assert.equal(env.channelHints.replyVia, "contactUri");
});

runCase("formatEmailBody includes JSON and HOLA line", () => {
  const env = buildCollaborationEnvelope({
    messageId: "msg-2",
    fromTokenId: "sender",
    toTokenId: "recipient",
    contactUri: "mailto:peer@example.com",
    hola: "HOLA/RECIPIENT/signer/TS/NONCE/API.IDENTYCLAW.COM/SIG/D",
    variant: "good",
    probeId: "probe-2",
  });
  const body = formatEmailBody(env);
  assert.match(body, /identyclaw\.collaboration\.v1/);
  assert.match(body, /HOLA\/RECIPIENT/);
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
