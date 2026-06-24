/**
 * Peer gateway URL helpers — mirrors identyclaw-a2a TokenPeerResolver (metadata.webhook_url).
 */

export function parseWebhookBase(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  try {
    const u = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
    return `${u.protocol}//${u.host}`;
  } catch {
    return trimmed;
  }
}

export function webhookUrlToAgentCardUrl(webhookUrl) {
  const base = parseWebhookBase(webhookUrl);
  if (!base || !/^https?:\/\//i.test(base)) {
    return null;
  }
  return `${base}/.well-known/agent-card.json`;
}

export function peerRoditToGatewayBase(peerRodit) {
  const tokenId = String(peerRodit?.token_id || "")
    .trim()
    .toLowerCase();
  if (!tokenId) {
    throw new Error("no RODiT on chain for token_id");
  }
  const publicBase = parseWebhookBase(peerRodit?.metadata?.webhook_url);
  if (!publicBase || !/^https?:\/\//i.test(publicBase)) {
    throw new Error(
      `RODiT ${tokenId} has no usable metadata.webhook_url for A2A ingress`,
    );
  }
  return publicBase;
}

export function peerRoditToAgentCardUrl(peerRodit) {
  const tokenId = String(peerRodit?.token_id || "")
    .trim()
    .toLowerCase();
  if (!tokenId) {
    throw new Error("no RODiT on chain for token_id");
  }
  const cardUrl = webhookUrlToAgentCardUrl(peerRodit?.metadata?.webhook_url ?? "");
  if (!cardUrl) {
    throw new Error(
      `RODiT ${tokenId} has no usable metadata.webhook_url for A2A ingress`,
    );
  }
  return cardUrl;
}

/** Same shape as RoditClient.getBlockchainService().nearorg_rpc_tokenfromroditid */
export async function resolvePeerAgentCardUrl(tokenId, fetchPeerRoditByTokenId) {
  const peerRodit = await fetchPeerRoditByTokenId(tokenId);
  return peerRoditToAgentCardUrl(peerRodit);
}
