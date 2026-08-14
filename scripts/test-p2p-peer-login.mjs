#!/usr/bin/env node
/**
 * Smoke test: P2P RODiT login to a peer gateway, then POST /a2a with the peer-issued JWT.
 * Usage: test-p2p-peer-login.mjs <peer-base-url> [a2a-url]
 *   test-p2p-peer-login.mjs --auto   (plugin auto provider → configured peer)
 *   test-p2p-peer-login.mjs --mediated (compare mediated login_server path)
 * Env: NEAR credentials via NEAR_CREDENTIALS_FILE_PATH or standard IDENTYCLAW_* + file layout.
 * Set NODE_TLS_REJECT_UNAUTHORIZED=0 when peers use self-signed TLS (dev).
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import https from "node:https";
import { reportFinding } from "./lib-test-report.mjs";

const mode = process.argv[2];
const isFlagMode = mode === "--auto" || mode === "--mediated";
const peerBase = (
  isFlagMode
    ? (process.argv[3] || "https://agent-c.dev.identyclaw.com:88")
    : (process.argv[2] || "https://agent-c.dev.identyclaw.com:88")
).replace(/\/$/, "");
let a2aUrl = (isFlagMode ? process.argv[4] : process.argv[3]) || `${peerBase}/a2a`;

process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";
process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CONTRACT_ID =
  process.env.NEAR_CONTRACT_ID || process.env.IDENTYCLAW_NEAR_CONTRACT_ID || "genaaaa-identyclaw-com.near";

const ocDir = process.env.OPENCLAW_HOME || "/home/node/.openclaw";
const credDir = join(ocDir, "secrets/near-credentials");
if (!process.env.NEAR_CREDENTIALS_FILE_PATH) {
  const credFile = readdirSync(credDir).find((f) => f.endsWith(".json"));
  if (!credFile) {
    console.error("No NEAR credentials in", credDir);
    process.exit(2);
  }
  process.env.NEAR_CREDENTIALS_FILE_PATH = join(credDir, credFile);
}
const creds = JSON.parse(readFileSync(process.env.NEAR_CREDENTIALS_FILE_PATH, "utf8"));
process.env.IDENTYCLAW_ACCOUNT_ID = creds.implicit_account_id || creds.account_id;
process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = creds.private_key;

const extCandidates = ["identyclaw-a2a", "a2a"];
const extName = extCandidates.find((name) =>
  existsSync(join(ocDir, "extensions", name, "dist/auth/rodit-peer-login.js")),
);
if (!extName) {
  console.error("A2A plugin not found under", join(ocDir, "extensions"));
  process.exit(2);
}
const ext = join(ocDir, "extensions", extName);

const { defaultRoditPeerLogin } = await import(join(ext, "dist/auth/rodit-peer-login.js"));
const { createRoditOutboundAuthProvider } = await import(
  join(ext, "dist/auth/create-rodit-outbound-auth.js"),
);
const require = createRequire(pathToFileURL(join(ext, "package.json")));
const entries = JSON.parse(readFileSync(join(ocDir, "openclaw.json"), "utf8")).plugins.entries;
const outboundCfg = (entries["identyclaw-a2a"] || entries.a2a).config.outbound;

function decodeJwt(token) {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
}

let p2pJwt;
let loginLabel = "P2P";

if (mode === "--mediated") {
  loginLabel = "Mediated";
  console.log("==> login_server → IdentyClaw API (Passport subjectuniqueidentifier_url)");
  const { RoditClient } = require("@rodit/rodit-auth-be");
  const client = await RoditClient.create({ role: "client" });
  console.log(`    API base: ${client.apiendpoint || "(from passport)"}`);
  const result = await client.login_server();
  if (!result?.jwt_token) {
    reportFinding("login_server", false, result?.error || "no jwt_token");
    process.exit(1);
  }
  p2pJwt = result.jwt_token;
  reportFinding("login_server", true, `jwt len=${p2pJwt.length}`);
} else if (mode === "--auto") {
  loginLabel = "Auto";
  console.log("==> Plugin outbound auth mode=auto");
  const auto = createRoditOutboundAuthProvider(
    { ...outboundCfg.auth, mode: "auto" },
    outboundCfg.agents,
  );
  const peerId = Object.keys(outboundCfg.agents || {})[0];
  const peer = peerId ? outboundCfg.agents?.[peerId] : undefined;
  if (!peer?.url) {
    console.error("No outbound peer configured in openclaw.json");
    process.exit(2);
  }
  const peerBaseFromCard = peer.url.replace(/\/\.well-known\/agent-card\.json$/, "");
  if (!isFlagMode || process.argv[3] === undefined) {
    a2aUrl = `${peerBaseFromCard}/a2a`;
  }
  const hdr = await auto.getAuthorizationHeader({
    agentId: peerId,
    agentCardUrl: peer.url,
  });
  p2pJwt = hdr.replace(/^Bearer /, "");
  reportFinding("outbound auth auto provider", true, `jwt len=${p2pJwt.length}, peer=${peerId}`);
  console.log("Auto peer:", peerId, "→", a2aUrl);
} else {
  console.log("==> P2P login_server →", peerBase + "/api/login");
  try {
    p2pJwt = await defaultRoditPeerLogin(peerBase, { logLevel: "error" });
    reportFinding(`P2P login_server at ${peerBase}`, true, `jwt len=${p2pJwt.length}`);
  } catch (e) {
    reportFinding(`P2P login_server at ${peerBase}`, false, e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}

const payload = decodeJwt(p2pJwt);
console.log(
  loginLabel + " JWT claims:",
  JSON.stringify(
    { iss: payload.iss, aud: payload.aud, rodit_id: payload.rodit_id || payload.token_id },
    null,
    2,
  ),
);

const msgId = "p2p-peer-test-" + Date.now();
const body = JSON.stringify({
  jsonrpc: "2.0",
  id: msgId,
  method: "message/send",
  params: {
    message: {
      role: "user",
      parts: [{ kind: "text", text: "P2P login peer test from identyclaw-agents smoke script" }],
      messageId: msgId,
    },
  },
});

function httpsPost(url, headers, payload) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      {
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname,
        method: "POST",
        rejectUnauthorized: false,
        headers: { ...headers, "Content-Length": Buffer.byteLength(payload) },
      },
      (res) => {
        let d = "";
        res.on("data", (c) => (d += c));
        res.on("end", () => resolve({ status: res.statusCode, body: d }));
      },
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

console.log("\n==> POST", a2aUrl, "with", loginLabel, "JWT");
const result = await httpsPost(
  a2aUrl,
  { "Content-Type": "application/json", Authorization: "Bearer " + p2pJwt },
  body,
);
console.log("HTTP", result.status);
console.log(result.body.slice(0, 800));

const matchesContract = result.status >= 200 && result.status < 300;
reportFinding(`POST /a2a with ${loginLabel} JWT`, matchesContract, `HTTP ${result.status}`);
process.exit(matchesContract ? 0 : 1);
