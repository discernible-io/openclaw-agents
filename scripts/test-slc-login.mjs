#!/usr/bin/env node
/**
 * SLC game API login smoke test (RODiT challenge-response → JWT → protected routes).
 * Usage: node test-slc-login.mjs --target https://slc.identyclaw.com:8443
 */
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const apiBase = (arg("--target", "https://slc.identyclaw.com:8443") || "").replace(/\/$/, "");
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

async function fetchJson(url, opts = {}) {
  const res = await fetch(url, opts);
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain text e.g. skill.md */
  }
  return { status: res.status, json, text: text.slice(0, 800) };
}

console.log(`==> SLC login test → ${apiBase}`);

const ts = await fetchJson(`${apiBase}/api/login/timestamp`);
console.log(
  "1) GET /api/login/timestamp →",
  ts.status,
  ts.json ? `timestamp_iso=${ts.json.timestamp_iso}` : ts.text,
);

const client = await RoditClient.create({ role: "client" });
const own = await client.getConfigOwnRodit();
const tokenId = own?.own_rodit?.token_id || own?.token_id || "(unknown)";
console.log("   agent token_id:", tokenId);
console.log("   NEAR account:", process.env.IDENTYCLAW_ACCOUNT_ID?.slice(0, 16) + "…");

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

let jwt;
try {
  const result = await login_server(cfg, {
    loginPath: "/api/login",
    timestampPath: "/api/login/timestamp",
  });
  if (!result?.jwt_token) {
    console.log("2) POST /api/login → FAILED:", result?.error || JSON.stringify(result)?.slice(0, 400));
    process.exit(1);
  }
  jwt = result.jwt_token;
  console.log("2) POST /api/login → OK (jwt_token length", jwt.length + ")");
} catch (e) {
  console.log("2) POST /api/login → ERROR:", e.message);
  process.exit(1);
}

const claims = await fetchJson(`${apiBase}/api/token/claims`, {
  headers: { Authorization: `Bearer ${jwt}` },
});
console.log(
  "3) GET /api/token/claims →",
  claims.status,
  claims.json ? JSON.stringify(claims.json).slice(0, 500) : claims.text,
);

const mine = await fetchJson(`${apiBase}/api/game/games/mine`, {
  headers: { Authorization: `Bearer ${jwt}` },
});
console.log(
  "4) GET /api/game/games/mine →",
  mine.status,
  mine.json ? JSON.stringify(mine.json).slice(0, 500) : mine.text,
);

const skill = await fetchJson(`${apiBase}/api/game/skill.md`);
console.log("5) GET /api/game/skill.md →", skill.status, skill.text?.slice(0, 150).replace(/\n/g, " "));

const ok = claims.status >= 200 && claims.status < 300;
console.log(ok ? "\npassed  SLC login + token claims" : "\nnot-passed  claims check");
process.exit(ok ? 0 : 1);
