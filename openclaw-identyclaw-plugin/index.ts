import { Type } from "@sinclair/typebox";
import bs58 from "bs58";
import nacl from "tweetnacl";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

type LoginCache = {
  token: string;
  expiresAtMs: number;
};

type RuntimeConfig = {
  baseUrl: string;
  accountid?: string;
  // Backward compatibility for older configs/env naming.
  roditid?: string;
  nearPrivateKey?: string;
};

const ONE_MINUTE_MS = 60_000;
let loginCache: LoginCache | null = null;

function base64UrlEncode(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function toJsonText(value: unknown): string {
  return JSON.stringify(value, null, 2);
}

function readConfig(api: unknown): RuntimeConfig {
  const envBase = process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";
  const envAccountId = process.env.IDENTYCLAW_ACCOUNT_ID;
  const envRodit = process.env.IDENTYCLAW_RODIT_ID;
  const envKey = process.env.IDENTYCLAW_NEAR_PRIVATE_KEY;

  const maybeApi = api as {
    config?: Record<string, unknown>;
    getConfig?: () => Record<string, unknown> | undefined;
  };

  const fromGetConfig = maybeApi.getConfig?.() || {};
  const fromConfig = maybeApi.config || {};
  const merged = { ...fromConfig, ...fromGetConfig };

  return {
    baseUrl: String(merged.baseUrl || envBase),
    accountid: merged.accountid
      ? String(merged.accountid)
      : merged.roditid
        ? String(merged.roditid)
        : envAccountId || envRodit,
    // Preserve legacy field as a fallback source only.
    roditid: merged.roditid ? String(merged.roditid) : envRodit,
    nearPrivateKey: merged.nearPrivateKey ? String(merged.nearPrivateKey) : envKey
  };
}

function getSecretKey32(nearPrivateKey: string): Uint8Array {
  const keyBody = nearPrivateKey.replace(/^ed25519:/, "").trim();
  const decoded = bs58.decode(keyBody);
  if (decoded.length < 32) {
    throw new Error("Invalid NEAR private key: decoded length is less than 32 bytes");
  }
  return decoded.slice(0, 32);
}

async function getJwt(cfg: RuntimeConfig): Promise<string> {
  if (loginCache && loginCache.expiresAtMs - ONE_MINUTE_MS > Date.now()) {
    return loginCache.token;
  }

  if (!cfg.accountid || !cfg.nearPrivateKey) {
    throw new Error("Missing config: protected tools require accountid and nearPrivateKey");
  }

  const tsResp = await fetch(`${cfg.baseUrl}/api/login/timestamp`);
  if (!tsResp.ok) {
    throw new Error(`Failed to get login timestamp: HTTP ${tsResp.status}`);
  }
  const tsData = (await tsResp.json()) as { timestamp: number; timestamp_iso: string };
  if (!Number.isFinite(tsData.timestamp) || !tsData.timestamp_iso) {
    throw new Error("Timestamp endpoint returned invalid payload");
  }

  const message = `${cfg.accountid}${tsData.timestamp_iso}`;
  const secretKey = getSecretKey32(cfg.nearPrivateKey);
  const signature = nacl.sign.detached(new TextEncoder().encode(message), secretKey);
  const base64urlSignature = base64UrlEncode(signature);

  const loginResp = await fetch(`${cfg.baseUrl}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      accountid: cfg.accountid,
      timestamp: tsData.timestamp,
      base64url_signature: base64urlSignature
    })
  });
  if (!loginResp.ok) {
    throw new Error(`Login failed: HTTP ${loginResp.status}`);
  }
  const loginData = (await loginResp.json()) as { token: string; expiresIn?: number };
  if (!loginData.token) {
    throw new Error("Login response did not include token");
  }

  const expiresIn = Number.isFinite(loginData.expiresIn) ? Number(loginData.expiresIn) : 3600;
  loginCache = {
    token: loginData.token,
    expiresAtMs: Date.now() + expiresIn * 1000
  };

  return loginData.token;
}

async function apiGet(path: string, cfg: RuntimeConfig, auth = false): Promise<unknown> {
  const headers: Record<string, string> = {};
  if (auth) {
    headers.authorization = `Bearer ${await getJwt(cfg)}`;
  }
  const resp = await fetch(`${cfg.baseUrl}${path}`, { headers });
  if (!resp.ok) {
    throw new Error(`GET ${path} failed: HTTP ${resp.status}`);
  }
  return resp.json();
}

async function apiPost(path: string, body: unknown, cfg: RuntimeConfig, auth = false): Promise<unknown> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (auth) {
    headers.authorization = `Bearer ${await getJwt(cfg)}`;
  }
  const resp = await fetch(`${cfg.baseUrl}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body)
  });
  if (!resp.ok) {
    throw new Error(`POST ${path} failed: HTTP ${resp.status}`);
  }
  return resp.json();
}

export default definePluginEntry({
  id: "identyclaw-tools",
  name: "identyclaw Tools",
  description: "OpenClaw tools for identyclaw API",
  register(api) {
    api.registerTool({
      name: "identyclaw_list_agents",
      description: "List public identyclaw agents",
      parameters: Type.Object({
        limit: Type.Optional(Type.Number({ minimum: 1, maximum: 100 })),
        cursor: Type.Optional(Type.String())
      }),
      async execute(_id, params) {
        const cfg = readConfig(api);
        const query = new URLSearchParams();
        if (params.limit !== undefined) query.set("limit", String(params.limit));
        if (params.cursor) query.set("cursor", params.cursor);
        const suffix = query.size > 0 ? `?${query.toString()}` : "";
        const data = await apiGet(`/api/agents${suffix}`, cfg, false);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });

    api.registerTool({
      name: "identyclaw_get_my_identity",
      description: "Get caller identity from identyclaw",
      parameters: Type.Object({}),
      async execute() {
        const cfg = readConfig(api);
        const data = await apiGet("/api/me/identity", cfg, true);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });

    api.registerTool({
      name: "identyclaw_get_nonce",
      description:
        "GET /api/holanonce16ts — returns JSON { noncetsHex, timestamp, length, algorithm, requestId }. Use noncetsHex and timestamp in the HOLA line (not timestamp_iso from login).",
      parameters: Type.Object({}),
      async execute() {
        const cfg = readConfig(api);
        const data = await apiGet("/api/holanonce16ts", cfg, true);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });

    api.registerTool({
      name: "identyclaw_verify_hola",
      description: "Verify a HOLA message using identyclaw",
      parameters: Type.Object({
        hello: Type.String(),
        maxAgeMs: Type.Optional(Type.Number({ minimum: 1 }))
      }),
      async execute(_id, params) {
        const cfg = readConfig(api);
        const body = {
          hello: params.hello,
          constraints: params.maxAgeMs ? { maxAgeMs: params.maxAgeMs } : undefined
        };
        const data = await apiPost("/api/identity/verify", body, cfg, true);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });

    api.registerTool({
      name: "identyclaw_list_resources",
      description: "List identyclaw MCP-style resources",
      parameters: Type.Object({
        limit: Type.Optional(Type.Number({ minimum: 1 })),
        cursor: Type.Optional(Type.String())
      }),
      async execute(_id, params) {
        const cfg = readConfig(api);
        const query = new URLSearchParams();
        if (params.limit !== undefined) query.set("limit", String(params.limit));
        if (params.cursor) query.set("cursor", params.cursor);
        const suffix = query.size > 0 ? `?${query.toString()}` : "";
        const data = await apiGet(`/api/mcp/resources${suffix}`, cfg, false);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });

    api.registerTool({
      name: "identyclaw_get_resource",
      description: "Fetch one identyclaw MCP-style resource by URI",
      parameters: Type.Object({
        uri: Type.String()
      }),
      async execute(_id, params) {
        const cfg = readConfig(api);
        const encodedUri = params.uri.split("/").map((part) => encodeURIComponent(part)).join("/");
        const data = await apiGet(`/api/mcp/resource/${encodedUri}`, cfg, false);
        return { content: [{ type: "text", text: toJsonText(data) }] };
      }
    });
  }
});
