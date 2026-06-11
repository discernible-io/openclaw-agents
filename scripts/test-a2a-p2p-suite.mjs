#!/usr/bin/env node
/**
 * A2A P2P + mediated auth test suite (positive and negative cases).
 * Includes a P2P webhook section: local creds sign → peer /hooks/wake (+ optional reply).
 *
 * Usage:
 *   node scripts/test-a2a-p2p-suite.mjs \
 *     --ext-dir /home/node/.openclaw/extensions/a2a \
 *     --creds /path/to/near-credentials.json \
 *     --local https://agent-b.dihola.io:4443 \
 *     --peer https://agent-a.dihola.io:9443 \
 *     [--peer-creds /path/to/peer-near.json] \
 *     [--skip-webhooks]
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join, resolve } from "node:path";
import { fetchJson, loadNearCreds, runP2pWebhookSend } from "./lib-rodit-webhook-test.mjs";

function arg(name, fallback = "") {
    const i = process.argv.indexOf(name);
    return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
const credPath = resolve(arg("--creds", ""));
const localBase = (arg("--local", "") || "").replace(/\/$/, "");
const peerBase = (arg("--peer", "") || "").replace(/\/$/, "");
const peerCredsPath = arg("--peer-creds", "") ? resolve(arg("--peer-creds", "")) : "";
const skipWebhooks = process.argv.includes("--skip-webhooks");

if (!extDir || !credPath || !localBase) {
    process.stderr.write(
        "usage: test-a2a-p2p-suite.mjs --ext-dir <a2a> --creds <near.json> --local <base-url> " +
            "[--peer <base-url>] [--peer-creds <peer.json>] [--skip-webhooks]\n",
    );
    process.exit(2);
}

const creds = JSON.parse(readFileSync(credPath, "utf8"));
const accountId = creds.implicit_account_id || creds.account_id || "";
const privateKey = creds.private_key || "";
if (!accountId || !privateKey) {
    process.stderr.write("credentials missing account_id or private_key\n");
    process.exit(1);
}

process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
process.env.IDENTYCLAW_ACCOUNT_ID = accountId;
process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = privateKey;
process.env.IDENTYCLAW_BASE_URL = process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";
process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID ||
    process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
    "genaaaa-identyclaw-com.near";
process.env.LOG_LEVEL = "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient, login_server } = require("@rodit/rodit-auth-be");

const A2A_BODY = JSON.stringify({
    jsonrpc: "2.0",
    id: "p2p-suite",
    method: "tasks/get",
    params: { id: "suite-smoke-nonexistent" },
});

const results = [];
let pass = 0;
let fail = 0;
let skip = 0;

function record(category, name, ok, detail = "") {
    results.push({ category, name, ok, detail });
    if (ok) pass++;
    else fail++;
    const mark = ok ? "PASS" : "FAIL";
    const line = detail ? `${mark}  [${category}] ${name} — ${detail}` : `${mark}  [${category}] ${name}`;
    process.stdout.write(`${line}\n`);
}

function recordSkip(category, name, detail = "") {
    skip++;
    const line = detail ? `SKIP  [${category}] ${name} — ${detail}` : `SKIP  [${category}] ${name}`;
    process.stdout.write(`${line}\n`);
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

async function mediatedJwt() {
    const client = await RoditClient.create({ role: "client" });
    const result = await client.login_server();
    if (!result?.jwt_token) throw new Error(result?.error || "mediated login failed");
    return result.jwt_token;
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
    if (!result?.jwt_token) throw new Error(result?.error || "P2P login failed");
    return result.jwt_token;
}

function decodeJwt(jwt) {
    try {
        return JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString("utf8"));
    } catch {
        return {};
    }
}

function corruptJwt(jwt) {
    const parts = jwt.split(".");
    if (parts.length !== 3) return "not.a.jwt";
    parts[2] = parts[2].slice(0, -4) + "XXXX";
    return parts.join(".");
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
    record("positive", `${label}: agent card public`, card.status === 200, `HTTP ${card.status}`);
    const ts = await fetchStatus(`${base}/api/login/timestamp`);
    record("positive", `${label}: P2P login timestamp`, ts.status === 200, `HTTP ${ts.status}`);
}

async function runPositiveAuth(base, label, jwtFn, authLabel) {
    try {
        const jwt = await jwtFn();
        const claims = decodeJwt(jwt);
        const { status, text } = await postA2a(base, jwt);
        const ok = status !== 401 && status !== 403;
        record(
            "positive",
            `${label}: ${authLabel} → POST /a2a`,
            ok,
            `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}…`,
        );
        return jwt;
    } catch (e) {
        record("positive", `${label}: ${authLabel} → POST /a2a`, false, e.message);
        return null;
    }
}

async function runNegative(base, label, name, jwtOrFn, expectUnauthorized = true) {
    try {
        const jwt = typeof jwtOrFn === "function" ? await jwtOrFn() : jwtOrFn;
        const { status } = await postA2a(base, jwt);
        const ok = expectUnauthorized ? status === 401 || status === 403 : status !== 401 && status !== 403;
        record(
            "negative",
            `${label}: ${name}`,
            ok,
            `HTTP ${status} (expected ${expectUnauthorized ? "401/403" : "not 401/403"})`,
        );
    } catch (e) {
        record("negative", `${label}: ${name}`, false, e.message);
    }
}

async function runWebhookNegative(base, label) {
    const hook = await fetchStatus(`${base}/hooks/wake`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text: "suite-smoke" }),
    });
    if (hook.status === 404) {
        record(
            "webhook",
            `${label}: POST /hooks/wake without RODiT signature`,
            true,
            "HTTP 404 (route not exposed — treated as blocked)",
        );
        return;
    }
    record(
        "webhook",
        `${label}: POST /hooks/wake without RODiT signature`,
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
        record("webhook", `${label}: invalid signature rejected`, status === 401, `HTTP ${status}`);
    } catch (e) {
        record("webhook", `${label}: invalid signature rejected`, false, e.message);
    }
}

async function runWebhookSection() {
    if (skipWebhooks) {
        recordSkip("webhook", "section", "--skip-webhooks");
        return;
    }

    process.stdout.write("\n--- P2P webhooks ---\n");

    await runWebhookNegative(localBase, "local");
    if (peerBase) {
        await runWebhookNegative(peerBase, "peer");
    }

    await runWebhookInvalidSignature(localBase, "local", credPath);

    if (peerBase) {
        await runWebhookInvalidSignature(peerBase, "peer", credPath);

        try {
            const outbound = await runP2pWebhookSend({
                extDir,
                signerCredsPath: credPath,
                receiverBase: peerBase,
                markerPrefix: "a2a-suite-webhook",
                senderLabel: "local",
                receiverLabel: "peer",
            });
            record(
                "webhook",
                "local → peer: P2P signed POST /hooks/wake",
                outbound.postOk,
                outbound.postDetail,
            );
            record(
                "webhook",
                "local → peer: receiver recorded webhook",
                outbound.receiptOk,
                outbound.receiptDetail,
            );
        } catch (e) {
            record("webhook", "local → peer: P2P signed POST /hooks/wake", false, e.message);
            record("webhook", "local → peer: receiver recorded webhook", false, "skipped after send failure");
        }

        if (peerCredsPath) {
            try {
                const inbound = await runP2pWebhookSend({
                    extDir,
                    signerCredsPath: peerCredsPath,
                    receiverBase: localBase,
                    markerPrefix: "a2a-suite-webhook",
                    senderLabel: "peer",
                    receiverLabel: "local",
                });
                record(
                    "webhook",
                    "peer → local: P2P signed POST /hooks/wake (reply)",
                    inbound.postOk,
                    inbound.postDetail,
                );
                record(
                    "webhook",
                    "peer → local: receiver recorded webhook",
                    inbound.receiptOk,
                    inbound.receiptDetail,
                );
            } catch (e) {
                record("webhook", "peer → local: P2P signed POST /hooks/wake (reply)", false, e.message);
                record("webhook", "peer → local: receiver recorded webhook", false, "skipped after send failure");
            }
        } else {
            recordSkip(
                "webhook",
                "peer → local P2P signed POST /hooks/wake (reply)",
                "no --peer-creds (place at secrets/peer-credentials/<peer>/*.json)",
            );
        }
    } else {
        recordSkip("webhook", "local → peer P2P signed POST", "no --peer base URL");
    }
}

async function main() {
    process.stdout.write(`\nA2A P2P test suite\n`);
    process.stdout.write(`  caller creds: ${accountId}\n`);
    process.stdout.write(`  local:  ${localBase}\n`);
    if (peerBase) process.stdout.write(`  peer:   ${peerBase}\n`);
    process.stdout.write("\n");

    // --- Discovery (positive) ---
    await runDiscovery(localBase, "local");
    if (peerBase) await runDiscovery(peerBase, "peer");

    // --- Positive auth on local ---
    const localMediated = await runPositiveAuth(localBase, "local", mediatedJwt, "mediated JWT");
    const localP2p = await runPositiveAuth(localBase, "local", () => p2pJwt(localBase), "P2P JWT");

    // --- Positive auth on peer ---
    let peerMediated = null;
    let peerP2p = null;
    if (peerBase) {
        peerMediated = await runPositiveAuth(peerBase, "peer", mediatedJwt, "mediated JWT");
        peerP2p = await runPositiveAuth(peerBase, "peer", () => p2pJwt(peerBase), "P2P JWT");
    }

    // --- Negative: no / bad auth ---
    const { status: noAuth } = await postA2a(localBase, undefined);
    record(
        "negative",
        "local: POST /a2a without Authorization",
        noAuth === 401 || noAuth === 403,
        `HTTP ${noAuth}`,
    );

    const { status: garbage } = await postA2a(localBase, "not-a-valid-jwt");
    record(
        "negative",
        "local: POST /a2a garbage Bearer token",
        garbage === 401 || garbage === 403,
        `HTTP ${garbage}`,
    );

    if (localMediated) {
        await runNegative(localBase, "local", "corrupted mediated JWT", corruptJwt(localMediated));
    }

    // Wrong-peer JWT: P2P login to peer, use on local (aud mismatch)
    if (peerBase && peerP2p) {
        const peerP2pJwt = await p2pJwt(peerBase);
        const claims = decodeJwt(peerP2pJwt);
        const { status } = await postA2a(localBase, peerP2pJwt);
        record(
            "negative",
            "local: peer-issued P2P JWT (wrong aud)",
            status === 401 || status === 403,
            `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}… (peer owner_id)`,
        );
    }

    // Wrong-peer JWT: P2P login to local, use on peer
    if (peerBase && localP2p) {
        const localP2pJwt = await p2pJwt(localBase);
        const claims = decodeJwt(localP2pJwt);
        const { status } = await postA2a(peerBase, localP2pJwt);
        record(
            "negative",
            "peer: local-issued P2P JWT (wrong aud)",
            status === 401 || status === 403,
            `HTTP ${status}, aud=${(claims.aud || "").slice(0, 16)}… (local owner_id)`,
        );
    }

    if (peerBase) {
        const { status: peerNoAuth } = await postA2a(peerBase, undefined);
        record(
            "negative",
            "peer: POST /a2a without Authorization",
            peerNoAuth === 401 || peerNoAuth === 403,
            `HTTP ${peerNoAuth}`,
        );
    }

    await runWebhookSection();

    process.stdout.write(`\n--- Summary: ${pass} passed, ${fail} failed${skip ? `, ${skip} skipped` : ""} ---\n`);
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    process.stderr.write(`suite error: ${e.message}\n`);
    process.exit(1);
});
