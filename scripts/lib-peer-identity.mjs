/**
 * Peer Passport identity via IdentyClaw API GET /api/identity/token/{tokenId}/full.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { resolveRoditApiBaseUrl } from "./lib-rodit-env.mjs";

/** contactUri formats: email:domain:user@domain, mailto:user@domain */
export function contactUriToEmail(contactUri) {
  const raw = String(contactUri || "").trim();
  if (!raw) return "";
  if (raw.startsWith("mailto:")) {
    return raw.slice("mailto:".length).trim();
  }
  if (raw.startsWith("email:")) {
    const parts = raw.split(":");
    if (parts.length >= 3) {
      return parts.slice(2).join(":").trim();
    }
  }
  if (raw.includes("@") && !raw.includes("://")) {
    return raw;
  }
  return "";
}

export function normalizeEmail(email) {
  return String(email || "").trim().toLowerCase();
}

export function emailsMatch(a, b) {
  const left = normalizeEmail(a);
  const right = normalizeEmail(b);
  return Boolean(left && right && left === right);
}

export async function loadIdentityApiClient(extDir) {
  const apiClientPath = join(extDir, "dist/auth/identyclaw-api-client.js");
  if (!existsSync(apiClientPath)) {
    throw new Error(`missing identyclaw-api-client at ${apiClientPath}`);
  }
  return import(pathToFileURL(apiClientPath).href);
}

export async function fetchPeerIdentityFull(extDir, credPath, peerTokenId, apiBaseArg = "") {
  const apiBase = apiBaseArg || (await resolveRoditApiBaseUrl({ extDir, credPath }));
  const { fetchTokenIdentityFull } = await loadIdentityApiClient(extDir);
  const identity = await fetchTokenIdentityFull(peerTokenId, {
    identityApiBaseUrl: apiBase,
    logLevel: process.env.LOG_LEVEL || "error",
  });
  return { identity, apiBase };
}

export function contactUriFromIdentity(identity) {
  const contactUri =
    identity?.dn?.contactUri ||
    identity?.dn?.allAttributes?.ContactURI ||
    identity?.contactUri ||
    "";
  return String(contactUri || "").trim();
}

export function contactUriFromOwnRodit(ownRodit = {}) {
  const dn = ownRodit?.dn ?? {};
  const meta = ownRodit?.metadata ?? {};
  return String(
    dn.contactUri ||
      dn.allAttributes?.ContactURI ||
      meta.contactUri ||
      meta.contact_uri ||
      ownRodit?.contactUri ||
      "",
  ).trim();
}

export function displayNameFromOwnRodit(ownRodit = {}) {
  const dn = ownRodit?.dn ?? {};
  const meta = ownRodit?.metadata ?? {};
  return String(
    dn.displayName ||
      dn.cn ||
      dn.allAttributes?.DisplayName ||
      dn.allAttributes?.CN ||
      meta.display_name ||
      meta.displayName ||
      ownRodit?.display_name ||
      "",
  ).trim();
}

export function displayNameFromIdentity(identity) {
  const dn = identity?.dn ?? {};
  return String(
    dn.displayName ||
      dn.cn ||
      dn.allAttributes?.DisplayName ||
      dn.allAttributes?.CN ||
      identity?.displayName ||
      identity?.cn ||
      "",
  ).trim();
}

export function peerEmailFromIdentity(identity) {
  return contactUriToEmail(contactUriFromIdentity(identity));
}

export async function verifyHolaViaApi(apiBase, jwt, hola, expectedRecipient = "") {
  const body = { hola };
  if (expectedRecipient) {
    body.expectedRecipient = expectedRecipient;
  }
  const res = await fetch(`${apiBase.replace(/\/+$/, "")}/api/identity/verify`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify(body),
  });
  const payload = await res.json().catch(() => ({}));
  return { status: res.status, payload };
}

/**
 * Accept an inbound probe HOLA that already passed crypto checks but failed only because
 * the prober called POST /api/identity/verify before SMTP delivery (nonce replay).
 */
export function isNonceReplayOnlyValidProbe(payload, { ownTokenId, senderTokenId, envelopeToTokenId } = {}) {
  if (!payload || payload.verified === true) return false;

  const reasons = Array.isArray(payload.failureReasons) ? payload.failureReasons : [];
  if (reasons.length !== 1 || reasons[0] !== "nonce_replay") return false;

  const checks = payload.checks || {};
  if (
    checks.signatureValid !== true ||
    checks.checksumValid !== true ||
    checks.timestampFresh !== true ||
    checks.tokenExists !== true ||
    checks.tokenActive !== true
  ) {
    return false;
  }

  const peer = String(payload.peerTokenId || "")
    .trim()
    .toLowerCase();
  const sender = String(senderTokenId || "")
    .trim()
    .toLowerCase();
  if (sender && peer && peer !== sender) return false;

  const dest = String(payload.destinatary || "")
    .trim()
    .toLowerCase();
  const own = String(ownTokenId || "")
    .trim()
    .toLowerCase();
  const envTo = String(envelopeToTokenId || "")
    .trim()
    .toLowerCase();
  if (!dest) return false;
  return dest === own || (envTo && dest === envTo);
}

/**
 * Verify an inbound email HOLA probe for the responder. Tries strict expectedRecipient
 * first, then relaxed; treats nonce-replay-only failures as good when crypto checks pass.
 */
export async function verifyInboundProbeHola(apiBase, jwt, hola, context = {}) {
  const strict = await verifyHolaViaApi(apiBase, jwt, hola, context.ownTokenId);
  if (strict.payload?.verified === true) {
    return {
      verified: true,
      status: strict.status,
      payload: strict.payload,
      peerTokenId: String(strict.payload?.peerTokenId || "").toLowerCase(),
      acceptedDespiteReplay: false,
    };
  }
  if (isNonceReplayOnlyValidProbe(strict.payload, context)) {
    return {
      verified: true,
      status: strict.status,
      payload: strict.payload,
      peerTokenId: String(strict.payload?.peerTokenId || "").toLowerCase(),
      acceptedDespiteReplay: true,
    };
  }

  const relaxed = await verifyHolaViaApi(apiBase, jwt, hola);
  if (relaxed.payload?.verified === true) {
    return {
      verified: true,
      status: relaxed.status,
      payload: relaxed.payload,
      peerTokenId: String(relaxed.payload?.peerTokenId || "").toLowerCase(),
      acceptedDespiteReplay: false,
    };
  }
  if (isNonceReplayOnlyValidProbe(relaxed.payload, context)) {
    return {
      verified: true,
      status: relaxed.status,
      payload: relaxed.payload,
      peerTokenId: String(relaxed.payload?.peerTokenId || "").toLowerCase(),
      acceptedDespiteReplay: true,
    };
  }

  return {
    verified: false,
    status: strict.status,
    payload: strict.payload,
    peerTokenId: String(strict.payload?.peerTokenId || "").toLowerCase(),
    acceptedDespiteReplay: false,
  };
}
