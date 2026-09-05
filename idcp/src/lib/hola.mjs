import {
  defaultBaseUrl,
  loadJwt,
  loadNearCredentials,
  loadHolaClient,
  loadSessionsMeta,
} from "./paths.mjs";
import { ensureSession } from "./session.mjs";

export async function createHolaLine({
  recipient = "MUNDO",
  baseUrl = defaultBaseUrl(),
  credentialsPath = null,
} = {}) {
  let jwt = loadJwt(baseUrl);
  if (!jwt) {
    await ensureSession({ baseUrl, force: true, credentialsPath });
    jwt = loadJwt(baseUrl);
  }

  const meta = loadSessionsMeta()[baseUrl] || {};
  let tokenId = meta.tokenId;
  if (!tokenId) {
    // Refresh session to populate tokenId via /api/me/identity
    const s = await ensureSession({ baseUrl, force: true, credentialsPath });
    tokenId = s.tokenId;
    jwt = loadJwt(baseUrl);
  }
  if (!tokenId) {
    throw new Error("tokenId unknown — ensure Passport is minted and ensure_session succeeds");
  }

  const creds = loadNearCredentials(credentialsPath);
  const { createHola } = loadHolaClient();
  const result = await createHola({
    baseUrl,
    jwt,
    nearPrivateKey: creds.nearPrivateKey,
    tokenId,
    recipient,
  });

  return {
    ok: true,
    hola: result.hola,
    tokenId: result.tokenId,
    recipient: result.recipient,
    timestamp: result.timestamp,
    // no jwt, no private key
  };
}

export async function verifyHolaLine({
  hola,
  expectedRecipient = "MUNDO",
  baseUrl = defaultBaseUrl(),
} = {}) {
  if (!hola || typeof hola !== "string") {
    throw new Error("hola string required");
  }
  const res = await fetch(`${baseUrl}/api/identity/verify`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ hola, expectedRecipient }),
  });
  const body = await res.json();
  return {
    ok: res.ok,
    status: res.status,
    verified: body.verified === true,
    body,
  };
}
