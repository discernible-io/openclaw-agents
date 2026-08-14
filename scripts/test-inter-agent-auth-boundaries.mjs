#!/usr/bin/env node
/**
 * Inter-agent auth boundary tests: channel isolation + mutual P2P JWT binding.
 *
 * Usage:
 *   node scripts/test-inter-agent-auth-boundaries.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/identyclaw-a2a \
 *     --creds /path/to/near-credentials.json \
 *     --local https://agent-c.example:88 \
 *     [--peer https://agent-a.example:88]
 */
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { applyNearRoditEnv, loadRoditAuthBe, parseNearCreds } from "./lib-rodit-env.mjs";
import { fetchJson, loadNearCreds } from "./lib-rodit-webhook-test.mjs";
import { createTally, reportFinding, reportSkip } from "./lib-test-report.mjs";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const localBase = (arg("--local", "") || "").replace(/\/$/, "");
const peerBase = (arg("--peer", "") || "").replace(/\/$/, "");

if (!extDir || !credPath || !localBase) {
  process.stderr.write(
    "usage: test-inter-agent-auth-boundaries.mjs --ext-dir <a2a> --creds <near.json> --local <base-url> [--peer <peer-base-url>]\n",
  );
  process.exit(2);
}

applyNearRoditEnv(parseNearCreds(credPath));

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient, login_server } = loadRoditAuthBe(extDir);

const A2A_BODY = JSON.stringify({
  jsonrpc: "2.0",
  id: "auth-boundary",
  method: "tasks/get",
  params: { id: "boundary-smoke-nonexistent" },
});

const tally = createTally();

function record(category, surface, matchesContract, detail = "") {
  const scoped = `[${category}] ${surface}`;
  return reportFinding(scoped, matchesContract, detail);
}

function recordSkip(category, surface, detail = "") {
  tally.addSkip();
  reportSkip(`[${category}] ${surface}`, detail);
}

function decodeJwt(jwt) {
  try {
    return JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString("utf8"));
  } catch {
    return {};
  }
}

function tamperJwt(jwt) {
  const parts = jwt.split(".");
  if (parts.length !== 3) return "not.a.jwt";
  const sig = parts[2];
  const flipped = sig[0] === "a" ? "b" : "a";
  return `${parts[0]}.${parts[1]}.${flipped}${sig.slice(1)}`;
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
  if (!result?.jwt_token) {
    throw new Error(result?.error || "P2P login_server failed");
  }
  return result.jwt_token;
}

async function apiMediatedJwt() {
  const client = await RoditClient.create({ role: "client" });
  const result = await client.login_server();
  if (!result?.jwt_token) {
    throw new Error(result?.error || "API login_server failed");
  }
  return result.jwt_token;
}

async function postA2a(base, jwt, extraHeaders = {}) {
  const headers = { "content-type": "application/json", ...extraHeaders };
  if (jwt !== undefined && jwt !== null) {
    headers.authorization = jwt.startsWith("Bearer ") ? jwt : `Bearer ${jwt}`;
  }
  return fetchJson(`${base.replace(/\/$/, "")}/a2a`, {
    method: "POST",
    headers,
    body: A2A_BODY,
  });
}

async function postHook(base, hookPath, body, headers = {}) {
  const url = `${base.replace(/\/$/, "")}/${hookPath.replace(/^\/+/, "")}`;
  return fetchJson(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body,
  });
}

async function webhookSignatureHeaders(body, timestampMs) {
  const client = await RoditClient.create({ role: "client" });
  const config = await client.getConfigOwnRodit();
  const privateKeyBytes = config?.own_rodit_bytes_private_key;
  if (!privateKeyBytes) {
    throw new Error("RoditConfig missing own_rodit_bytes_private_key for webhook signing");
  }
  const nacl = require("tweetnacl");
  const ts = String(timestampMs);
  const hash = crypto.createHash("sha256").update(body + ts).digest();
  const sig = nacl.sign.detached(hash, new Uint8Array(privateKeyBytes));
  const signer = loadNearCreds(credPath);
  return {
    "x-signature": Buffer.from(sig).toString("hex"),
    "x-timestamp": ts,
    "x-rodit-token-id": signer.accountId,
  };
}

async function runChannelIsolation() {
  process.stdout.write("\n--- Channel isolation ---\n");

  try {
    const jwt = await p2pJwt(localBase);
    const hookBody = JSON.stringify({ text: "boundary-jwt-on-hook", mode: "now" });
    const { status } = await postHook(localBase, "hooks/wake", hookBody, {
      authorization: `Bearer ${jwt}`,
    });
    const ok = record(
      "isolation",
      "POST /hooks/wake with A2A Bearer JWT only",
      status === 400 || status === 401,
      `HTTP ${status}`,
    );
    tally.add(ok);
  } catch (e) {
    tally.add(record("isolation", "POST /hooks/wake with A2A Bearer JWT only", false, e.message));
  }

  try {
    const hookBody = JSON.stringify({ text: "boundary-sig-on-a2a", mode: "now" });
    const sigHeaders = await webhookSignatureHeaders(hookBody, Date.now());
    const { status } = await postA2a(localBase, undefined, sigHeaders);
    tally.add(
      record(
        "isolation",
        "POST /a2a with RODiT webhook headers only",
        status === 401 || status === 403,
        `HTTP ${status}`,
      ),
    );
  } catch (e) {
    tally.add(record("isolation", "POST /a2a with RODiT webhook headers only", false, e.message));
  }

  try {
    const jwt = await apiMediatedJwt();
    const claims = decodeJwt(jwt);
    const { status } = await postA2a(localBase, jwt);
    tally.add(
      record(
        "isolation",
        "POST /a2a with central API JWT",
        status === 401 || status === 403,
        `HTTP ${status}, aud=${String(claims.aud || "").slice(0, 16)}…`,
      ),
    );
  } catch (e) {
    tally.add(record("isolation", "POST /a2a with central API JWT", false, e.message));
  }
}

async function runP2pBinding() {
  process.stdout.write("\n--- Mutual P2P JWT binding ---\n");

  try {
    const jwt = await p2pJwt(localBase);
    const tampered = tamperJwt(jwt);
    const { status } = await postA2a(localBase, tampered);
    tally.add(
      record(
        "p2p",
        "POST /a2a with tampered P2P JWT",
        status === 401 || status === 403,
        `HTTP ${status}`,
      ),
    );
  } catch (e) {
    tally.add(record("p2p", "POST /a2a with tampered P2P JWT", false, e.message));
  }

  if (!peerBase) {
    recordSkip("p2p", "POST /a2a with peer-issued P2P JWT on local gateway", "no --peer");
    recordSkip("p2p", "POST /a2a on peer with local-issued P2P JWT", "no --peer");
    return;
  }

  try {
    const peerJwt = await p2pJwt(peerBase);
    const claims = decodeJwt(peerJwt);
    const { status } = await postA2a(localBase, peerJwt);
    const localJwt = await p2pJwt(localBase);
    const localAud = decodeJwt(localJwt).aud;
    const peerAud = claims.aud;
    if (localAud && peerAud && localAud === peerAud) {
      recordSkip(
        "p2p",
        "POST /a2a with peer-issued P2P JWT on local gateway",
        "local and peer share same JWT aud — cannot test cross-audience",
      );
    } else {
      tally.add(
        record(
          "p2p",
          "POST /a2a with peer-issued P2P JWT on local gateway",
          status === 401 || status === 403,
          `HTTP ${status}, aud=${String(peerAud || "").slice(0, 16)}…`,
        ),
      );
    }
  } catch (e) {
    tally.add(record("p2p", "POST /a2a with peer-issued P2P JWT on local gateway", false, e.message));
  }

  try {
    const localJwt = await p2pJwt(localBase);
    const claims = decodeJwt(localJwt);
    const { status } = await postA2a(peerBase, localJwt);
    const peerJwt = await p2pJwt(peerBase);
    const localAud = claims.aud;
    const peerAud = decodeJwt(peerJwt).aud;
    if (localAud && peerAud && localAud === peerAud) {
      recordSkip(
        "p2p",
        "POST /a2a on peer with local-issued P2P JWT",
        "local and peer share same JWT aud — cannot test cross-audience",
      );
    } else {
      tally.add(
        record(
          "p2p",
          "POST /a2a on peer with local-issued P2P JWT",
          status === 401 || status === 403,
          `HTTP ${status}, aud=${String(localAud || "").slice(0, 16)}…`,
        ),
      );
    }
  } catch (e) {
    tally.add(record("p2p", "POST /a2a on peer with local-issued P2P JWT", false, e.message));
  }
}

async function runWebhookTimestamp() {
  process.stdout.write("\n--- Webhook timestamp skew ---\n");

  try {
    const hookBody = JSON.stringify({ text: "boundary-stale-ts", mode: "now" });
    const staleMs = Date.now() - 6 * 60 * 1000;
    const headers = await webhookSignatureHeaders(hookBody, staleMs);
    const { status } = await postHook(localBase, "hooks/wake", hookBody, headers);
    tally.add(
      record(
        "webhook",
        "POST /hooks/wake with stale x-timestamp",
        status === 400 || status === 401,
        `HTTP ${status}`,
      ),
    );
  } catch (e) {
    tally.add(record("webhook", "POST /hooks/wake with stale x-timestamp", false, e.message));
  }
}

async function main() {
  process.stdout.write("Inter-agent auth boundaries\n");
  process.stdout.write(`  local: ${localBase}\n`);
  if (peerBase) process.stdout.write(`  peer:  ${peerBase}\n`);

  await runChannelIsolation();
  await runP2pBinding();
  await runWebhookTimestamp();

  tally.printSummary("Summary");
  process.exit(tally.exitCode());
}

main().catch((e) => {
  process.stderr.write(`suite error: ${e.message}\n`);
  process.exit(1);
});
