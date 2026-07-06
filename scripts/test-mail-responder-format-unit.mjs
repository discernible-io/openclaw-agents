#!/usr/bin/env node
/**
 * Unit tests for mail responder body format (no live mail).
 *
 * Run: node scripts/test-mail-responder-format-unit.mjs
 */
import assert from "node:assert/strict";
import {
  buildRejectionMailBody,
  mailRejectionOmitsHolaLine,
  resolveReplyRecipientEmail,
} from "./lib-mail-responder.mjs";
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

process.stdout.write("Mail responder format (unit)\n\n");

runCase("mailRejectionOmitsHolaLine on JSON-only rejection", () => {
  const body = buildRejectionMailBody(
    { probeId: "p1", variant: "bad", messageId: "m1" },
    "inbound HOLA did not verify",
  );
  assert.equal(mailRejectionOmitsHolaLine(body), true);
  assert.match(body, /"verified"\s*:\s*false/);
});

runCase("mailRejectionOmitsHolaLine detects HOLA credential line", () => {
  assert.equal(mailRejectionOmitsHolaLine("trailer\nHOLA/RECIPIENT/signer/TS/NONCE/API.IDENTYCLAW.COM/SIG/C\n"), false);
});

runCase("resolveReplyRecipientEmail prefers plain From header", () => {
  const email = resolveReplyRecipientEmail({
    plain: "From: Peer <peer@example.com>\n\nbody",
    envelope: { from: { addr: "other@example.com" } },
  });
  assert.equal(email, "peer@example.com");
});

runCase("resolveReplyRecipientEmail falls back to envelope from.addr", () => {
  const email = resolveReplyRecipientEmail({
    plain: "body without headers",
    envelope: { from: { name: "Peer", addr: "peer@example.com" } },
  });
  assert.equal(email, "peer@example.com");
});

runCase("resolveReplyRecipientEmail falls back to JSON from.contactUri", () => {
  const email = resolveReplyRecipientEmail({
    plain: "",
    jsonEnvelope: { from: { contactUri: "mailto:peer@example.com" } },
  });
  assert.equal(email, "peer@example.com");
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
