// send-rodit-webhook.ts
import { readFileSync } from "node:fs";

// rodit-runtime.ts
import { createRequire } from "node:module";
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
  if (cardUrl) return agentCardUrlToBase(cardUrl);
  if (loginBase) return loginBase.replace(/\/$/, "");
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
export {
  agentCardUrlToBase,
  loadNearSignerFromEnv,
  outboundTlsSkipVerify,
  resolveOutboundPeerBase,
  sendRoditWebhook
};
