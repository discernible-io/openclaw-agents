#!/usr/bin/env node
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const apiBase = (process.argv[2] || "").replace(/\/$/, "");
if (!apiBase) {
  console.error("Usage: node decode-slc-jwt-iss.mjs <apiBaseUrl>");
  console.error("Example: node decode-slc-jwt-iss.mjs https://api.identyclaw.com");
  process.exit(2);
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
const { RoditClient } = require("@rodit/rodit-auth-be");
const nacl = require("tweetnacl");
const jose = require("jose");

const authMw = require(join(
  extDir,
  "node_modules/@rodit/rodit-auth-be/lib/middleware/authenticationmw.js",
));
const unixTimeToDateString = authMw.unixTimeToDateString || (async (ts) => {
  const d = new Date(ts * 1000);
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
});

const client = await RoditClient.create({ role: "client" });
const own = await client.getConfigOwnRodit();
const cfg = {
  ...own,
  own_rodit: {
    ...own.own_rodit,
    metadata: {
      ...own.own_rodit.metadata,
      subjectuniqueidentifier_url: apiBase,
    },
  },
};

console.log("agent token_id:", cfg.own_rodit.token_id);
const tsRes = await fetch(`${apiBase}/api/login/timestamp`);
const ts = await tsRes.json();
const timestamp = ts.timestamp;
const roditid = cfg.own_rodit.token_id;
const timeString = await unixTimeToDateString(timestamp);
const msg = new TextEncoder().encode(roditid + timeString);
const sig = nacl.sign.detached(msg, cfg.own_rodit_bytes_private_key);
const body = {
  timestamp,
  roditid,
  roditid_base64url_signature: Buffer.from(sig).toString("base64url"),
};

const res = await fetch(`${apiBase}/api/login`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "User-Agent": "RODiT-SDK" },
  body: JSON.stringify(body),
});
const text = await res.text();
console.log("POST /api/login →", res.status);
let data;
try {
  data = JSON.parse(text);
} catch {
  console.log(text.slice(0, 400));
  process.exit(1);
}

if (!data.jwt_token) {
  console.log("no jwt:", JSON.stringify(data).slice(0, 500));
  process.exit(1);
}

const payload = jose.decodeJwt(data.jwt_token);
console.log("JWT iss:", payload.iss);
console.log("JWT rodit_id:", payload.rodit_id);
console.log("JWT aud:", payload.aud);

const peer = await client.getBlockchainService().nearorg_rpc_tokenfromroditid(payload.rodit_id);
console.log("peer on-chain sui:", peer?.metadata?.subjectuniqueidentifier_url);

const norm = (url) => {
  try {
    const u = new URL(url);
    u.port = "";
    return u.toString();
  } catch {
    return url || "";
  }
};
console.log("normalized iss:", norm(payload.iss));
console.log("normalized expected:", norm(peer?.metadata?.subjectuniqueidentifier_url));
console.log("issuer match:", norm(payload.iss) === norm(peer?.metadata?.subjectuniqueidentifier_url));
