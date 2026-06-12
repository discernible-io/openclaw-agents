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

export function registerDynamicPeerFromInbound(result) {
    if (!registrar || !result?.ok || !result.label) {
        return;
    }
    const webhookUrl = resolveInboundWebhookUrl(result.webhookPayload);
    if (!webhookUrl) {
        return;
    }
    void registrar(result.label, webhookUrl).catch((err) => {
        console.error(`[a2a] dynamic peer registration failed for ${result.label}: ${String(err)}`);
    });
}
