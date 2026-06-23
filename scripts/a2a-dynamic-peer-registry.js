// SPDX-License-Identifier: Apache-2.0
// Bootstrap patch helper: register outbound peers from inbound RODiT JWT claims.

let registrar = null;

export function setDynamicPeerRegistrar(fn) {
    registrar = typeof fn === "function" ? fn : null;
}

function normalizeWebhookBase(raw) {
    const trimmed = String(raw || "").trim().replace(/\/+$/, "");
    if (!trimmed) {
        return "";
    }
    try {
        const u = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
        return `${u.protocol}//${u.host}`;
    }
    catch {
        return trimmed;
    }
}

export function resolveInboundWebhookUrl(payload) {
    if (!payload || typeof payload !== "object") {
        return "";
    }
    const candidates = [
        payload.rodit_webhookurl,
        payload.rodit_webhook_url,
        payload.webhook_url,
    ];
    for (const candidate of candidates) {
        const base = normalizeWebhookBase(candidate);
        if (base) {
            return base;
        }
    }
    return "";
}

/** Passport token_id (12-char) — canonical outbound peer key. */
export function resolveInboundPeerTokenId(result) {
    const payload = result?.webhookPayload;
    if (payload && typeof payload === "object") {
        for (const candidate of [payload.token_id, payload.peerTokenId, payload.rodit_id]) {
            const text = String(candidate || "").trim();
            if (isPassportTokenId(text)) {
                return text;
            }
        }
    }
    const label = String(result?.label || "").trim();
    if (isPassportTokenId(label)) {
        return label;
    }
    return label;
}

export function isPassportTokenId(value) {
    return /^[A-Za-z][A-Za-z0-9]{11}$/.test(String(value || "").trim());
}

export function registerDynamicPeerFromInbound(result) {
    if (!registrar || !result?.ok) {
        return;
    }
    const peerTokenId = resolveInboundPeerTokenId(result);
    if (!peerTokenId) {
        return;
    }
    const webhookUrl = resolveInboundWebhookUrl(result.webhookPayload);
    if (!webhookUrl) {
        return;
    }
    void registrar(peerTokenId, webhookUrl).catch((err) => {
        console.error(`[a2a] dynamic peer registration failed for ${peerTokenId}: ${String(err)}`);
    });
}
