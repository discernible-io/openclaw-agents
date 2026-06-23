#!/usr/bin/env node
/**
 * Smoke-test A2A inbound auth with P2P RODiT JWT.
 *
 * Usage:
 *   node scripts/test-a2a-rodit-auth.mjs \
 *     --ext-dir ../identyclaw-agents-app/agents/agent-b/extensions/identyclaw-a2a \
 *     --creds ../identyclaw-agents-app/agents/agent-b/secrets/near-credentials/*.json \
 *     --target https://agent-b.dev.identyclaw.com:7443
 */
import { createRequire } from "node:module";
import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

function arg(name, fallback = "") {
    const i = process.argv.indexOf(name);
    return i >= 0 ? process.argv[i + 1] : fallback;
}

const extDir = resolve(arg("--ext-dir", ""));
let credPath = resolve(arg("--creds", ""));
const targetBase = (arg("--target", "") || "").replace(/\/$/, "");

if (!extDir || !targetBase) {
    process.stderr.write(
        "usage: test-a2a-rodit-auth.mjs --ext-dir <a2a-plugin> --creds <near.json> --target <base-url>\n",
    );
    process.exit(2);
}

if (credPath.includes("*")) {
    const dir = dirname(credPath);
    const base = credPath.split("/").pop();
    const name = base.replace("*", "");
    const hit = readdirSync(dir).find((f) => f.endsWith(".json") && f.includes(name.replace(".json", "")));
    credPath = hit ? join(dir, hit) : credPath;
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
process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
process.env.SUPPRESS_STRICTNESS_CHECK = "true";

const pkgPath = join(extDir, "package.json");
const require = createRequire(pathToFileURL(pkgPath));
const { RoditClient, login_server } = require("@rodit/rodit-auth-be");

async function getOwnConfig() {
    const client = await RoditClient.create({ role: "client" });
    return client.getConfigOwnRodit();
}

async function p2pJwt(peerBase) {
    const ownConfig = await getOwnConfig();
    const base = peerBase.replace(/\/$/, "");
    const withPeer = {
        ...ownConfig,
        own_rodit: {
            ...ownConfig.own_rodit,
            metadata: {
                ...ownConfig.own_rodit.metadata,
                subjectuniqueidentifier_url: base,
            },
        },
    };
    const result = await login_server(withPeer, {
        loginPath: "/api/login",
        timestampPath: "/api/login/timestamp",
    });
    if (!result?.jwt_token) {
        throw new Error(result?.error || "P2P login_server failed");
    }
    return result.jwt_token;
}

async function postA2a(jwt) {
    const res = await fetch(`${targetBase}/a2a`, {
        method: "POST",
        headers: {
            "content-type": "application/json",
            authorization: `Bearer ${jwt}`,
        },
        body: JSON.stringify({
            jsonrpc: "2.0",
            id: "rodit-auth-smoke",
            method: "tasks/get",
            params: { id: "smoke-nonexistent" },
        }),
    });
    const text = await res.text();
    return { status: res.status, body: text.slice(0, 200) };
}

function decodeAud(jwt) {
    try {
        const payload = JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString("utf8"));
        return payload.aud || "(no aud)";
    } catch {
        return "(decode failed)";
    }
}

async function runP2pAuth() {
    process.stdout.write("\n==> P2P login → A2A\n");
    const jwt = await p2pJwt(targetBase);
    process.stdout.write(`    JWT aud: ${decodeAud(jwt)}\n`);
    const { status, body } = await postA2a(jwt);
    process.stdout.write(`    POST ${targetBase}/a2a → HTTP ${status}\n`);
    if (body) {
        process.stdout.write(`    body: ${body}\n`);
    }
    if (status === 401 || status === 403) {
        process.stderr.write(`FAIL: P2P login → A2A rejected (HTTP ${status})\n`);
        return false;
    }
    process.stdout.write(`OK: P2P login → A2A accepted (HTTP ${status})\n`);
    return true;
}

const ok = await runP2pAuth();
process.exit(ok ? 0 : 1);
