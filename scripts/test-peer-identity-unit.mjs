#!/usr/bin/env node
/**
 * Unit tests for lib-peer-identity.mjs responder policy (no live API).
 *
 * Run: node scripts/test-peer-identity-unit.mjs
 */
import assert from "node:assert/strict";
import {
  contactUriToEmail,
  emailsMatch,
  isNonceReplayOnlyValidProbe,
  normalizeEmail,
  peerEmailFromIdentity,
  verifyInboundProbeHola,
} from "./lib-peer-identity.mjs";
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

async function runCaseAsync(surface, fn) {
  try {
    await fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

process.stdout.write("Peer identity policy (unit)\n\n");

runCase("contactUriToEmail mailto", () => {
  assert.equal(contactUriToEmail("mailto:user@example.com"), "user@example.com");
});

runCase("contactUriToEmail email: scheme", () => {
  assert.equal(contactUriToEmail("email:domain:user@example.com"), "user@example.com");
});

runCase("normalizeEmail and emailsMatch", () => {
  assert.equal(normalizeEmail("  User@Example.COM "), "user@example.com");
  assert.equal(emailsMatch("A@b.com", "a@B.com"), true);
  assert.equal(emailsMatch("a@b.com", "c@d.com"), false);
});

runCase("peerEmailFromIdentity contactUri", () => {
  assert.equal(
    peerEmailFromIdentity({ dn: { contactUri: "mailto:agent@identyclaw.com" } }),
    "agent@identyclaw.com",
  );
});

runCase("isNonceReplayOnlyValidProbe accepts replay-only", () => {
  const payload = {
    verified: false,
    failureReasons: ["nonce_replay"],
    checks: {
      signatureValid: true,
      checksumValid: true,
      timestampFresh: true,
      tokenExists: true,
      tokenActive: true,
    },
    peerTokenId: "peertokenid",
    destinatary: "owntokenid",
  };
  assert.equal(
    isNonceReplayOnlyValidProbe(payload, {
      ownTokenId: "owntokenid",
      senderTokenId: "peertokenid",
    }),
    true,
  );
});

runCase("isNonceReplayOnlyValidProbe rejects wrong reason", () => {
  const payload = {
    verified: false,
    failureReasons: ["signature_invalid"],
    checks: { signatureValid: false },
  };
  assert.equal(isNonceReplayOnlyValidProbe(payload, { ownTokenId: "own" }), false);
});

runCase("isNonceReplayOnlyValidProbe rejects peer mismatch", () => {
  const payload = {
    verified: false,
    failureReasons: ["nonce_replay"],
    checks: {
      signatureValid: true,
      checksumValid: true,
      timestampFresh: true,
      tokenExists: true,
      tokenActive: true,
    },
    peerTokenId: "otherpeer",
    destinatary: "own",
  };
  assert.equal(
    isNonceReplayOnlyValidProbe(payload, { ownTokenId: "own", senderTokenId: "sender" }),
    false,
  );
});

runCase("isNonceReplayOnlyValidProbe rejects dest mismatch", () => {
  const payload = {
    verified: false,
    failureReasons: ["nonce_replay"],
    checks: {
      signatureValid: true,
      checksumValid: true,
      timestampFresh: true,
      tokenExists: true,
      tokenActive: true,
    },
    peerTokenId: "peer",
    destinatary: "wrongdest",
  };
  assert.equal(
    isNonceReplayOnlyValidProbe(payload, { ownTokenId: "own", senderTokenId: "peer" }),
    false,
  );
});

runCase("isNonceReplayOnlyValidProbe rejects already verified", () => {
  assert.equal(isNonceReplayOnlyValidProbe({ verified: true }, { ownTokenId: "own" }), false);
});

await runCaseAsync("verifyInboundProbeHola strict verified", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    status: 200,
    json: async () => ({ verified: true, peerTokenId: "peertoken" }),
  });
  try {
    const result = await verifyInboundProbeHola("https://api.example.com", "jwt", "HOLA/line", {
      ownTokenId: "own",
    });
    assert.equal(result.verified, true);
    assert.equal(result.acceptedDespiteReplay, false);
    assert.equal(result.peerTokenId, "peertoken");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

await runCaseAsync("verifyInboundProbeHola nonce replay accepted", async () => {
  const replayPayload = {
    verified: false,
    failureReasons: ["nonce_replay"],
    checks: {
      signatureValid: true,
      checksumValid: true,
      timestampFresh: true,
      tokenExists: true,
      tokenActive: true,
    },
    peerTokenId: "peer",
    destinatary: "own",
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    status: 200,
    json: async () => replayPayload,
  });
  try {
    const result = await verifyInboundProbeHola("https://api.example.com", "jwt", "HOLA/line", {
      ownTokenId: "own",
      senderTokenId: "peer",
    });
    assert.equal(result.verified, true);
    assert.equal(result.acceptedDespiteReplay, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

await runCaseAsync("verifyInboundProbeHola bad signature rejected", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    status: 200,
    json: async () => ({
      verified: false,
      failureReasons: ["signature_invalid"],
      checks: { signatureValid: false },
    }),
  });
  try {
    const result = await verifyInboundProbeHola("https://api.example.com", "jwt", "HOLA/bad", {
      ownTokenId: "own",
    });
    assert.equal(result.verified, false);
    assert.equal(result.acceptedDespiteReplay, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
