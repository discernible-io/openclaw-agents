// index.ts
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join as join2 } from "node:path";
import { pathToFileURL } from "node:url";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

// send-rodit-webhook.ts
import { readFileSync } from "node:fs";

// rodit-runtime.ts
import { createRequire } from "node:module";
import { dirname as dirname2, join } from "node:path";
function normalizeWebhookBase(raw) {
  const trimmed = raw.trim().replace(/\/+$/, "");
  if (!trimmed) return "";
  if (trimmed.includes("://")) return trimmed;
  return `https://${trimmed}`;
}
async function getOwnPassportUrls(logLevel) {
  const client = await getRoditClient(logLevel);
  const own = await client.getConfigOwnRodit();
  const meta = own?.own_rodit?.metadata ?? {};
  return {
    webhook_url: normalizeWebhookBase(String(meta.webhook_url || "")),
    api_base: String(meta.subjectuniqueidentifier_url || "").trim().replace(/\/+$/, ""),
    owner_id: String(own?.own_rodit?.owner_id || "").trim()
  };
}
var roditClientPromise = null;
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
function applyWebhookTlsSkip(skip) {
  if (skip) {
    process.env.SECURITY_OPTIONS_WEBHOOK_TLS_SKIP_VERIFY = "true";
  }
}
function peerBaseToRoditWebhookUrl(baseUrl) {
  return baseUrl.replace(/^https?:\/\//i, "").replace(/\/+$/, "");
}
function buildPeerWebhookReq(peerBaseUrl) {
  return { user: { rodit_webhookurl: peerBaseToRoditWebhookUrl(peerBaseUrl) } };
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
var roditAuthPromise = null;
function loadRoditAuth(logLevel) {
  applyRoditEmbedEnv(logLevel);
  const require2 = createRequire(import.meta.url);
  const pkgRoot = dirname2(require2.resolve("@rodit/rodit-auth-be"));
  return require2(join(pkgRoot, "lib/auth/authentication.js"));
}
async function getRoditAuth(logLevel) {
  if (!roditAuthPromise) {
    roditAuthPromise = Promise.resolve(loadRoditAuth(logLevel));
  }
  return roditAuthPromise;
}

// send-rodit-webhook.ts
function agentCardUrlToBase(url) {
  const trimmed = url.trim().replace(/\/$/, "");
  if (trimmed.endsWith("/.well-known/agent-card.json")) {
    return trimmed.slice(0, -"/.well-known/agent-card.json".length);
  }
  return trimmed;
}
function resolveOutboundPeerBase(config, peerId) {
  const peer = config.plugins?.entries?.a2a?.config?.outbound?.agents?.[peerId];
  const cardUrl = peer?.url?.trim();
  const loginBase = peer?.loginBaseUrl?.trim();
  if (loginBase) return loginBase.replace(/\/$/, "");
  if (cardUrl) return agentCardUrlToBase(cardUrl);
  const known = Object.keys(config.plugins?.entries?.a2a?.config?.outbound?.agents ?? {});
  throw new Error(
    `Peer '${peerId}' not found in plugins.entries.a2a.config.outbound.agents` + (known.length ? ` (configured: ${known.join(", ")})` : "")
  );
}
function outboundTlsSkipVerify(config) {
  return config.plugins?.entries?.a2a?.config?.outbound?.tlsSkipVerify === true;
}
function loadNearSignerFromEnv() {
  const credPath = process.env.NEAR_CREDENTIALS_FILE_PATH?.trim();
  if (!credPath) {
    throw new Error("NEAR_CREDENTIALS_FILE_PATH is not set");
  }
  const data = JSON.parse(readFileSync(credPath, "utf8"));
  const accountId = data.implicit_account_id || data.account_id || data.accountId;
  const privateKey = data.private_key || data.privateKey;
  if (!accountId || !privateKey) {
    throw new Error(`Missing account_id/private_key in ${credPath}`);
  }
  return { accountId: String(accountId).trim(), privateKey: String(privateKey).trim() };
}
async function sendRoditWebhook(opts) {
  const delaySeconds = opts.delaySeconds ?? 10;
  const hookPath = (opts.hookPath ?? "hooks/wake").replace(/^\/+/, "");
  const targetBase = resolveOutboundPeerBase(opts.config, opts.peerId);
  const tlsSkipVerify = outboundTlsSkipVerify(opts.config);
  const signer = loadNearSignerFromEnv();
  const endpoint = `/${hookPath}`;
  const url = `${targetBase.replace(/\/+$/, "")}${endpoint}`;
  const wakeText = opts.text?.trim() || `Webhook ping to ${opts.peerId} via send_rodit_webhook`;
  if (delaySeconds > 0) {
    await new Promise((resolve) => setTimeout(resolve, delaySeconds * 1e3));
  }
  applyWebhookTlsSkip(tlsSkipVerify);
  const client = await getRoditClient();
  const peerReq = buildPeerWebhookReq(targetBase);
  const payload = {
    event: wakeText,
    data: {
      mode: "now",
      token_id: signer.accountId,
      peerTokenId: signer.accountId
    }
  };
  let sdkResult;
  try {
    sdkResult = endpoint === "/hooks/wake" ? await client.sendWakeHook(payload, peerReq) : await client.sendWebhookToEndpoint(payload, endpoint, peerReq);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      url,
      peerId: opts.peerId,
      requestId: "",
      delaySeconds,
      status: 502,
      ok: false,
      response: { error: message, webhookUrl: peerBaseToRoditWebhookUrl(targetBase) }
    };
  }
  const ok = sdkResult.isValid === true;
  return {
    url,
    peerId: opts.peerId,
    requestId: sdkResult.requestId ?? "",
    delaySeconds,
    status: ok ? 200 : 502,
    ok,
    response: sdkResult
  };
}

// index.ts
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
  const mod = await import(pathToFileURL(join2(dist, entry)).href);
  mod.requestHeartbeat?.({ source: "hook", reason: "hook:wake" });
}
function normalizeWakePayload(rawPayload) {
  try {
    const payload = JSON.parse(rawPayload);
    if (typeof payload.text === "string" && payload.text.trim()) {
      const mode = payload.mode === "next-heartbeat" ? "next-heartbeat" : "now";
      return { ok: true, text: payload.text.trim(), mode };
    }
    if (typeof payload.event === "string" && payload.event.trim()) {
      const nested2 = payload.data && typeof payload.data === "object" && !Array.isArray(payload.data) ? payload.data : null;
      const mode = nested2?.mode === "next-heartbeat" ? "next-heartbeat" : "now";
      return { ok: true, text: payload.event.trim(), mode };
    }
    const nested = payload.data && typeof payload.data === "object" && !Array.isArray(payload.data) ? payload.data : null;
    if (nested && typeof nested.text === "string" && nested.text.trim()) {
      const mode = nested.mode === "next-heartbeat" ? "next-heartbeat" : "now";
      return { ok: true, text: nested.text.trim(), mode };
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
    api.registerTool({
      name: "send_rodit_webhook",
      description: "Sign and POST a RODiT webhook (/hooks/wake) to a configured A2A peer after a delay. Resolves the peer base URL from plugins.entries.a2a.config.outbound.agents.",
      parameters: {
        type: "object",
        properties: {
          peerId: {
            type: "string",
            description: "Outbound peer id (key in outbound.agents), e.g. agent-a"
          },
          text: {
            type: "string",
            description: "Webhook body text (default: auto-generated ping message)"
          },
          delaySeconds: {
            type: "number",
            minimum: 0,
            description: "Seconds to wait before sending (default: 10)"
          },
          hookPath: {
            type: "string",
            description: "Webhook path on the peer (default: hooks/wake)"
          }
        },
        required: ["peerId"],
        additionalProperties: false
      },
      async execute(_toolCallId, params) {
        const result = await sendRoditWebhook({
          config: api.config ?? {},
          peerId: params.peerId,
          text: params.text,
          delaySeconds: params.delaySeconds ?? 10,
          hookPath: params.hookPath
        });
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify(result, null, 2)
            }
          ]
        };
      }
    });
    api.logger.info("[rodit-webhooks] registered tool send_rodit_webhook");
    api.registerService({
      id: "rodit-webhooks",
      start: async () => {
        try {
          await getRoditClient(logLevel);
          const passport = await getOwnPassportUrls(logLevel);
          if (passport.webhook_url) {
            api.logger.info(`[rodit-webhooks] Passport metadata.webhook_url=${passport.webhook_url}`);
          }
          const configured = api.config?.plugins?.entries?.a2a?.config?.inbound?.publicBaseUrl?.replace(/\/+$/, "");
          if (configured && passport.webhook_url && configured !== passport.webhook_url) {
            api.logger.warn(
              `[rodit-webhooks] inbound.publicBaseUrl (${configured}) differs from Passport webhook_url (${passport.webhook_url})`
            );
          }
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
