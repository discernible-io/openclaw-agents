/**
 * Shared RODiT webhook helpers for smoke tests.
 * P2P delivery uses sendRoditWebhook() — same path as send_rodit_webhook / send-rodit-webhook.mjs.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_CONFIG = "/home/node/.openclaw/openclaw.json";
const DEFAULT_PLUGIN_DIR = "/home/node/.openclaw/extensions/rodit-webhooks/dist";

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
      receiptDetail: `receipt requestId mismatch (expected ${requestId}, got ${hit.requestId})`,
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
  const a2a = (entries.a2a ??= {});
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

/**
 * Inbound: peer sends send_rodit_webhook → verify we received (local /hooks/_receipts).
 * Uses peer NEAR creds; optional outboundPeerOverride when peer config is not available locally.
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
