// index.ts
import { createRequire } from "node:module";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
var DEFAULT_ENDPOINTS = ["/hooks/wake", "/hooks/agent"];
var RECEIPTS_PATH = "/home/node/.openclaw/cache/webhook-receipts.json";
var MAX_BODY_BYTES = 256 * 1024;
var MAX_RECEIPTS = 200;
var webhookReceipts = [];
function persistReceipts() {
  try {
    mkdirSync(dirname(RECEIPTS_PATH), { recursive: true });
    writeFileSync(RECEIPTS_PATH, `${JSON.stringify(webhookReceipts, null, 2)}
`, "utf8");
  } catch {
  }
}
function clearReceipts() {
  webhookReceipts.length = 0;
  persistReceipts();
}
function recordReceipt(path, rawPayload, requestIdHeader) {
  let event = null;
  let requestId = requestIdHeader || null;
  try {
    const parsed = JSON.parse(rawPayload);
    if (typeof parsed.event === "string") event = parsed.event;
    if (!requestId && typeof parsed.requestId === "string") requestId = parsed.requestId;
    const nested = parsed.data && typeof parsed.data === "object" && !Array.isArray(parsed.data) ? parsed.data : null;
    if (!requestId && nested && typeof nested.requestId === "string") requestId = nested.requestId;
  } catch {
  }
  webhookReceipts.push({
    path,
    event,
    requestId,
    timestamp: (/* @__PURE__ */ new Date()).toISOString()
  });
  if (webhookReceipts.length > MAX_RECEIPTS) {
    webhookReceipts.splice(0, webhookReceipts.length - MAX_RECEIPTS);
  }
  persistReceipts();
}
var roditClientPromise = null;
var roditAuthPromise = null;
function applyRoditEmbedEnv(logLevel) {
  if (!process.env.LOG_LEVEL) {
    process.env.LOG_LEVEL = logLevel ?? "error";
  }
  if (process.env.SUPPRESS_NO_CONFIG_WARNING === void 0) {
    process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
  }
  if (process.env.SUPPRESS_STRICTNESS_CHECK === void 0) {
    process.env.SUPPRESS_STRICTNESS_CHECK = "true";
  }
}
function loadRoditAuth(logLevel) {
  applyRoditEmbedEnv(logLevel);
  const require2 = createRequire(import.meta.url);
  const pkgRoot = dirname(require2.resolve("@rodit/rodit-auth-be"));
  return require2(join(pkgRoot, "lib/auth/authentication.js"));
}
async function getRoditAuth(logLevel) {
  if (!roditAuthPromise) {
    roditAuthPromise = Promise.resolve(loadRoditAuth(logLevel));
  }
  return roditAuthPromise;
}
async function getRoditClient(logLevel) {
  applyRoditEmbedEnv(logLevel);
  if (!roditClientPromise) {
    const require2 = createRequire(import.meta.url);
    const { RoditClient } = require2("@rodit/rodit-auth-be");
    if (!process.env.NEAR_CREDENTIALS_FILE_PATH?.trim() && !process.env.RODIT_NEAR_CREDENTIALS_SOURCE?.trim()) {
      throw new Error("RODiT credentials not configured (NEAR_CREDENTIALS_FILE_PATH)");
    }
    roditClientPromise = RoditClient.create({ role: "client" });
  }
  return roditClientPromise;
}
function headerValue(req, name) {
  const raw = req.headers[name.toLowerCase()];
  if (typeof raw === "string") return raw.trim();
  if (Array.isArray(raw) && raw.length > 0) return String(raw[0]).trim();
  return "";
}
function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.end(JSON.stringify(body));
}
async function readRawBody(req, maxBytes = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        req.destroy();
        reject(new Error("payload too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}
function implicitAccountPublicKeyBase64url(tokenId) {
  const normalized = tokenId.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(normalized)) return null;
  return Buffer.from(normalized, "hex").toString("base64url");
}
function resolveSignerPublicKey(stateManager, req, rawPayload) {
  const headerTokenId = headerValue(req, "x-rodit-token-id") || headerValue(req, "x-token-id") || headerValue(req, "x-rodit-id");
  if (headerTokenId) {
    const fromHeader = implicitAccountPublicKeyBase64url(headerTokenId);
    if (fromHeader) return fromHeader;
  }
  try {
    const parsed = JSON.parse(rawPayload);
    const nested = parsed.data && typeof parsed.data === "object" && !Array.isArray(parsed.data) ? parsed.data : null;
    const tokenId = typeof parsed.token_id === "string" && parsed.token_id || typeof parsed.rodit_id === "string" && parsed.rodit_id || typeof parsed.serverTokenId === "string" && parsed.serverTokenId || typeof parsed.peerTokenId === "string" && parsed.peerTokenId || nested && typeof nested.token_id === "string" && nested.token_id || nested && typeof nested.serverTokenId === "string" && nested.serverTokenId || nested && typeof nested.peerTokenId === "string" && nested.peerTokenId || "";
    const fromPayload = implicitAccountPublicKeyBase64url(tokenId);
    if (fromPayload) return fromPayload;
  } catch {
  }
  const peerKey = stateManager.getPeerBase64urlJwkPublicKey?.();
  if (peerKey) return peerKey;
  const ownKey = stateManager.getOwnBase64urlJwkPublicKey?.();
  if (ownKey) return ownKey;
  return null;
}
async function requestGatewayHeartbeat(mode) {
  if (mode !== "now") return;
  const dist = "/app/dist";
  const entry = readdirSync(dist).find((name) => name.startsWith("heartbeat-wake-") && name.endsWith(".js"));
  if (!entry) return;
  const mod = await import(pathToFileURL(join(dist, entry)).href);
  mod.requestHeartbeat?.({ source: "hook", reason: "hook:wake" });
}
function normalizeWakePayload(rawPayload) {
  try {
    const payload = JSON.parse(rawPayload);
    if (typeof payload.text === "string" && payload.text.trim()) {
      const mode = payload.mode === "next-heartbeat" ? "next-heartbeat" : "now";
      return { ok: true, text: payload.text.trim(), mode };
    }
    if (typeof payload.event === "string") {
      return { ok: true, text: payload.event, mode: "now" };
    }
    return { ok: false, error: "text required" };
  } catch {
    return { ok: false, error: "invalid json" };
  }
}
function createRoditWebhookHandler(endpoint, logLevel, logger) {
  return async (req, res) => {
    if (req.method !== "POST") {
      res.statusCode = 405;
      res.setHeader("Allow", "POST");
      res.end("Method Not Allowed");
      return;
    }
    const signature = headerValue(req, "x-signature");
    const timestamp = headerValue(req, "x-timestamp");
    if (!signature || !timestamp) {
      sendJson(res, 400, {
        ok: false,
        code: "MISSING_AUTH_PARAMS",
        message: "Missing required authentication parameters"
      });
      return;
    }
    let rawPayload = "";
    try {
      rawPayload = await readRawBody(req);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      sendJson(res, message === "payload too large" ? 413 : 400, { ok: false, error: message });
      return;
    }
    if (!rawPayload.trim()) {
      sendJson(res, 400, { ok: false, error: "empty body" });
      return;
    }
    try {
      const [auth, client] = await Promise.all([getRoditAuth(logLevel), getRoditClient(logLevel)]);
      const stateManager = client.getStateManager();
      const publicKey = resolveSignerPublicKey(stateManager, req, rawPayload);
      if (!publicKey) {
        sendJson(res, 500, {
          ok: false,
          code: "SIGNER_KEY_UNAVAILABLE",
          message: "Unable to resolve signer public key for webhook verification"
        });
        return;
      }
      const authResult = await auth.authenticate_webhook(rawPayload, signature, timestamp, publicKey);
      if (!authResult.isValid) {
        sendJson(res, 401, {
          ok: false,
          code: authResult.error?.code ?? "INVALID_WEBHOOK_SIGNATURE",
          message: authResult.error?.message ?? "Invalid webhook signature"
        });
        return;
      }
      recordReceipt(endpoint, rawPayload, headerValue(req, "x-request-id"));
      if (endpoint === "/hooks/wake") {
        const wake = normalizeWakePayload(rawPayload);
        if (!wake.ok) {
          sendJson(res, 400, { ok: false, error: wake.error });
          return;
        }
        await requestGatewayHeartbeat(wake.mode);
        sendJson(res, 200, { ok: true, mode: wake.mode });
        return;
      }
      if (endpoint === "/hooks/agent") {
        sendJson(res, 200, { ok: true, endpoint: "agent", accepted: true });
        return;
      }
      sendJson(res, 200, { ok: true, endpoint });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logger.error(`[rodit-webhooks] ${endpoint} failed: ${message}`);
      if (!res.headersSent) {
        sendJson(res, 500, { ok: false, error: "webhook processing failed" });
      }
    }
  };
}
var index_default = definePluginEntry({
  id: "rodit-webhooks",
  name: "RODiT Webhooks",
  description: "Inbound OpenClaw webhooks with RODiT Ed25519 origin signatures (x-signature + x-timestamp)",
  register(api) {
    const config = api.config?.plugins?.entries?.["rodit-webhooks"]?.config ?? {};
    const endpoints = (config.endpoints?.length ? config.endpoints : DEFAULT_ENDPOINTS).map(
      (path) => path.startsWith("/") ? path : `/${path}`
    );
    const logLevel = config.logLevel?.trim() || void 0;
    for (const endpoint of endpoints) {
      api.registerHttpRoute({
        path: endpoint,
        auth: "plugin",
        handler: createRoditWebhookHandler(endpoint, logLevel, api.logger)
      });
      api.logger.info(`[rodit-webhooks] registered ${endpoint} (RODiT x-signature + x-timestamp)`);
    }
    api.registerHttpRoute({
      path: "/hooks/_receipts",
      auth: "plugin",
      handler: async (req, res) => {
        if (req.method === "DELETE") {
          clearReceipts();
          sendJson(res, 200, { ok: true, cleared: true });
          return;
        }
        if (req.method !== "GET") {
          res.statusCode = 405;
          res.setHeader("Allow", "GET, DELETE");
          res.end("Method Not Allowed");
          return;
        }
        sendJson(res, 200, { ok: true, receipts: webhookReceipts });
      }
    });
    api.logger.info("[rodit-webhooks] registered GET|DELETE /hooks/_receipts (test helper)");
    api.registerService({
      id: "rodit-webhooks",
      start: async () => {
        try {
          await getRoditClient(logLevel);
          api.logger.info("[rodit-webhooks] RODiT passport warmed up for webhook verification");
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          api.logger.error(`[rodit-webhooks] warmup failed: ${message}`);
        }
      }
    });
  }
});
export {
  index_default as default
};
