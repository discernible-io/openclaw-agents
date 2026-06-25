#!/usr/bin/env node
/**
 * Unit tests for peer gateway resolution (API metadata.webhook_url + chain fallback).
 *
 * Run: node scripts/test-peer-gateway-resolution.mjs
 */
import assert from "node:assert/strict";
import {
  identityFullToAgentCardUrl,
  peerRoditToAgentCardUrl,
  resolvePeerGatewayBase,
} from "./lib-peer-gateway-url.mjs";
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

process.stdout.write("Peer gateway resolution (unit)\n\n");

runCase("identityFullToAgentCardUrl from API metadata.webhook_url", () => {
  const cardUrl = identityFullToAgentCardUrl({
    tokenId: "lncqsncdshcj",
    metadata: { webhook_url: "https://peer:7443" },
  });
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

await runCaseAsync("resolvePeerGatewayBase from API /full metadata.webhook_url", async () => {
  const { base, source } = await resolvePeerGatewayBase("lncqsncdshcj", {
    fetchIdentityFull: async (tokenId) => ({
      tokenId,
      metadata: { webhook_url: "https://peer:7443" },
    }),
    fetchPeerRoditByTokenId: async () => {
      throw new Error("chain should not be called");
    },
  });
  assert.equal(base, "https://peer:7443");
  assert.equal(source, "api");
});

await runCaseAsync("resolvePeerGatewayBase on-chain fallback when API webhook_url missing", async () => {
  const { base, source } = await resolvePeerGatewayBase("lncqsncdshcj", {
    fetchIdentityFull: async (tokenId) => ({
      tokenId,
      metadata: { webhook_url: null },
    }),
    fetchPeerRoditByTokenId: async (tokenId) => ({
      token_id: tokenId,
      metadata: { webhook_url: "https://peer:7443" },
    }),
  });
  assert.equal(base, "https://peer:7443");
  assert.equal(source, "chain");
});

await runCaseAsync("resolvePeerGatewayBase on-chain fallback when API errors", async () => {
  const { base, source } = await resolvePeerGatewayBase("bdbfsdcfsnbd", {
    fetchIdentityFull: async () => {
      throw new Error("HTTP 503");
    },
    fetchPeerRoditByTokenId: async (tokenId) => ({
      token_id: tokenId,
      metadata: { webhook_url: "https://fallback.example.com:7443" },
    }),
  });
  assert.equal(base, "https://fallback.example.com:7443");
  assert.equal(source, "chain");
});

runCase("peerRoditToAgentCardUrl from on-chain rodit_token metadata", () => {
  const cardUrl = peerRoditToAgentCardUrl({
    token_id: "lncqsncdshcj",
    metadata: { webhook_url: "https://peer:7443" },
  });
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

await runCaseAsync("resolvePeerGatewayBase error when webhook_url missing on API and chain", async () => {
  await assert.rejects(
    () =>
      resolvePeerGatewayBase("lncqsncdshcj", {
        fetchIdentityFull: async (tokenId) => ({
          tokenId,
          metadata: {},
        }),
        fetchPeerRoditByTokenId: async (tokenId) => ({
          token_id: tokenId,
          metadata: {},
        }),
      }),
    (err) => {
      assert.match(err.message, /no usable metadata\.webhook_url/);
      assert.match(err.message, /lncqsncdshcj/);
      return true;
    },
  );
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
