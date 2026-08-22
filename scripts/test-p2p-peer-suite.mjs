#!/usr/bin/env node
/**
 * P2P / dual-mode A2A auth test suite.
 *
 * Run inside agent container (e.g. openclaw-agent-a):
 *   NODE_TLS_REJECT_UNAUTHORIZED=0 node test-p2p-peer-suite.mjs
 *
 * Env overrides:
 *   PEER_A_BASE  default https://agent-a.dev.identyclaw.com:8443  (agent-a)
 *   PEER_C_BASE  default https://agent-c.dev.identyclaw.com:8443  (agent-c)
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import https from "node:https";
import { createTally, runProbe } from "./lib-test-report.mjs";

const PEER_A = (process.env.PEER_A_BASE || "https://agent-a.dev.identyclaw.com:8443").replace(/\/$/, "");
const PEER_C = (process.env.PEER_C_BASE || process.env.PEER_D_BASE || "https://agent-c.dev.identyclaw.com:8443").replace(/\/$/, "");

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
const entries = JSON.parse(readFileSync(join(ocDir, "openclaw.json"), "utf8")).plugins.entries;
const a2aCfg = (entries["identyclaw-a2a"] || entries.a2a).config;
const inbound = a2aCfg.inbound?.auth || {};
const outboundCfg = a2aCfg.outbound;

const { defaultRoditPeerLogin } = await import(join(ext, "dist/auth/rodit-peer-login.js"));
const { createRoditOutboundAuthProvider } = await import(
  join(ext, "dist/auth/create-rodit-outbound-auth.js"),
);
const require = createRequire(pathToFileURL(join(ext, "package.json")));

function decodeJwt(token) {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
}

function httpsPost(url, headers, payload) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      {
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + (u.search || ""),
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

function a2aBody(label) {
  const msgId = `suite-${label}-${Date.now()}`;
  return JSON.stringify({
    jsonrpc: "2.0",
    id: msgId,
    method: "message/send",
    params: {
      message: {
        role: "user",
        parts: [{ kind: "text", text: `P2P suite: ${label}` }],
        messageId: msgId,
      },
    },
  });
}

async function postA2a(a2aUrl, jwt, label = "test") {
  const headers = { "Content-Type": "application/json" };
  if (jwt !== undefined) {
    headers.Authorization = jwt === null ? undefined : `Bearer ${jwt}`;
  }
  return httpsPost(a2aUrl, headers, a2aBody(label));
}

async function mediatedLogin() {
  const { RoditClient } = require("@rodit/rodit-auth-be");
  const client = await RoditClient.create({ role: "client" });
  const result = await client.login_server();
  if (!result?.jwt_token) {
    throw new Error(result?.error || "login_server returned no jwt_token");
  }
  return result.jwt_token;
}

async function p2pLogin(base) {
  return defaultRoditPeerLogin(base, { logLevel: "error" });
}

async function autoLogin() {
  const auto = createRoditOutboundAuthProvider(
    { ...outboundCfg.auth, mode: "auto" },
    outboundCfg.agents,
  );
  const peer = outboundCfg.agents?.["agent-c"];
  const hdr = await auto.getAuthorizationHeader({
    agentId: "agent-c",
    agentCardUrl: peer.url,
  });
  return hdr.replace(/^Bearer /, "");
}

function tamperJwt(jwt) {
  const parts = jwt.split(".");
  const sig = parts[2];
  const flipped = sig[0] === "a" ? "b" : "a";
  return `${parts[0]}.${parts[1]}.${flipped}${sig.slice(1)}`;
}

const tally = createTally();

console.log("P2P / dual-mode A2A test suite");
console.log(`  Local (agent-a):  ${PEER_A}`);
console.log(`  Peer  (agent-c): ${PEER_C}`);
console.log(`  Inbound mode: ${inbound.mode}, p2pAudience: ${inbound.p2pAudience?.slice(0, 16)}…`);
console.log("");

let jwtP2pB;
let jwtMediated;
let jwtP2pA;

try {
  jwtP2pB = await p2pLogin(PEER_C);
  jwtMediated = await mediatedLogin();
  jwtP2pA = await p2pLogin(PEER_A);
} catch (e) {
  console.error("suite setup error:", e instanceof Error ? e.message : e);
  process.exit(2);
}

const audP2pB = decodeJwt(jwtP2pB).aud;
const audMediated = decodeJwt(jwtMediated).aud;
const audP2pA = decodeJwt(jwtP2pA).aud;
console.log("JWT audiences:");
console.log(`  P2P→B:      ${audP2pB}`);
console.log(`  Mediated:   ${audMediated}`);
console.log(`  P2P→A:      ${audP2pA}`);
console.log("");

process.stdout.write("--- Auth probes ---\n");

await runProbe(tally, "POST /a2a on peer-b with P2P JWT", async () => {
  const r = await postA2a(`${PEER_C}/a2a`, jwtP2pB, "p2p-to-b");
  return {
    matchesContract: r.status >= 200 && r.status < 300,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b with central API JWT", async () => {
  const r = await postA2a(`${PEER_C}/a2a`, jwtMediated, "mediated-to-b");
  return {
    matchesContract: r.status >= 200 && r.status < 300,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b with auto outbound JWT", async () => {
  const jwt = await autoLogin();
  const r = await postA2a(`${PEER_C}/a2a`, jwt, "auto-to-b");
  return {
    matchesContract: r.status >= 200 && r.status < 300,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on local with P2P JWT", async () => {
  const r = await postA2a(`${PEER_A}/a2a`, jwtP2pA, "p2p-to-a");
  return {
    matchesContract: r.status >= 200 && r.status < 300,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on local with central API JWT", async () => {
  const r = await postA2a(`${PEER_A}/a2a`, jwtMediated, "mediated-to-a");
  return {
    matchesContract: r.status >= 200 && r.status < 300,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b without Authorization", async () => {
  const r = await postA2a(`${PEER_C}/a2a`, undefined, "no-auth-b");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b with malformed Bearer token", async () => {
  const r = await postA2a(`${PEER_C}/a2a`, "not.a.valid.jwt", "bad-jwt-b");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b with tampered P2P JWT", async () => {
  const r = await postA2a(`${PEER_C}/a2a`, tamperJwt(jwtP2pB), "tampered-b");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on local with peer-b P2P JWT", async () => {
  if (audP2pB === audP2pA) {
    throw new Error("skip: P2P audiences identical — cannot test cross-audience");
  }
  const r = await postA2a(`${PEER_A}/a2a`, jwtP2pB, "wrong-aud-a");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on peer-b with local P2P JWT", async () => {
  if (audP2pB === audP2pA) {
    throw new Error("skip: P2P audiences identical — cannot test cross-audience");
  }
  const r = await postA2a(`${PEER_C}/a2a`, jwtP2pA, "wrong-aud-b");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on local without Authorization", async () => {
  const r = await postA2a(`${PEER_A}/a2a`, undefined, "no-auth-a");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

await runProbe(tally, "POST /a2a on local with tampered central API JWT", async () => {
  const r = await postA2a(`${PEER_A}/a2a`, tamperJwt(jwtMediated), "tampered-a");
  return {
    matchesContract: r.status === 401,
    detail: `HTTP ${r.status}`,
  };
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
