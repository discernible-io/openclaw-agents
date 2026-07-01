/**
 * Discover public IdentyClaw agents via GET /api/agents (api.identyclaw.com).
 * Same endpoint as identyclaw-tools `identyclaw_list_agents` (no auth required).
 *
 * Note: this returns Passport token_ids only. Resolving A2A gateway URLs
 * (metadata.webhook_url) uses GET /api/identity/token/{tokenId}/full, which
 * requires a session JWT from POST /api/login (agent NEAR credentials).
 */

/** Normalize API tokenId to 12-char Passport token_id when possible. */
export function normalizePassportTokenId(raw) {
  const text = String(raw || "").trim();
  if (!text) return "";
  if (/^[A-Za-z][A-Za-z0-9]{11}$/.test(text)) {
    return text.toLowerCase();
  }
  const roditMatch = text.match(/(?:^|;|\s)id=([A-Za-z][A-Za-z0-9]{11})(?:;|$)/i);
  if (roditMatch) {
    return roditMatch[1].toLowerCase();
  }
  return "";
}

export function normalizeApiBaseUrl(base) {
  let url = String(base || "").trim().replace(/\/+$/, "");
  if (!url) return "";
  if (!/^https?:\/\//i.test(url)) {
    url = `https://${url}`;
  }
  return url.replace(/\/+$/, "");
}

/**
 * @param {string} apiBase e.g. https://api.identyclaw.com
 * @param {{ limit?: number, maxPages?: number, exclude?: Set<string> }} [opts]
 * @returns {Promise<{ tokenIds: string[], pages: number, apiBase: string }>}
 */
export async function fetchPublicAgentTokenIds(apiBase, opts = {}) {
  const base = normalizeApiBaseUrl(apiBase);
  if (!base) {
    throw new Error("IdentyClaw API base URL is required");
  }
  const pageLimit = Math.min(Math.max(Number(opts.limit) || 100, 1), 100);
  const maxPages = Math.min(Math.max(Number(opts.maxPages) || 10, 1), 50);
  const exclude = opts.exclude instanceof Set ? opts.exclude : new Set();
  const seen = new Set();
  const tokenIds = [];
  let cursor = "";
  let pages = 0;

  for (let page = 0; page < maxPages; page += 1) {
    const query = new URLSearchParams({ limit: String(pageLimit) });
    if (cursor) {
      query.set("cursor", cursor);
    }
    const url = `${base}/api/agents?${query.toString()}`;
    const res = await fetch(url);
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`GET /api/agents failed: HTTP ${res.status}${body ? ` — ${body.slice(0, 200)}` : ""}`);
    }
    const payload = await res.json();
    pages += 1;
    for (const entry of payload?.agents || []) {
      const tokenId = normalizePassportTokenId(entry?.tokenId);
      if (!tokenId || seen.has(tokenId) || exclude.has(tokenId)) {
        continue;
      }
      seen.add(tokenId);
      tokenIds.push(tokenId);
    }
    cursor = String(payload?.nextCursor || "").trim();
    if (!cursor) {
      break;
    }
  }

  return { tokenIds, pages, apiBase: base };
}
