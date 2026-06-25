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

export function peerEmailFromIdentity(identity) {
  const contactUri =
    identity?.dn?.contactUri ||
    identity?.dn?.allAttributes?.ContactURI ||
    identity?.contactUri ||
    "";
  return contactUriToEmail(contactUri);
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
