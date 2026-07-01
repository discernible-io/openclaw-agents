/**
 * Peer gateway URL helpers — IdentyClaw API identity.metadata.webhook_url
 * (GET /api/identity/token/{tokenId}/full with Bearer JWT from /api/login),
 * with on-chain RODiT fallback.
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

/** webhook_url from GET /api/identity/token/{tokenId}/full (OpenAPI metadata object). */
export function extractWebhookUrlFromIdentity(identity) {
  const meta = identity?.metadata;
  if (meta && typeof meta === "object" && !Array.isArray(meta)) {
    const fromMeta = String(meta.webhook_url ?? meta.webhookUrl ?? "").trim();
    if (fromMeta) {
      return fromMeta;
    }
  }
  return "";
}

export function extractWebhookUrlFromPeerRodit(peerRodit) {
  return String(peerRodit?.metadata?.webhook_url ?? peerRodit?.metadata?.webhookUrl ?? "").trim();
}

export function identityFullToGatewayBase(identity, tokenId = "") {
  const tid = String(identity?.tokenId || tokenId || "")
    .trim()
    .toLowerCase();
  if (!tid) {
    throw new Error("identity response missing tokenId");
  }
  const publicBase = parseWebhookBase(extractWebhookUrlFromIdentity(identity));
  if (!publicBase || !/^https?:\/\//i.test(publicBase)) {
    throw new Error(
      `Identity for ${tid} has no usable metadata.webhook_url for A2A ingress`,
    );
  }
  return publicBase;
}

export function identityFullToAgentCardUrl(identity, tokenId = "") {
  const tid = String(identity?.tokenId || tokenId || "")
    .trim()
    .toLowerCase();
  const cardUrl = webhookUrlToAgentCardUrl(extractWebhookUrlFromIdentity(identity));
  if (!cardUrl) {
    throw new Error(
      `Identity for ${tid || "unknown"} has no usable metadata.webhook_url for A2A ingress`,
    );
  }
  return cardUrl;
}

export function peerRoditToGatewayBase(peerRodit) {
  const tokenId = String(peerRodit?.token_id || "")
    .trim()
    .toLowerCase();
  if (!tokenId) {
    throw new Error("no RODiT on chain for token_id");
  }
  const publicBase = parseWebhookBase(extractWebhookUrlFromPeerRodit(peerRodit));
  if (!publicBase || !/^https?:\/\//i.test(publicBase)) {
    throw new Error(
      `RODiT ${tokenId} has no usable metadata.webhook_url for A2A ingress`,
    );
  }
  return publicBase;
}

export function peerRoditToAgentCardUrl(peerRodit) {
  const base = peerRoditToGatewayBase(peerRodit);
  return `${base}/.well-known/agent-card.json`;
}

export function tryIdentityFullToGatewayBase(identity, tokenId = "") {
  try {
    return identityFullToGatewayBase(identity, tokenId);
  } catch {
    return null;
  }
}

export function tryPeerRoditToGatewayBase(peerRodit) {
  try {
    return peerRoditToGatewayBase(peerRodit);
  } catch {
    return null;
  }
}

/**
 * API first (GET /api/identity/token/{tokenId}/full), then on-chain rodit_token.
 * @returns {{ base: string, source: "api" | "chain" }}
 */
export async function resolvePeerGatewayBase(
  tokenId,
  { fetchIdentityFull, fetchPeerRoditByTokenId },
) {
  const normalized = String(tokenId || "")
    .trim()
    .toLowerCase();
  let apiDetail = "";

  if (fetchIdentityFull) {
    try {
      const identity = await fetchIdentityFull(normalized);
      const fromApi = tryIdentityFullToGatewayBase(identity, normalized);
      if (fromApi) {
        return { base: fromApi, source: "api" };
      }
      apiDetail = "API /full returned no usable metadata.webhook_url";
    } catch (err) {
      apiDetail =
        err instanceof Error ? err.message : String(err);
    }
  } else {
    apiDetail = "API identity fetch not available";
  }

  if (!fetchPeerRoditByTokenId) {
    throw new Error(
      `Peer ${normalized}: ${apiDetail}; on-chain fallback unavailable`,
    );
  }

  try {
    const peerRodit = await fetchPeerRoditByTokenId(normalized);
    const fromChain = tryPeerRoditToGatewayBase(peerRodit);
    if (fromChain) {
      return { base: fromChain, source: "chain" };
    }
    throw new Error(
      `Peer ${normalized}: ${apiDetail}; on-chain RODiT has no usable metadata.webhook_url`,
    );
  } catch (err) {
    const chainDetail = err instanceof Error ? err.message : String(err);
    if (chainDetail.includes("no usable metadata.webhook_url") || chainDetail.includes("no RODiT")) {
      throw err;
    }
    throw new Error(`Peer ${normalized}: ${apiDetail}; on-chain lookup failed: ${chainDetail}`);
  }
}

export async function resolvePeerAgentCardUrlFromApi(tokenId, fetchIdentityFull) {
  const identity = await fetchIdentityFull(tokenId);
  return identityFullToAgentCardUrl(identity, tokenId);
}

export async function resolvePeerAgentCardUrl(tokenId, fetchIdentityFull) {
  return resolvePeerAgentCardUrlFromApi(tokenId, fetchIdentityFull);
}
