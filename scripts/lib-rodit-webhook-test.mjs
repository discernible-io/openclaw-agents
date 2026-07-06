/**
 * Shared RODiT webhook helpers for smoke tests.
 * P2P delivery uses sendRoditWebhook() — same path as send_rodit_webhook / send-rodit-webhook.mjs.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_CONFIG = "/home/node/.openclaw/openclaw.json";
const DEFAULT_PLUGIN_DIR = "/home/node/.openclaw/extensions/identyclaw-webhooks/dist";

export function loadNearCreds(path) {
  const data = JSON.parse(readFileSync(path, "utf8"));
  const accountId = data.implicit_account_id || data.account_id || data.accountId;
  const privateKey = data.private_key || data.privateKey;
  if (!accountId || !privateKey) {
    throw new Error(`Missing account_id/private_key in ${path}`);
  }
  return { accountId: String(accountId).trim(), privateKey: String(privateKey).trim() };
}

export async function fetchJson(url, init = {}) {
  const res = await fetch(url, init);
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, json, text };
}

export async function clearReceipts(receiverBase) {
  await fetchJson(`${receiverBase.replace(/\/+$/, "")}/hooks/_receipts`, { method: "DELETE" });
}

export async function getReceipts(receiverBase) {
  const url = `${receiverBase.replace(/\/+$/, "")}/hooks/_receipts`;
  const { status, json, text } = await fetchJson(url);
  if (status !== 200 || !json?.ok) {
    const hint = text?.includes("<!DOCTYPE") ? " (got HTML — check receiver port/host)" : "";
    throw new Error(`GET ${url} failed: HTTP ${status}${hint}`);
  }
  return json.receipts ?? [];
}

function hookPathTail(hookPath) {
  return (hookPath ?? "hooks/wake").replace(/^\/+/, "");
}

function findWebhookReceipt(receipts, { marker, hookPath }) {
  const path = hookPathTail(hookPath);
  const endpoint = `/${path}`;
  return receipts.find(
    (r) =>
      r.event === marker &&
      (r.path === endpoint || r.path === path || String(r.path || "").endsWith(path)),
  );
}

/** Verify the receiver agent recorded an inbound webhook (GET /hooks/_receipts). */
export async function verifyWebhookReceipt(receiverBase, opts) {
  const { marker, hookPath = "hooks/wake", requestId } = opts;
  const receipts = await getReceipts(receiverBase);
  const hit = findWebhookReceipt(receipts, { marker, hookPath });
  if (!hit) {
    return {
      receiptOk: false,
      receiptDetail: `no matching receipt for event=${marker} (${receipts.length} total)`,
    };
  }
  if (requestId && hit.requestId && hit.requestId !== requestId) {
    return {
      receiptOk: false,
      receiptDetail: `receipt requestId mismatch (wanted ${requestId}, got ${hit.requestId})`,
    };
  }
  return {
    receiptOk: true,
    receiptDetail: `receipt at ${hit.timestamp || "?"} (requestId=${hit.requestId || "?"})`,
    receipt: hit,
  };
}

function patchOutboundPeer(config, peerId, override) {
  if (!override) return config;
  const next = JSON.parse(JSON.stringify(config));
  const plugins = (next.plugins ??= {});
  const entries = (plugins.entries ??= {});
  const pluginKey = entries["identyclaw-a2a"] ? "identyclaw-a2a" : "a2a";
  const a2a = (entries[pluginKey] ??= {});
  const a2aConfig = (a2a.config ??= {});
  const outbound = (a2aConfig.outbound ??= {});
  const agents = (outbound.agents ??= {});
  agents[peerId] = { ...(agents[peerId] ?? {}), ...override };
  return next;
}

async function loadSendRoditWebhook(pluginDir = DEFAULT_PLUGIN_DIR) {
  const mod = await import(pathToFileURL(join(pluginDir, "send-rodit-webhook.js")).href);
  return mod.sendRoditWebhook;
}

/**
 * Run send_rodit_webhook and verify the receiver recorded it.
 */
export async function runSendRoditWebhookRequest(opts) {
  const {
    configPath = process.env.OPENCLAW_CONFIG || DEFAULT_CONFIG,
    pluginDir = DEFAULT_PLUGIN_DIR,
    signerCredsPath,
    peerId,
    receiverBase,
    text,
    delaySeconds = 0,
    hookPath = "hooks/wake",
    markerPrefix = "send-rodit-webhook",
    outboundPeerOverride,
    clearReceiptsBefore = true,
  } = opts;

  if (!signerCredsPath || !peerId) {
    throw new Error("signerCredsPath and peerId are required");
  }

  process.env.NEAR_CREDENTIALS_FILE_PATH = signerCredsPath;
  const signer = loadNearCreds(signerCredsPath);
  const marker = text ?? `${markerPrefix}-${peerId}-${Date.now()}`;
  const recvBaseHint = receiverBase?.replace(/\/+$/, "");

  if (clearReceiptsBefore && recvBaseHint) {
    await clearReceipts(recvBaseHint);
  }

  const rawConfig = JSON.parse(readFileSync(configPath, "utf8"));
  const config = patchOutboundPeer(rawConfig, peerId, outboundPeerOverride);
  const sendRoditWebhook = await loadSendRoditWebhook(pluginDir);
  const sendResult = await sendRoditWebhook({
    config,
    peerId,
    text: marker,
    delaySeconds,
    hookPath,
  });

  const recvBase = recvBaseHint || sendResult.url.replace(/\/hooks\/.*$/, "");
  const receipt = await verifyWebhookReceipt(recvBase, {
    marker,
    hookPath,
    requestId: sendResult.requestId || undefined,
  });

  return {
    postOk: sendResult.ok,
    receiptOk: receipt.receiptOk,
    marker,
    requestId: sendResult.requestId ?? "",
    signerId: signer.accountId,
    peerId,
    hookUrl: sendResult.url,
    receiverBase: recvBase,
    postDetail: sendResult.ok
      ? `send_rodit_webhook ok requestId=${sendResult.requestId || "?"}`
      : `send_rodit_webhook failed ${JSON.stringify(sendResult.response)}`,
    receiptDetail: receipt.receiptDetail,
    sendResult,
  };
}

/**
 * Outbound to a peerId absent from outbound.agents — wiring contract only.
 */
export async function runSendToUnconfiguredPeer(opts) {
  const {
    configPath = process.env.OPENCLAW_CONFIG || DEFAULT_CONFIG,
    pluginDir = DEFAULT_PLUGIN_DIR,
    signerCredsPath,
    peerId = "zzzzzzzzzzzz",
    hookPath = "hooks/wake",
  } = opts;

  if (!signerCredsPath) {
    throw new Error("signerCredsPath is required");
  }

  process.env.NEAR_CREDENTIALS_FILE_PATH = signerCredsPath;
  const rawConfig = JSON.parse(readFileSync(configPath, "utf8"));
  const plugins = rawConfig.plugins?.entries || {};
  const pluginKey = plugins["identyclaw-a2a"] ? "identyclaw-a2a" : "a2a";
  const agents = plugins[pluginKey]?.config?.outbound?.agents || {};
  if (agents[peerId]) {
    throw new Error(`peerId ${peerId} is configured — pick an id not in outbound.agents`);
  }

  const sendRoditWebhook = await loadSendRoditWebhook(pluginDir);
  const sendResult = await sendRoditWebhook({
    config: rawConfig,
    peerId,
    text: `unconfigured-peer-probe-${Date.now()}`,
    delaySeconds: 0,
    hookPath,
  });

  const detail = sendResult.ok
    ? "unexpected ok:true for unconfigured peer"
    : JSON.stringify(sendResult.response || sendResult.error || sendResult).slice(0, 300);

  return {
    peerId,
    rejected: !sendResult.ok,
    detail,
    sendResult,
  };
}

/**
 * Outbound: local agent sends send_rodit_webhook → verify peer received (peer /hooks/_receipts).
 */
export async function runOutboundWebhookToPeer(opts) {
  const {
    localId,
    peerId,
    localCredsPath,
    peerBase,
    markerPrefix = "outbound-webhook",
    ...rest
  } = opts;

  const result = await runSendRoditWebhookRequest({
    signerCredsPath: localCredsPath,
    peerId,
    receiverBase: peerBase,
    markerPrefix: `${markerPrefix}-${localId}-to-${peerId}`,
    ...rest,
  });

  return {
    ...result,
    direction: "outbound",
    deliveredOk: result.postOk,
    peerReceivedOk: result.receiptOk,
    deliveredDetail: result.postDetail,
    peerReceivedDetail: result.receiptDetail,
  };
}

function applyNearEnvFromCreds(credsPath, openclawHome = "/home/node/.openclaw") {
  process.env.NEAR_CREDENTIALS_FILE_PATH = credsPath;
  const creds = loadNearCreds(credsPath);
  process.env.IDENTYCLAW_ACCOUNT_ID = creds.accountId;
  process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = creds.privateKey;
  process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
  process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
  process.env.SUPPRESS_STRICTNESS_CHECK = "true";
  process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
  process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID || process.env.IDENTYCLAW_NEAR_CONTRACT_ID || "genaaaa-identyclaw-com.near";
  process.env.OPENCLAW_HOME = openclawHome;
}

/** P2P login_server against a live peer gateway (JWT for POST /a2a). */
export async function acquireP2pJwtForPeer(peerBase, openclawHome = "/home/node/.openclaw") {
  const ext = join(openclawHome, "extensions/identyclaw-a2a");
  const { defaultRoditPeerLogin } = await import(
    pathToFileURL(join(ext, "dist/auth/rodit-peer-login.js")).href
  );
  return defaultRoditPeerLogin(peerBase.replace(/\/+$/, ""), { logLevel: "error" });
}

/** Parse send_rodit_webhook tool success from an A2A message/send JSON response. */
export function parseSendRoditWebhookToolOk(a2aJson) {
  if (!a2aJson || typeof a2aJson !== "object") return null;

  function readOk(payload) {
    if (!payload || typeof payload !== "object") return null;
    if ("ok" in payload) return Boolean(payload.ok);
    return null;
  }

  function inspectToolNode(node) {
    if (!node || typeof node !== "object") return null;
    const name = String(node.name || node.toolName || node.tool || "").toLowerCase();
    if (!name.includes("send_rodit_webhook") && !name.includes("send-rodit-webhook")) {
      return null;
    }
    const direct = readOk(node.content ?? node.result ?? node.output ?? node.response);
    if (direct !== null) return direct;
    const raw = node.content ?? node.result ?? node.output ?? node.response;
    if (typeof raw === "string") {
      try {
        return readOk(JSON.parse(raw));
      } catch {
        return null;
      }
    }
    return null;
  }

  const stack = [a2aJson];
  while (stack.length) {
    const cur = stack.pop();
    if (!cur || typeof cur !== "object") continue;
    if (Array.isArray(cur)) {
      stack.push(...cur);
      continue;
    }
    const toolOk = inspectToolNode(cur);
    if (toolOk !== null) return toolOk;
    for (const value of Object.values(cur)) {
      if (value && typeof value === "object") stack.push(value);
    }
  }

  const text = JSON.stringify(a2aJson);
  if (/send[_-]rodit[_-]webhook/i.test(text)) {
    if (/"ok"\s*:\s*true/.test(text)) return true;
    if (/"ok"\s*:\s*false/.test(text)) return false;
  }
  return null;
}

/** Ask a live peer agent (via A2A message/send) to run send_rodit_webhook toward us. */
export async function requestLivePeerSendRoditWebhook(opts) {
  const {
    peerBase,
    jwt,
    localOutboundPeerId,
    marker,
    delaySeconds = 0,
    hookPath = "hooks/wake",
  } = opts;
  const a2aUrl = `${peerBase.replace(/\/+$/, "")}/a2a`;
  const msgId = `live-inbound-${Date.now()}`;
  const instruction =
    `IDENTYCLAW_SMOKE inbound webhook test. Call tool send_rodit_webhook exactly once with: ` +
    `peerId="${localOutboundPeerId}", text="${marker}", delaySeconds=${delaySeconds}, hookPath="${hookPath}". ` +
    `Use the exact text value as the webhook event. Reply with the tool result JSON.`;
  const { status, json, text } = await fetchJson(a2aUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: msgId,
      method: "message/send",
      params: {
        message: {
          role: "user",
          parts: [{ kind: "text", text: instruction }],
          messageId: msgId,
        },
      },
    }),
  });
  if (status < 200 || status >= 300) {
    throw new Error(`A2A message/send to live peer failed: HTTP ${status} ${String(text).slice(0, 300)}`);
  }
  return { a2aUrl, msgId, status, json, marker };
}

/**
 * Inbound via live peer: P2P login → A2A message/send → peer signs send_rodit_webhook at origin.
 * Receiver validates via rodit-auth-be (P2P session); no peer NEAR file on this host.
 */
export async function runInboundWebhookFromLivePeer(opts) {
  const {
    localId,
    localTokenId,
    peerId,
    peerBase,
    localBase,
    localCredsPath,
    openclawHome = "/home/node/.openclaw",
    hookPath = "hooks/wake",
    markerPrefix = "live-inbound",
    delaySeconds = 0,
    pollIntervalMs = 2000,
    pollTimeoutMs = 180000,
  } = opts;

  if (!localId || !peerBase || !localBase || !localCredsPath) {
    throw new Error("localId, peerBase, localBase, localCredsPath are required");
  }

  applyNearEnvFromCreds(localCredsPath, openclawHome);
  const marker = `${markerPrefix}-${peerId || "peer"}-to-${localId}-${Date.now()}`;
  await clearReceipts(localBase);

  const jwt = await acquireP2pJwtForPeer(peerBase, openclawHome);
  const a2a = await requestLivePeerSendRoditWebhook({
    peerBase,
    jwt,
    localOutboundPeerId: localTokenId || localId,
    marker,
    delaySeconds,
    hookPath,
  });

  const deadline = Date.now() + pollTimeoutMs;
  let receipt = { receiptOk: false, receiptDetail: "timeout waiting for inbound webhook" };
  while (Date.now() < deadline) {
    receipt = await verifyWebhookReceipt(localBase, { marker, hookPath });
    if (receipt.receiptOk) break;
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }

  const toolOk = parseSendRoditWebhookToolOk(a2a.json);
  const httpOk = a2a.status >= 200 && a2a.status < 300;
  let peerDeliveredOk;
  let peerDeliveredDetail;
  if (toolOk === true) {
    peerDeliveredOk = true;
    peerDeliveredDetail = `send_rodit_webhook tool ok=true (A2A HTTP ${a2a.status})`;
  } else if (toolOk === false) {
    peerDeliveredOk = false;
    peerDeliveredDetail = `send_rodit_webhook tool ok=false (A2A HTTP ${a2a.status})`;
  } else if (receipt.receiptOk) {
    peerDeliveredOk = true;
    peerDeliveredDetail = `webhook receipt verified (A2A HTTP ${a2a.status}; no parseable tool result)`;
  } else {
    peerDeliveredOk = false;
    peerDeliveredDetail = httpOk
      ? `A2A HTTP ${a2a.status} but send_rodit_webhook not confirmed (no tool result or receipt)`
      : `A2A message/send failed HTTP ${a2a.status}`;
  }

  return {
    direction: "inbound-live",
    marker,
    hookUrl: `${localBase.replace(/\/+$/, "")}/${hookPath.replace(/^\/+/, "")}`,
    a2aStatus: a2a.status,
    peerDeliveredOk,
    weReceivedOk: receipt.receiptOk,
    peerDeliveredDetail,
    weReceivedDetail: receipt.receiptDetail,
    a2aResponse: a2a.json,
    sendRoditWebhookToolOk: toolOk,
  };
}

/**
 * Inbound: simulate peer sending send_rodit_webhook → verify we received (local /hooks/_receipts).
 * Offline harness only: signs with peer NEAR creds from disk. Prefer runInboundWebhookFromLivePeer.
 */
export async function runInboundWebhookFromPeer(opts) {
  const {
    localId,
    peerId,
    peerCredsPath,
    localBase,
    markerPrefix = "inbound-webhook",
    outboundPeerOverride,
    ...rest
  } = opts;

  const result = await runSendRoditWebhookRequest({
    signerCredsPath: peerCredsPath,
    peerId: localId,
    receiverBase: localBase,
    markerPrefix: `${markerPrefix}-${peerId}-to-${localId}`,
    outboundPeerOverride: outboundPeerOverride ?? { loginBaseUrl: localBase.replace(/\/+$/, "") },
    ...rest,
  });

  return {
    ...result,
    direction: "inbound",
    peerDeliveredOk: result.postOk,
    weReceivedOk: result.receiptOk,
    peerDeliveredDetail: result.postDetail,
    weReceivedDetail: result.receiptDetail,
  };
}

/** @deprecated Use runOutboundWebhookToPeer / runInboundWebhookFromPeer. */
export async function runP2pWebhookSend(opts) {
  const {
    signerCredsPath,
    receiverBase,
    hookPath = "hooks/wake",
    markerPrefix = "p2p-webhook",
    senderLabel = "sender",
    receiverLabel = "receiver",
    peerId = receiverLabel,
    configPath,
    pluginDir,
    delaySeconds = 0,
    outboundPeerOverride,
  } = opts;

  return runSendRoditWebhookRequest({
    configPath,
    pluginDir,
    signerCredsPath,
    peerId,
    receiverBase,
    hookPath,
    markerPrefix: `${markerPrefix}-${senderLabel}-to-${receiverLabel}`,
    delaySeconds,
    outboundPeerOverride,
  });
}
