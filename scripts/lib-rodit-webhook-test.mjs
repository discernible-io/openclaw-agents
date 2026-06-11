/**
 * Shared RODiT webhook signing + /hooks/_receipts helpers for smoke tests.
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function loadNearCreds(path) {
  const data = JSON.parse(readFileSync(path, "utf8"));
  const accountId = data.implicit_account_id || data.account_id || data.accountId;
  const privateKey = data.private_key || data.privateKey;
  if (!accountId || !privateKey) {
    throw new Error(`Missing account_id/private_key in ${path}`);
  }
  return { accountId: String(accountId).trim(), privateKey: String(privateKey).trim() };
}

function pluginRequire(extDir) {
  return createRequire(pathToFileURL(join(extDir, "package.json")));
}

export function privateKeyBytes(extDir, nearPrivateKey) {
  const bs58 = pluginRequire(extDir)("bs58");
  const body = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(body);
  if (decoded.length !== 64 && decoded.length < 32) throw new Error("Invalid NEAR private key");
  return new Uint8Array(decoded);
}

export function signWebhookPayload(extDir, payload, privateKey) {
  const nacl = pluginRequire(extDir)("tweetnacl");
  const timestamp = Date.now().toString();
  const payloadWithTimestamp = payload + timestamp;
  const hash = createHash("sha256").update(payloadWithTimestamp).digest();
  const signature = nacl.sign.detached(new Uint8Array(hash), privateKey);
  return {
    timestamp,
    signatureHex: Buffer.from(signature).toString("hex"),
  };
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

/**
 * P2P webhook: signer creds POST to receiver /hooks/wake, verify via _receipts.
 * Returns { postOk, receiptOk, marker, detail }.
 */
export async function runP2pWebhookSend(opts) {
  const {
    extDir,
    signerCredsPath,
    receiverBase,
    hookPath = "hooks/wake",
    markerPrefix = "p2p-webhook",
    senderLabel = "sender",
    receiverLabel = "receiver",
  } = opts;

  const path = hookPath.replace(/^\/+/, "");
  const recvBase = receiverBase.replace(/\/+$/, "");
  const signer = loadNearCreds(signerCredsPath);
  const signerKey = privateKeyBytes(extDir, signer.privateKey);
  const marker = `${markerPrefix}-${senderLabel}-to-${receiverLabel}-${Date.now()}`;
  const payload = JSON.stringify({ text: marker, mode: "now", p2p: true, requestId: marker });
  const hookUrl = `${recvBase}/${path}`;

  await clearReceipts(recvBase);

  const signed = signWebhookPayload(extDir, payload, signerKey);
  const post = await fetchJson(hookUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-signature": signed.signatureHex,
      "x-timestamp": signed.timestamp,
      "x-rodit-token-id": signer.accountId,
    },
    body: payload,
  });

  const postOk = post.status === 200 && post.json?.ok === true;
  const postDetail = `HTTP ${post.status}${postOk ? "" : ` ${JSON.stringify(post.json)}`}`;

  const receipts = await getReceipts(recvBase);
  const hit = receipts.find(
    (r) =>
      r.requestId === marker &&
      (r.path === `/${path}` || r.path === path || String(r.path || "").endsWith(path)),
  );

  return {
    postOk,
    receiptOk: Boolean(hit),
    marker,
    signerId: signer.accountId,
    postDetail,
    receiptDetail: hit
      ? `receipt at ${hit.timestamp || "?"}`
      : `no matching receipt (${receipts.length} total)`,
  };
}
