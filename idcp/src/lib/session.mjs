import nacl from "tweetnacl";
import {
  defaultBaseUrl,
  loadNearCredentials,
  saveJwt,
  loadJwt,
  loadSessionsMeta,
  ensureSecretsLayout,
  loadHolaClient,
} from "./paths.mjs";

function base64Url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

/** NEAR ed25519 key → 64-byte tweetnacl secret (not a 32-byte seed). */
function secretKeyFromNearPrivateKey(nearPrivateKey) {
  const { nearPrivateKeyToSigningSecretKey } = loadHolaClient();
  return nearPrivateKeyToSigningSecretKey(nearPrivateKey);
}

/**
 * Host-side API login. Returns metadata only (never prints full JWT).
 */
export async function ensureSession({
  baseUrl = defaultBaseUrl(),
  credentialsPath = null,
  force = false,
} = {}) {
  ensureSecretsLayout();
  const existing = loadJwt(baseUrl);
  if (existing && !force) {
    // Soft reuse — caller can force refresh
    const meta = loadSessionsMeta()[baseUrl] || {};
    return {
      ok: true,
      reused: true,
      baseUrl,
      jwt_length: existing.length,
      tokenId: meta.tokenId || null,
      accountid: meta.accountid || null,
      jwt_path: meta.jwt_path || null,
    };
  }

  const creds = loadNearCredentials(credentialsPath);
  const tsRes = await fetch(`${baseUrl}/api/login/timestamp`);
  if (!tsRes.ok) {
    throw new Error(`GET /api/login/timestamp failed (${tsRes.status})`);
  }
  const ts = await tsRes.json();
  const message = `${creds.accountid}${ts.timestamp_iso}`;
  const secretKey = secretKeyFromNearPrivateKey(creds.nearPrivateKey);
  const sig = nacl.sign.detached(new TextEncoder().encode(message), secretKey);

  const loginRes = await fetch(`${baseUrl}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      accountid: creds.accountid,
      timestamp: ts.timestamp,
      base64url_signature: base64Url(sig),
    }),
  });
  const login = await loginRes.json();
  if (!loginRes.ok || !login.jwt_token) {
    throw new Error(`POST /api/login failed: ${JSON.stringify(login)}`);
  }

  let tokenId = login.token_id || login.roditid || null;
  // Confirm identity when possible
  try {
    const meRes = await fetch(`${baseUrl}/api/me/identity`, {
      headers: { authorization: `Bearer ${login.jwt_token}` },
    });
    if (meRes.ok) {
      const me = await meRes.json();
      tokenId = me.tokenId || me.token_id || me.roditid || tokenId;
    }
  } catch {
    /* optional */
  }

  const jwt_path = saveJwt(login.jwt_token, baseUrl, {
    tokenId,
    accountid: creds.accountid,
  });

  return {
    ok: true,
    reused: false,
    baseUrl,
    jwt_length: login.jwt_token.length,
    tokenId,
    accountid: creds.accountid,
    jwt_path,
  };
}

export async function apiRequest({
  method = "GET",
  path,
  body = null,
  baseUrl = defaultBaseUrl(),
  refreshOn401 = true,
} = {}) {
  if (!path || !path.startsWith("/")) {
    throw new Error("path must be an absolute API path, e.g. /api/me/identity");
  }
  let jwt = loadJwt(baseUrl);
  if (!jwt) {
    await ensureSession({ baseUrl, force: true });
    jwt = loadJwt(baseUrl);
  }

  const doFetch = async (token) => {
    const opts = {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/json",
      },
    };
    if (body != null) {
      opts.headers["content-type"] = "application/json";
      opts.body = typeof body === "string" ? body : JSON.stringify(body);
    }
    return fetch(`${baseUrl}${path}`, opts);
  };

  let res = await doFetch(jwt);
  if (res.status === 401 && refreshOn401) {
    await ensureSession({ baseUrl, force: true });
    jwt = loadJwt(baseUrl);
    res = await doFetch(jwt);
  }

  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain */
  }
  return {
    ok: res.ok,
    status: res.status,
    baseUrl,
    path,
    body: json ?? text,
  };
}

export async function me(baseUrl = defaultBaseUrl()) {
  return apiRequest({ method: "GET", path: "/api/me/identity", baseUrl });
}

export function listSessions() {
  const sessions = loadSessionsMeta();
  return {
    ok: true,
    sessions: Object.entries(sessions).map(([baseUrl, meta]) => ({
      baseUrl,
      jwt_length: meta.jwt_length,
      tokenId: meta.tokenId || null,
      accountid: meta.accountid || null,
      updated_at: meta.updated_at || null,
      // never include jwt
    })),
  };
}
