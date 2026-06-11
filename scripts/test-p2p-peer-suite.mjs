#!/usr/bin/env node
/**
 * P2P / dual-mode A2A auth test suite (positive + negative cases).
 *
 * Run inside agent container (e.g. openclaw-agent-a):
 *   NODE_TLS_REJECT_UNAUTHORIZED=0 node test-p2p-peer-suite.mjs
 *
 * Env overrides:
 *   PEER_A_BASE  default https://agent-a.dihola.io:9443  (Juanelo inbound)
 *   PEER_B_BASE  default https://agent-b.dihola.io:4443  (Archimedes)
 */
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import https from "node:https";

// In pod: nginx listens on 4443 (host maps 9443→4443 for agent-a). Use 4443 from containers.
const PEER_A = (process.env.PEER_A_BASE || "https://agent-a.dihola.io:4443").replace(/\/$/, "");
const PEER_B = (process.env.PEER_B_BASE || "https://agent-b.dihola.io:4443").replace(/\/$/, "");

process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";
process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID || process.env.IDENTYCLAW_NEAR_CONTRACT_ID || "genaaaa-identyclaw-com.near";
process.env.IDENTYCLAW_BASE_URL = process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";

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

const ext = join(ocDir, "extensions/a2a");
const a2aCfg = JSON.parse(readFileSync(join(ocDir, "openclaw.json"), "utf8")).plugins.entries.a2a.config;
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
        throw new Error(result?.error || "mediated login failed");
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
    const peer = outboundCfg.agents?.["agent-b"];
    const hdr = await auto.getAuthorizationHeader({
        agentId: "agent-b",
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

const results = [];

async function runCase(id, category, description, fn) {
    process.stdout.write(`  [${category}] ${description} ... `);
    try {
        await fn();
        console.log("PASS");
        results.push({ id, category, description, ok: true });
    } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.log(`FAIL — ${msg}`);
        results.push({ id, category, description, ok: false, error: msg });
    }
}

function expect2xx(status, body) {
    if (status < 200 || status >= 300) {
        throw new Error(`expected 2xx, got HTTP ${status}: ${body.slice(0, 200)}`);
    }
}

function expect401(status, body) {
    if (status !== 401) {
        throw new Error(`expected HTTP 401, got ${status}: ${body.slice(0, 200)}`);
    }
}

console.log("P2P / dual-mode A2A test suite");
console.log(`  Local (Juanelo):  ${PEER_A}`);
console.log(`  Peer  (Archimedes): ${PEER_B}`);
console.log(`  Inbound mode: ${inbound.mode}, p2pAudience: ${inbound.p2pAudience?.slice(0, 16)}…`);
console.log("");

let jwtP2pB;
let jwtMediated;
let jwtP2pA;

try {
    jwtP2pB = await p2pLogin(PEER_B);
    jwtMediated = await mediatedLogin();
    jwtP2pA = await p2pLogin(PEER_A);
} catch (e) {
    console.error("Setup failed (could not acquire JWTs):", e instanceof Error ? e.message : e);
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

console.log("=== POSITIVE (should succeed) ===");

await runCase("P1", "positive", "P2P login → POST peer-b /a2a", async () => {
    const r = await postA2a(`${PEER_B}/a2a`, jwtP2pB, "p2p-to-b");
    expect2xx(r.status, r.body);
});

await runCase("P2", "positive", "Mediated login → POST peer-b /a2a (dual inbound)", async () => {
    const r = await postA2a(`${PEER_B}/a2a`, jwtMediated, "mediated-to-b");
    expect2xx(r.status, r.body);
});

await runCase("P3", "positive", "Auto outbound auth → POST peer-b /a2a", async () => {
    const jwt = await autoLogin();
    const r = await postA2a(`${PEER_B}/a2a`, jwt, "auto-to-b");
    expect2xx(r.status, r.body);
});

await runCase("P4", "positive", "P2P login → POST local /a2a (Juanelo inbound)", async () => {
    const r = await postA2a(`${PEER_A}/a2a`, jwtP2pA, "p2p-to-a");
    expect2xx(r.status, r.body);
});

await runCase("P5", "positive", "Mediated login → POST local /a2a (Juanelo dual inbound)", async () => {
    const r = await postA2a(`${PEER_A}/a2a`, jwtMediated, "mediated-to-a");
    expect2xx(r.status, r.body);
});

console.log("");
console.log("=== NEGATIVE (should be rejected) ===");

await runCase("N1", "negative", "No Authorization → peer-b /a2a → 401", async () => {
    const r = await postA2a(`${PEER_B}/a2a`, undefined, "no-auth-b");
    expect401(r.status, r.body);
});

await runCase("N2", "negative", "Malformed Bearer token → peer-b /a2a → 401", async () => {
    const r = await postA2a(`${PEER_B}/a2a`, "not.a.valid.jwt", "bad-jwt-b");
    expect401(r.status, r.body);
});

await runCase("N3", "negative", "Tampered P2P JWT signature → peer-b /a2a → 401", async () => {
    const r = await postA2a(`${PEER_B}/a2a`, tamperJwt(jwtP2pB), "tampered-b");
    expect401(r.status, r.body);
});

await runCase("N4", "negative", "P2P JWT for peer-b used on local /a2a (wrong aud) → 401", async () => {
    if (audP2pB === audP2pA) {
        throw new Error("skip: P2P audiences identical — cannot test cross-audience rejection");
    }
    const r = await postA2a(`${PEER_A}/a2a`, jwtP2pB, "wrong-aud-a");
    expect401(r.status, r.body);
});

await runCase("N5", "negative", "P2P JWT for local used on peer-b /a2a (wrong aud) → 401", async () => {
    if (audP2pB === audP2pA) {
        throw new Error("skip: P2P audiences identical — cannot test cross-audience rejection");
    }
    const r = await postA2a(`${PEER_B}/a2a`, jwtP2pA, "wrong-aud-b");
    expect401(r.status, r.body);
});

await runCase("N6", "negative", "No Authorization → local /a2a → 401", async () => {
    const r = await postA2a(`${PEER_A}/a2a`, undefined, "no-auth-a");
    expect401(r.status, r.body);
});

await runCase("N7", "negative", "Tampered mediated JWT → local /a2a → 401", async () => {
    const r = await postA2a(`${PEER_A}/a2a`, tamperJwt(jwtMediated), "tampered-a");
    expect401(r.status, r.body);
});

console.log("");
const passed = results.filter((r) => r.ok).length;
const failed = results.filter((r) => !r.ok);
console.log(`Summary: ${passed}/${results.length} passed`);
if (failed.length) {
    console.log("Failures:");
    for (const f of failed) {
        console.log(`  ${f.id} ${f.description}: ${f.error}`);
    }
    process.exit(1);
}
console.log("All tests passed.");
