#!/usr/bin/env node
/**
 * @deprecated Use ./identyclaw.sh test (constitution suites). Overlaps test-auth-boundaries
 * and test-webhooks-p2p-suite; rodit-auth-be crypto is tested upstream.
 *
 * A2A P2P auth test suite with optional P2P webhook section.
 *
 * Usage:
 *   node scripts/test-a2a-p2p-suite.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /path/to/near-credentials.json \
 *     --local https://agent-c.dev.identyclaw.com:88 \
 *     --peer https://agent-a.dev.identyclaw.com:88 \
 *     [--peer-id <passport-token-id>] [--local-id agent-c] \
 *     [--peer-creds /path/to/peer-near.json] \
 *     [--config /home/node/.openclaw/openclaw.json] \
 *     [--skip-webhooks]
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { join, resolve } from "node:path";
import { applyNearRoditEnv, parseNearCreds } from "./lib-rodit-env.mjs";
import {
  fetchJson,
  loadNearCreds,
  runInboundWebhookFromLivePeer,
  runInboundWebhookFromPeer,
  runOutboundWebhookToPeer,
} from "./lib-rodit-webhook-test.mjs";
import { createTally, reportFinding, reportSkip } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const localBase = (arg("--local", "") || "").replace(/\/$/, "");
const peerBase = (arg("--peer", "") || "").replace(/\/$/, "");
const peerCredsPath = arg("--peer-creds", "") ? resolve(arg("--peer-creds", "")) : "";
const peerId = arg("--peer-id", "");
const localId = arg("--local-id", "");
const configPath = resolve(arg("--config", process.env.OPENCLAW_CONFIG || "/home/node/.openclaw/openclaw.json"));
const pluginDir = resolve(arg("--plugin-dir", "/home/node/.openclaw/extensions/identyclaw-webhooks/dist"));
const skipWebhooks = process.argv.includes("--skip-webhooks");
const simulateInbound = process.argv.includes("--simulate-inbound");

if (!extDir || !credPath || !localBase) {
  process.stderr.write(
    "usage: test-a2a-p2p-suite.mjs --ext-dir <a2a> --creds <near.json> --local <base-url> " +
      "[--peer <base-url>] [--peer-id <id>] [--local-id <id>] [--peer-creds <peer.json>] " +
      "[--config openclaw.json] [--skip-webhooks]\n",
  );
  process.exit(2);
}

const nearCreds = parseNearCreds(credPath);
applyNearRoditEnv(nearCreds);

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient, login_server } = require("@rodit/rodit-auth-be");

const A2A_BODY = JSON.stringify({
  jsonrpc: "2.0",
  id: "p2p-suite",
  method: "tasks/get",
  params: { id: "suite-smoke-nonexistent" },
});

const tally = createTally();

function record(category, surface, matchesContract, detail = "") {
  reportFinding(`[${category}] ${surface}`, matchesContract, detail);
  tally.add(matchesContract);
}

function skipCase(category, surface, detail = "") {
  reportSkip(`[${category}] ${surface}`, detail);
  tally.addSkip();
}

async function fetchStatus(url, init = {}) {
  const res = await fetch(url, init);
  const text = await res.text();
  return { status: res.status, text: text.slice(0, 300) };
}

async function getOwnConfig() {
  const client = await RoditClient.create({ role: "client" });
  return client.getConfigOwnRodit();
}

async function p2pJwt(peerBaseUrl) {
  const ownConfig = await getOwnConfig();
  const base = peerBaseUrl.replace(/\/$/, "");
  const cfg = {
    ...ownConfig,
    own_rodit: {
      ...ownConfig.own_rodit,
      metadata: {
        ...ownConfig.own_rodit.metadata,
        subjectuniqueidentifier_url: base,
      },
    },
  };
  const result = await login_server(cfg, {
    loginPath: "/api/login",
    timestampPath: "/api/login/timestamp",
  });
  if (!result?.jwt_token) throw new Error(result?.error || "P2P login returned no jwt_token");
  return result.jwt_token;
}

function decodeJwt(jwt) {
  try {
    return JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

async function postA2a(base, jwt, extraHeaders = {}) {
  const headers = { "content-type": "application/json", ...extraHeaders };
  if (jwt !== undefined && jwt !== null) {
    headers.authorization = jwt.startsWith("Bearer ") ? jwt : `Bearer ${jwt}`;
  }
  return fetchStatus(`${base}/a2a`, { method: "POST", headers, body: A2A_BODY });
}

async function runDiscovery(base, label) {
  const card = await fetchStatus(`${base}/.well-known/agent-card.json`);
  record("discovery", `GET /.well-known/agent-card.json (${label})`, card.status === 200, `HTTP ${card.status}`);
  const ts = await fetchStatus(`${base}/api/login/timestamp`);
  record("discovery", `GET /api/login/timestamp (${label})`, ts.status === 200, `HTTP ${ts.status}`);
}

async function runAuthWithP2pJwt(base, label) {
  try {
    const jwt = await p2pJwt(base);
    const claims = decodeJwt(jwt);
    const { status } = await postA2a(base, jwt);
    const matchesContract = status !== 401 && status !== 403;
    record(
      "auth",
      `POST /a2a with P2P JWT (${label})`,
      matchesContract,
      `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}…`,
    );
    return jwt;
  } catch (e) {
    record("auth", `POST /a2a with P2P JWT (${label})`, false, e.message);
    return null;
  }
}

async function runWebhookUnsigned(base, label) {
  const hook = await fetchStatus(`${base}/hooks/wake`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "suite-smoke" }),
  });
  if (hook.status === 404) {
    record(
      "webhook",
      `POST /hooks/wake without RODiT signature (${label})`,
      true,
      "HTTP 404 (route not exposed)",
    );
    return;
  }
  record(
    "webhook",
    `POST /hooks/wake without RODiT signature (${label})`,
    hook.status === 400 || hook.status === 401,
    `HTTP ${hook.status}`,
  );
}

async function runWebhookInvalidSignature(base, label, credsPath) {
  try {
    const signer = loadNearCreds(credsPath);
    const payload = JSON.stringify({ text: "invalid-sig-smoke", mode: "now" });
    const { status } = await fetchJson(`${base.replace(/\/$/, "")}/hooks/wake`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-signature": "deadbeef",
        "x-timestamp": Date.now().toString(),
        "x-rodit-token-id": signer.accountId,
      },
      body: payload,
    });
    record(
      "webhook",
      `POST /hooks/wake with invalid x-signature (${label})`,
      status === 401,
      `HTTP ${status}`,
    );
  } catch (e) {
    record("webhook", `POST /hooks/wake with invalid x-signature (${label})`, false, e.message);
  }
}

async function runWebhookSection() {
  if (skipWebhooks) {
    skipCase("webhook", "P2P webhook section", "--skip-webhooks");
    return;
  }

  process.stdout.write("\n--- P2P webhooks (send_rodit_webhook) ---\n");

  await runWebhookUnsigned(localBase, "local");
  if (peerBase) {
    await runWebhookUnsigned(peerBase, "peer");
  }

  await runWebhookInvalidSignature(localBase, "local", credPath);

  if (peerBase) {
    await runWebhookInvalidSignature(peerBase, "peer", credPath);

    process.stdout.write("\n  Outbound: we deliver webhooks to peer\n");

    if (!peerId) {
      skipCase("webhook", "send_rodit_webhook to peer", "no --peer-id");
      skipCase("webhook", "GET peer /hooks/_receipts", "no --peer-id");
    } else {
      try {
        const outbound = await runOutboundWebhookToPeer({
          configPath,
          pluginDir,
          localId: localId || "local",
          peerId,
          localCredsPath: credPath,
          peerBase,
          markerPrefix: "a2a-suite-outbound",
          delaySeconds: 0,
        });
        record("webhook", "send_rodit_webhook to peer", outbound.deliveredOk, outbound.deliveredDetail);
        record("webhook", "GET peer /hooks/_receipts", outbound.peerReceivedOk, outbound.peerReceivedDetail);
      } catch (e) {
        record("webhook", "send_rodit_webhook to peer", false, e.message);
        record("webhook", "GET peer /hooks/_receipts", false, "not run after send error");
      }
    }

    process.stdout.write("\n  Inbound: we receive webhooks from peer\n");

    if (localId) {
      try {
        const inbound =
          simulateInbound && peerCredsPath
            ? await runInboundWebhookFromPeer({
                configPath,
                pluginDir,
                localId,
                peerId,
                peerCredsPath,
                localBase,
                markerPrefix: "a2a-suite-inbound",
                delaySeconds: 0,
              })
            : await runInboundWebhookFromLivePeer({
                localId,
                peerId,
                peerBase,
                localBase,
                localCredsPath: credPath,
                markerPrefix: "a2a-suite-inbound",
                delaySeconds: 0,
              });
        record(
          "webhook",
          "peer send_rodit_webhook to local gateway",
          inbound.peerDeliveredOk,
          inbound.peerDeliveredDetail,
        );
        record("webhook", "GET local /hooks/_receipts", inbound.weReceivedOk, inbound.weReceivedDetail);
      } catch (e) {
        record("webhook", "peer send_rodit_webhook to local gateway", false, e.message);
        record("webhook", "GET local /hooks/_receipts", false, "not run after send error");
      }
    } else {
      skipCase("webhook", "peer send_rodit_webhook to local gateway", "no --local-id");
      skipCase("webhook", "GET local /hooks/_receipts", "inbound not run");
    }
  } else {
    skipCase("webhook", "send_rodit_webhook to peer", "no --peer base URL");
    skipCase("webhook", "peer send_rodit_webhook to local gateway", "no --peer base URL");
  }
}

async function main() {
  process.stdout.write(`\nA2A P2P test suite\n`);
  process.stdout.write(`  caller creds: ${nearCreds.accountId}\n`);
  process.stdout.write(`  local:  ${localBase}\n`);
  if (peerBase) process.stdout.write(`  peer:   ${peerBase}\n`);
  process.stdout.write("\n");

  await runDiscovery(localBase, "local");
  if (peerBase) await runDiscovery(peerBase, "peer");

  const localP2p = await runAuthWithP2pJwt(localBase, "local");

  let peerP2p = null;
  if (peerBase) {
    peerP2p = await runAuthWithP2pJwt(peerBase, "peer");
  }

  const { status: noAuth } = await postA2a(localBase, undefined);
  record(
    "auth",
    "POST /a2a without Authorization (local)",
    noAuth === 401 || noAuth === 403,
    `HTTP ${noAuth}`,
  );

  const { status: garbage } = await postA2a(localBase, "not-a-valid-jwt");
  record(
    "auth",
    "POST /a2a with malformed Bearer token (local)",
    garbage === 401 || garbage === 403,
    `HTTP ${garbage}`,
  );

  if (peerBase && peerP2p) {
    const peerP2pJwt = await p2pJwt(peerBase);
    const claims = decodeJwt(peerP2pJwt);
    const { status } = await postA2a(localBase, peerP2pJwt);
    record(
      "auth",
      "POST /a2a on local with peer-issued P2P JWT",
      status === 401 || status === 403,
      `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}…`,
    );
  }

  if (peerBase && localP2p) {
    const localP2pJwt = await p2pJwt(localBase);
    const claims = decodeJwt(localP2pJwt);
    const { status } = await postA2a(peerBase, localP2pJwt);
    record(
      "auth",
      "POST /a2a on peer with local-issued P2P JWT",
      status === 401 || status === 403,
      `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}…`,
    );
  }

  if (peerBase) {
    const { status: peerNoAuth } = await postA2a(peerBase, undefined);
    record(
      "auth",
      "POST /a2a without Authorization (peer)",
      peerNoAuth === 401 || peerNoAuth === 403,
      `HTTP ${peerNoAuth}`,
    );
  }

  await runWebhookSection();

  tally.printSummary("Summary");
  process.exit(tally.exitCode());
}

main().catch((e) => {
  process.stderr.write(`suite error: ${e.message}\n`);
  process.exit(1);
});
