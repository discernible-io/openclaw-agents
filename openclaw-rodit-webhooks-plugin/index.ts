import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import nacl from "tweetnacl";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { requestHeartbeat } from "openclaw/plugin-sdk/heartbeat-runtime";
import { enqueueSystemEvent } from "openclaw/plugin-sdk/system-event-runtime";

type IncomingMessage = {
    method?: string;
    headers: Record<string, string | string[] | undefined>;
    on(event: "data", listener: (chunk: Buffer) => void): void;
    on(event: "end", listener: () => void): void;
    on(event: "error", listener: (err: Error) => void): void;
};

type ServerResponse = {
    statusCode: number;
    setHeader(name: string, value: string): void;
    end(chunk?: string): void;
};

type PluginConfig = {
    endpoints?: string[];
    logLevel?: string;
};

const DEFAULT_ENDPOINTS = ["/hooks/wake", "/hooks/agent"];
const MAX_BODY_BYTES = 256 * 1024;

function headerValue(headers: IncomingMessage["headers"], name: string): string {
    const raw = headers[name] ?? headers[name.toLowerCase()];
    if (Array.isArray(raw)) return raw[0] ?? "";
    return raw ?? "";
}

function sendJson(res: ServerResponse, status: number, body: Record<string, unknown>) {
    res.statusCode = status;
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.end(JSON.stringify(body));
}

async function readRawBody(req: IncomingMessage): Promise<string> {
    return await new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let total = 0;
        req.on("data", (chunk) => {
            total += chunk.length;
            if (total > MAX_BODY_BYTES) {
                reject(new Error("payload too large"));
                return;
            }
            chunks.push(chunk);
        });
        req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
        req.on("error", reject);
    });
}

function resolveMainSessionKey(cfg: Record<string, unknown>): string {
    const session = cfg.session as { scope?: string; mainKey?: string } | undefined;
    if (session?.scope === "global") return "global";
    const agents = cfg.agents as { list?: Array<{ id?: string; default?: boolean }> } | undefined;
    const list = Array.isArray(agents?.list) ? agents.list : [];
    const agentId = list.find((entry) => entry?.default)?.id ?? list[0]?.id ?? "main";
    const mainKey = session?.mainKey ?? "main";
    return `agent:${agentId}:${mainKey}`;
}

const WEBHOOK_TIMESTAMP_MAX_AGE_MS = 5 * 60 * 1000;

function signerPublicKeyBytes(tokenId: string): Uint8Array {
    const hex = tokenId.trim().toLowerCase();
    if (!/^[0-9a-f]+$/.test(hex) || hex.length % 2 !== 0) {
        throw new Error("invalid token id");
    }
    const bytes = new Uint8Array(Buffer.from(hex, "hex"));
    if (bytes.length !== nacl.sign.publicKeyLength) {
        throw new Error("invalid signer public key length");
    }
    return bytes;
}

function verifyRoditWebhookSignature(
    rawBody: string,
    signatureHex: string,
    timestamp: string,
    tokenId: string,
): { ok: true } | { ok: false; status: number; error: string } {
    const parsedTimestamp = Number.parseInt(timestamp, 10);
    if (!Number.isFinite(parsedTimestamp)) {
        return { ok: false, status: 400, error: "invalid timestamp" };
    }
    if (Date.now() - parsedTimestamp > WEBHOOK_TIMESTAMP_MAX_AGE_MS) {
        return { ok: false, status: 401, error: "webhook timestamp is too old" };
    }
    if (!/^[0-9a-fA-F]+$/.test(signatureHex) || signatureHex.length % 2 !== 0) {
        return { ok: false, status: 401, error: "invalid signature" };
    }
    let publicKey: Uint8Array;
    try {
        publicKey = signerPublicKeyBytes(tokenId);
    } catch {
        return { ok: false, status: 400, error: "invalid x-rodit-token-id" };
    }
    const payloadWithTimestamp = rawBody + timestamp;
    const hash = createHash("sha256").update(payloadWithTimestamp).digest();
    const signature = new Uint8Array(Buffer.from(signatureHex, "hex"));
    if (signature.length !== nacl.sign.signatureLength) {
        return { ok: false, status: 401, error: "invalid signature" };
    }
    let valid = false;
    try {
        valid = nacl.sign.detached.verify(new Uint8Array(hash), signature, publicKey);
    } catch {
        return { ok: false, status: 401, error: "invalid webhook signature" };
    }
    if (!valid) {
        return { ok: false, status: 401, error: "invalid webhook signature" };
    }
    return { ok: true };
}

function normalizeWakePayload(payload: unknown): { ok: true; value: { text: string; mode: "now" | "next-heartbeat" } } | { ok: false; error: string } {
    if (!payload || typeof payload !== "object") {
        return { ok: false, error: "payload must be an object" };
    }
    const text = (payload as { text?: unknown }).text;
    if (typeof text !== "string" || !text.trim()) {
        return { ok: false, error: "text is required" };
    }
    const modeRaw = (payload as { mode?: unknown }).mode;
    const mode = modeRaw === "next-heartbeat" ? "next-heartbeat" : "now";
    return { ok: true, value: { text: text.trim(), mode } };
}

function normalizeAgentPayload(payload: unknown): { ok: true; value: { message: string } } | { ok: false; error: string } {
    if (!payload || typeof payload !== "object") {
        return { ok: false, error: "payload must be an object" };
    }
    const message = (payload as { message?: unknown }).message;
    if (typeof message !== "string" || !message.trim()) {
        return { ok: false, error: "message is required" };
    }
    return { ok: true, value: { message: message.trim() } };
}

export default definePluginEntry({
    id: "rodit-webhooks",
    name: "RODiT Webhooks",
    description: "Inbound OpenClaw webhooks with RODiT Ed25519 origin signatures (x-signature + x-timestamp)",
    register(api) {
        const pluginConfig = (api.pluginConfig ?? {}) as PluginConfig;
        const endpoints = pluginConfig.endpoints?.length ? pluginConfig.endpoints : DEFAULT_ENDPOINTS;
        const logLevel = pluginConfig.logLevel ?? "error";
        process.env.LOG_LEVEL = process.env.LOG_LEVEL || logLevel;
        process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
        process.env.SUPPRESS_STRICTNESS_CHECK = "true";

        const verifyRoditWebhook = (req: IncomingMessage, rawBody: string) => {
            const signature = headerValue(req.headers, "x-signature");
            const timestamp = headerValue(req.headers, "x-timestamp");
            const tokenId = headerValue(req.headers, "x-rodit-token-id");
            if (!signature || !timestamp || !rawBody) {
                return { ok: false as const, status: 400, error: "Missing required authentication parameters" };
            }
            if (!tokenId) {
                return { ok: false as const, status: 400, error: "Missing x-rodit-token-id header" };
            }
            const verified = verifyRoditWebhookSignature(rawBody, signature, timestamp, tokenId);
            if (!verified.ok) {
                return { ok: false as const, status: verified.status, error: verified.error };
            }
            return { ok: true as const };
        };

        const handleWake = async (payload: unknown, res: ServerResponse) => {
            const normalized = normalizeWakePayload(payload);
            if (!normalized.ok) {
                sendJson(res, 400, { ok: false, error: normalized.error });
                return;
            }
            const cfg = api.runtime.config.loadConfig() as Record<string, unknown>;
            const sessionKey = resolveMainSessionKey(cfg);
            enqueueSystemEvent(normalized.value.text, { sessionKey });
            if (normalized.value.mode === "now") {
                requestHeartbeat({
                    source: "hook",
                    intent: "immediate",
                    reason: "rodit-webhook:wake",
                });
            }
            sendJson(res, 200, { ok: true, mode: normalized.value.mode });
        };

        const handleAgent = async (payload: unknown, res: ServerResponse) => {
            const normalized = normalizeAgentPayload(payload);
            if (!normalized.ok) {
                sendJson(res, 400, { ok: false, error: normalized.error });
                return;
            }
            const run = await api.runtime.subagent.run({
                message: normalized.value.message,
                label: "rodit-webhook",
                deliver: false,
            });
            sendJson(res, 200, { ok: true, runId: run?.runId ?? run?.id ?? null });
        };

        for (const endpoint of endpoints) {
            const path = endpoint.startsWith("/") ? endpoint : `/${endpoint}`;
            api.registerHttpRoute({
                path,
                auth: "plugin",
                match: "exact",
                replaceExisting: true,
                handler: async (req, res) => {
                    if (req.method !== "POST") {
                        res.statusCode = 405;
                        res.setHeader("Allow", "POST");
                        res.end("Method Not Allowed");
                        return;
                    }
                    const contentType = headerValue(req.headers, "content-type");
                    if (!contentType.toLowerCase().includes("application/json")) {
                        sendJson(res, 415, { ok: false, error: "Content-Type must be application/json" });
                        return;
                    }
                    let rawBody = "";
                    try {
                        rawBody = await readRawBody(req);
                    } catch (err) {
                        const message = err instanceof Error ? err.message : String(err);
                        const status = message === "payload too large" ? 413 : 400;
                        sendJson(res, status, { ok: false, error: message });
                        return;
                    }
                    const verified = verifyRoditWebhook(req, rawBody);
                    if (!verified.ok) {
                        sendJson(res, verified.status, { ok: false, error: verified.error });
                        return;
                    }
                    let payload: unknown;
                    try {
                        payload = rawBody ? JSON.parse(rawBody) : {};
                    } catch {
                        sendJson(res, 400, { ok: false, error: "invalid JSON payload" });
                        return;
                    }
                    if (path === "/hooks/wake" || path.endsWith("/hooks/wake")) {
                        await handleWake(payload, res);
                        return;
                    }
                    if (path === "/hooks/agent" || path.endsWith("/hooks/agent")) {
                        await handleAgent(payload, res);
                        return;
                    }
                    sendJson(res, 404, { ok: false, error: `Unsupported webhook path: ${path}` });
                },
            });
            api.logger.info?.(`[rodit-webhooks] registered ${path}`);
        }
    },
});
