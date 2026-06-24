#!/usr/bin/env node
/**
 * Unit tests for peer gateway resolution (metadata.webhook_url → agent card URL).
 *
 * Run: node --test scripts/test-peer-gateway-resolution.mjs
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  peerRoditToAgentCardUrl,
  resolvePeerAgentCardUrl,
} from "./lib-peer-gateway-url.mjs";

test("happy path: mock nearorg_rpc_tokenfromroditid → agent card URL", async () => {
  const cardUrl = await resolvePeerAgentCardUrl("lncqsncdshcj", async (tokenId) => ({
    token_id: tokenId,
    metadata: { webhook_url: "https://peer:7443" },
  }));
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

test("happy path: peerRoditToAgentCardUrl from mocked chain record", () => {
  const cardUrl = peerRoditToAgentCardUrl({
    token_id: "lncqsncdshcj",
    metadata: { webhook_url: "https://peer:7443" },
  });
  assert.equal(cardUrl, "https://peer:7443/.well-known/agent-card.json");
});

test("missing webhook_url throws clear error", () => {
  assert.throws(
    () =>
      peerRoditToAgentCardUrl({
        token_id: "lncqsncdshcj",
        metadata: {},
      }),
    (err) => {
      assert.match(err.message, /no usable metadata\.webhook_url/);
      assert.match(err.message, /lncqsncdshcj/);
      return true;
    },
  );
});

test("missing webhook_url via mocked nearorg_rpc_tokenfromroditid throws clear error", async () => {
  await assert.rejects(
    () =>
      resolvePeerAgentCardUrl("bdbfsdcfsnbd", async () => ({
        token_id: "bdbfsdcfsnbd",
        metadata: {},
      })),
    (err) => {
      assert.match(err.message, /no usable metadata\.webhook_url/);
      assert.match(err.message, /bdbfsdcfsnbd/);
      return true;
    },
  );
});
