#!/usr/bin/env node
/**
 * Unit tests for peer gateway resolution (API metadata.webhook_url + chain fallback).
 *
 * Run: node --test scripts/test-peer-gateway-resolution.mjs
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  identityFullToAgentCardUrl,
  peerRoditToAgentCardUrl,
  resolvePeerGatewayBase,
} from "./lib-peer-gateway-url.mjs";

test("happy path: API /full metadata.webhook_url → agent card URL", () => {
  const cardUrl = identityFullToAgentCardUrl({
    tokenId: "lncqsncdshcj",
    metadata: { webhook_url: "https://peer:7443" },
  });
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

test("happy path: API /full → gateway base (resolvePeerGatewayBase)", async () => {
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

test("fallback: API missing webhook_url → on-chain rodit_token", async () => {
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

test("fallback: API error → on-chain rodit_token", async () => {
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

test("happy path: peerRoditToAgentCardUrl from on-chain record", () => {
  const cardUrl = peerRoditToAgentCardUrl({
    token_id: "lncqsncdshcj",
    metadata: { webhook_url: "https://peer:7443" },
  });
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

test("missing webhook_url on API and chain throws clear error", async () => {
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
