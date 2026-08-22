#!/usr/bin/env node
/**
 * Login smoke against api.identyclaw.com (optional peer via COMPARE_LOGIN_PEER).
 * Usage: OPENCLAW_HOME=/path node compare-login-endpoints.mjs
 * Optional: COMPARE_LOGIN_PEER=https://peer.example.com:9443
 */
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const TARGETS = [
  {
    name: "api.identyclaw.com",
    base: "https://api.identyclaw.com",
    fetchOpts: {},
  },
];
const peer = (process.env.COMPARE_LOGIN_PEER || "").replace(/\/$/, "");
if (peer) {
  TARGETS.push({
    name: peer.replace(/^https?:\/\//, ""),
    base: peer,
    fetchOpts: {},
    displayBase: peer,
  });
}

const ocDir = process.env.OPENCLAW_HOME || "/home/node/.openclaw";
const credDir = join(ocDir, "secrets/near-credentials");
const credFile = readdirSync(credDir).find((f) => f.endsWith(".json"));
if (!credFile) {
  console.error("No NEAR credentials in", credDir);
  process.exit(2);
}
const credPath = join(credDir, credFile);
const creds = JSON.parse(readFileSync(credPath, "utf8"));
process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
process.env.IDENTYCLAW_ACCOUNT_ID = creds.implicit_account_id || creds.account_id;
process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = creds.private_key;
process.env.NEAR_CONTRACT_ID = process.env.NEAR_CONTRACT_ID || "genaaaa-identyclaw-com.near";
process.env.LOG_LEVEL = "error";
process.env.SUPPRESS_NO_CONFIG_WARNING = "true";

const extDir = join(ocDir, "extensions/identyclaw-a2a");
const require = createRequire(pathToFileURL(join(extDir, "package.json")));
const { RoditClient, login_server } = require("@rodit/rodit-auth-be");
const nacl = require("tweetnacl");

function mergeHeaders(fetchOpts, extra = {}) {
  return { ...(fetchOpts.headers || {}), ...extra };
}

function normUrl(u) {
  try {
    const x = new URL(u);
    x.port = "";
    return x.toString();
  } catch {
    return u || "";
  }
}

function sdkTimeFromUnix(ts) {
  return new Date(ts * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function pickHeaders(res) {
  const keys = ["content-type", "new-token", "x-request-id", "server", "date"];
  const out = {};
  for (const k of keys) {
    const v = res.headers.get(k);
    if (v) out[k] = v;
  }
  return out;
}

async function fetchJson(url, opts = {}) {
  const res = await fetch(url, opts);
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain text */
  }
  return { status: res.status, headers: pickHeaders(res), json, text: text.slice(0, 1200) };
}

function decodeJwtPayload(token) {
  return JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
}

async function loginVariant(base, fetchOpts, own, variant) {
  const ts = await fetchJson(`${base}/api/login/timestamp`, fetchOpts);
  if (!ts.json?.timestamp_iso) {
    return { variant, error: "timestamp fetch failed", tsStatus: ts.status, tsBody: ts.text };
  }

  const tid = own.own_rodit.token_id;
  const accountId = process.env.IDENTYCLAW_ACCOUNT_ID;
  const { timestamp, timestamp_iso } = ts.json;
  const sdkTime = sdkTimeFromUnix(timestamp);

  let message;
  let body;
  if (variant === "sdk_timeString") {
    message = tid + sdkTime;
    body = { timestamp, roditid: tid, roditid_base64url_signature: "" };
  } else if (variant === "timestamp_iso") {
    message = tid + timestamp_iso;
    body = { timestamp_iso, roditid: tid, roditid_base64url_signature: "" };
  } else if (variant === "account_timestamp_iso") {
    message = accountId + timestamp_iso;
    body = { timestamp_iso, accountid: accountId, base64url_signature: "" };
  } else {
    return { variant, error: "unknown variant" };
  }

  const sig = nacl.sign.detached(new TextEncoder().encode(message), own.own_rodit_bytes_private_key);
  const sigB64 = Buffer.from(sig).toString("base64url");
  if ("roditid_base64url_signature" in body) body.roditid_base64url_signature = sigB64;
  if ("base64url_signature" in body) body.base64url_signature = sigB64;

  const res = await fetch(`${base}/api/login`, {
    method: "POST",
    ...fetchOpts,
    headers: mergeHeaders(fetchOpts, {
      "Content-Type": "application/json",
      "User-Agent": "RODiT-SDK",
    }),
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain */
  }
  return {
    variant,
    signedMessage: message,
    sdkTime,
    timestamp_iso,
    sdkMatchesApiIso: sdkTime === timestamp_iso,
    status: res.status,
    headers: pickHeaders(res),
    errorCode: json?.error?.code || json?.error?.details?.failureReason || null,
    errorMessage: json?.error?.message || json?.error?.details?.failureMessage || null,
    jwtLen: json?.jwt_token?.length || 0,
    jwtPayload: json?.jwt_token ? decodeJwtPayload(json.jwt_token) : null,
    raw: !json?.jwt_token ? text.slice(0, 600) : undefined,
  };
}

const client = await RoditClient.create({ role: "client" });
const own = await client.getConfigOwnRodit();
const tid = own.own_rodit.token_id;
const chain = await client.getBlockchainService().nearorg_rpc_tokenfromroditid(tid);

const report = {
  agent: {
    token_id: tid,
    owner_id: own.own_rodit.owner_id,
    near_account: process.env.IDENTYCLAW_ACCOUNT_ID,
    near_contract: process.env.NEAR_CONTRACT_ID,
    passport_sui: own.own_rodit.metadata?.subjectuniqueidentifier_url,
    onchain_sui: chain?.metadata?.subjectuniqueidentifier_url,
    onchain_webhook: chain?.metadata?.webhook_url,
  },
  targets: {},
};

for (const t of TARGETS) {
  const displayBase = t.displayBase || t.base;
  const entry = { base: displayBase, steps: {} };

  entry.steps.discovery = await fetchJson(`${t.base}/`, t.fetchOpts);

  entry.steps.timestamp = await fetchJson(`${t.base}/api/login/timestamp`, t.fetchOpts);
  const ts = entry.steps.timestamp.json || {};
  entry.steps.timestampAnalysis = {
    timestamp: ts.timestamp,
    timestamp_iso: ts.timestamp_iso,
    sdkDerivedIso: ts.timestamp ? sdkTimeFromUnix(ts.timestamp) : null,
    sdkMatchesApiIso: ts.timestamp_iso === sdkTimeFromUnix(ts.timestamp || 0),
    hasMillisecondsInIso: /\.\d{3}Z$/.test(ts.timestamp_iso || ""),
  };

  entry.steps.loginVariants = [];
  for (const variant of ["sdk_timeString", "timestamp_iso", "account_timestamp_iso"]) {
    entry.steps.loginVariants.push(await loginVariant(t.base, t.fetchOpts, own, variant));
  }

  const cfg = {
    ...own,
    own_rodit: {
      ...own.own_rodit,
      metadata: {
        ...own.own_rodit.metadata,
        subjectuniqueidentifier_url: displayBase,
      },
    },
  };
  let sdkLogin = { ok: false };
  try {
    const result = await login_server(cfg, {
      loginPath: "/api/login",
      timestampPath: "/api/login/timestamp",
    });
    sdkLogin = {
      ok: !!result?.jwt_token,
      error: result?.error || null,
      jwtLen: result?.jwt_token?.length || 0,
      jwtPayload: result?.jwt_token ? decodeJwtPayload(result.jwt_token) : null,
    };
  } catch (e) {
    sdkLogin = { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
  entry.steps.sdkLoginServer = sdkLogin;

  if (t.name === "api.identyclaw.com") {
    try {
      const med = await client.login_server();
      entry.steps.mediatedLoginServer = {
        ok: !!med?.jwt_token,
        error: med?.error || null,
        jwtLen: med?.jwt_token?.length || 0,
        jwtPayload: med?.jwt_token ? decodeJwtPayload(med.jwt_token) : null,
      };
    } catch (e) {
      entry.steps.mediatedLoginServer = {
        ok: false,
        error: e instanceof Error ? e.message : String(e),
      };
    }
  }

  const winning =
    entry.steps.sdkLoginServer.jwtPayload ||
    entry.steps.loginVariants.find((v) => v.jwtPayload)?.jwtPayload ||
    entry.steps.mediatedLoginServer?.jwtPayload ||
    null;

  if (winning) {
    entry.steps.jwtAnalysis = {
      iss: winning.iss,
      aud: winning.aud,
      rodit_id: winning.rodit_id || winning.token_id,
      exp: winning.exp,
      iat: winning.iat,
      issMatchesTargetBase: normUrl(winning.iss) === normUrl(displayBase),
      issMatchesPassportSui: normUrl(winning.iss) === normUrl(own.own_rodit.metadata?.subjectuniqueidentifier_url),
      issMatchesOnchainSui: normUrl(winning.iss) === normUrl(chain?.metadata?.subjectuniqueidentifier_url),
    };

    const jwt =
      entry.steps.sdkLoginServer.jwtPayload
        ? (await loginVariant(t.base, t.fetchOpts, own, "timestamp_iso")).jwtPayload && null
        : null;
  }

  // Re-run one successful login to get a token for protected-route probes
  const loginForProbe = entry.steps.loginVariants.find((v) => v.status === 200 && v.jwtLen > 0);
  const probeJwtSource = loginForProbe
    ? await (async () => {
        const v = await loginVariant(t.base, t.fetchOpts, own, "timestamp_iso");
        if (v.status !== 200) return null;
        const res = await fetch(`${t.base}/api/login`, {
          method: "POST",
          ...t.fetchOpts,
          headers: mergeHeaders(t.fetchOpts, {
            "Content-Type": "application/json",
            "User-Agent": "RODiT-SDK",
          }),
          body: JSON.stringify({
            timestamp_iso: v.timestamp_iso,
            roditid: tid,
            roditid_base64url_signature: Buffer.from(
              nacl.sign.detached(new TextEncoder().encode(v.signedMessage), own.own_rodit_bytes_private_key),
            ).toString("base64url"),
          }),
        });
        const j = await res.json();
        return j.jwt_token || null;
      })()
    : entry.steps.sdkLoginServer.jwtPayload
      ? null
      : null;

  // Use sdk/mediated jwt for api; skip slc if no jwt
  let probeToken = null;
  if (t.name === "api.identyclaw.com") {
    try {
      const med = await client.login_server();
      probeToken = med?.jwt_token || null;
    } catch {
      probeToken = null;
    }
  } else {
    const v = await loginVariant(t.base, t.fetchOpts, own, "timestamp_iso");
    if (v.status === 200) {
      // already consumed above path - do fresh login
      const ts2 = await fetchJson(`${t.base}/api/login/timestamp`, t.fetchOpts);
      const msg = tid + ts2.json.timestamp_iso;
      const sig = Buffer.from(
        nacl.sign.detached(new TextEncoder().encode(msg), own.own_rodit_bytes_private_key),
      ).toString("base64url");
      const res = await fetch(`${t.base}/api/login`, {
        method: "POST",
        ...t.fetchOpts,
        headers: mergeHeaders(t.fetchOpts, {
          "Content-Type": "application/json",
          "User-Agent": "RODiT-SDK",
        }),
        body: JSON.stringify({
          timestamp_iso: ts2.json.timestamp_iso,
          roditid: tid,
          roditid_base64url_signature: sig,
        }),
      });
      if (res.status === 200) {
        const j = await res.json();
        probeToken = j.jwt_token;
      }
    }
  }

  if (probeToken) {
    for (const path of ["/api/token/claims", "/api/game/games/mine"]) {
      const probe = await fetchJson(`${t.base}${path}`, {
        ...t.fetchOpts,
        headers: mergeHeaders(t.fetchOpts, { Authorization: `Bearer ${probeToken}` }),
      });
      entry.steps[`probe${path.replace(/\//g, "_")}`] = {
        status: probe.status,
        body: probe.json || probe.text,
      };
    }
  }

  report.targets[t.name] = entry;
}

// Optional cross-target: api JWT against COMPARE_LOGIN_PEER
if (peer) {
  try {
    const med = await client.login_server();
    if (med?.jwt_token) {
      const payload = decodeJwtPayload(med.jwt_token);
      const peerClaims = await fetchJson(`${peer}/api/token/claims`, {
        headers: { Authorization: `Bearer ${med.jwt_token}` },
      });
      report.crossTarget = {
        description: `api.identyclaw.com JWT used against ${peer}`,
        apiJwtIss: payload.iss,
        apiJwtAud: payload.aud,
        peerClaimsStatus: peerClaims.status,
        peerClaimsBody: peerClaims.json || peerClaims.text,
      };
    }
  } catch (e) {
    report.crossTarget = { error: e instanceof Error ? e.message : String(e) };
  }
}

console.log(JSON.stringify(report, null, 2));
