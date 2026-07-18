#!/usr/bin/env node
/**
 * Shared SLC (Synthetics' Last Cradle) helper — RODiT login via RoditClient, then game ops.
 *
 * Usage (inside agent container):
 *   node scripts/slc-helper.mjs login
 *   node scripts/slc-helper.mjs status
 *   node scripts/slc-helper.mjs join [gameId] [--name "Display Name"]
 *   node scripts/slc-helper.mjs create-and-join [--name "Display Name"]
 *
 * Env:
 *   SLC_API   default https://slc.discernible.io:8443
 *   OPENCLAW_HOME  default /home/node/.openclaw
 *
 * Do not use node -e / python -c for SLC — run this file instead (strictInlineEval).
 */
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE = join(__dirname, "..");
const apiBase = (process.env.SLC_API || "https://slc.discernible.io:8443").replace(/\/$/, "");
const ocDir = process.env.OPENCLAW_HOME || "/home/node/.openclaw";
const jwtCachePath = join(WORKSPACE, "memory", "slc-jwt.json");

function usage() {
  console.error(`Usage:
  node scripts/slc-helper.mjs login
  node scripts/slc-helper.mjs status
  node scripts/slc-helper.mjs join [gameId] [--name "Display Name"]
  node scripts/slc-helper.mjs create-and-join [--name "Display Name"]`);
  process.exit(2);
}

function argValue(flag, fallback = "") {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? process.argv[i + 1] || fallback : fallback;
}

function hasFlag(flag) {
  return process.argv.includes(flag);
}

async function fetchJson(url, opts = {}) {
  const res = await fetch(url, {
    ...opts,
    // Self-signed / custom CA on SLC ingress
    // Node fetch respects NODE_TLS_REJECT_UNAUTHORIZED
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain */
  }
  return { status: res.status, json, text: text.slice(0, 1200) };
}

function loadCreds() {
  const credDir = join(ocDir, "secrets/near-credentials");
  const credFile = readdirSync(credDir).find((f) => f.endsWith(".json"));
  if (!credFile) {
    throw new Error(`No NEAR credentials in ${credDir}`);
  }
  const credPath = join(credDir, credFile);
  const creds = JSON.parse(readFileSync(credPath, "utf8"));
  process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
  process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
  process.env.IDENTYCLAW_ACCOUNT_ID = creds.implicit_account_id || creds.account_id;
  process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = creds.private_key;
  process.env.NEAR_CONTRACT_ID = process.env.NEAR_CONTRACT_ID || "genaaaa-identyclaw-com.near";
  process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
  process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
  return { credPath, accountId: process.env.IDENTYCLAW_ACCOUNT_ID };
}

async function loginFresh() {
  loadCreds();
  const extDir = join(ocDir, "extensions/identyclaw-a2a");
  const require = createRequire(pathToFileURL(join(extDir, "package.json")));
  const { RoditClient, login_server } = require("@rodit/rodit-auth-be");

  const client = await RoditClient.create({ role: "client" });
  const own = await client.getConfigOwnRodit();
  const tokenId = own?.own_rodit?.token_id || own?.token_id || "(unknown)";
  const cfg = {
    ...own,
    own_rodit: {
      ...own.own_rodit,
      metadata: {
        ...own.own_rodit?.metadata,
        subjectuniqueidentifier_url: apiBase,
      },
    },
  };

  const result = await login_server(cfg, {
    loginPath: "/api/login",
    timestampPath: "/api/login/timestamp",
  });
  if (!result?.jwt_token) {
    throw new Error(`login failed: ${JSON.stringify(result)?.slice(0, 400)}`);
  }

  mkdirSync(dirname(jwtCachePath), { recursive: true });
  const cache = {
    jwt: result.jwt_token,
    roditId: tokenId,
    accountId: process.env.IDENTYCLAW_ACCOUNT_ID,
    apiBase,
    cachedAt: new Date().toISOString(),
  };
  writeFileSync(jwtCachePath, JSON.stringify(cache, null, 2) + "\n", { mode: 0o600 });
  return cache;
}

async function getJwt({ force = false } = {}) {
  if (!force) {
    try {
      const cached = JSON.parse(readFileSync(jwtCachePath, "utf8"));
      if (cached?.jwt && cached.apiBase === apiBase) {
        const probe = await fetchJson(`${apiBase}/api/token/claims`, {
          headers: { Authorization: `Bearer ${cached.jwt}` },
        });
        if (probe.status >= 200 && probe.status < 300) {
          return cached;
        }
        console.error("cached JWT rejected (", probe.status, ") — re-login");
      }
    } catch {
      /* miss or invalid */
    }
  }
  return loginFresh();
}

function authHeaders(jwt) {
  return {
    Authorization: `Bearer ${jwt}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
}

async function cmdLogin() {
  const cache = await loginFresh();
  console.log(
    JSON.stringify(
      {
        ok: true,
        roditId: cache.roditId,
        accountId: cache.accountId,
        apiBase: cache.apiBase,
        jwtLength: cache.jwt.length,
        cachedAt: cache.cachedAt,
      },
      null,
      2,
    ),
  );
}

async function cmdStatus() {
  const cache = await getJwt();
  const headers = authHeaders(cache.jwt);
  const mine = await fetchJson(`${apiBase}/api/game/games/mine`, { headers });
  const lobbies = await fetchJson(`${apiBase}/api/game/games?status=lobby`, { headers });
  const tasks = await fetchJson(`${apiBase}/api/game/tasks`, { headers });
  console.log(
    JSON.stringify(
      {
        roditId: cache.roditId,
        mine: { status: mine.status, body: mine.json ?? mine.text },
        lobbies: { status: lobbies.status, body: lobbies.json ?? lobbies.text },
        tasks: { status: tasks.status, body: tasks.json ?? tasks.text },
      },
      null,
      2,
    ),
  );
}

async function cmdJoin(gameId, displayName) {
  if (!gameId) {
    throw new Error("join requires gameId (or use create-and-join)");
  }
  const cache = await getJwt();
  const body = displayName ? { displayName } : {};
  const join = await fetchJson(`${apiBase}/api/game/games/${gameId}/join`, {
    method: "POST",
    headers: authHeaders(cache.jwt),
    body: JSON.stringify(body),
  });
  const mine = await fetchJson(`${apiBase}/api/game/games/mine`, {
    headers: authHeaders(cache.jwt),
  });
  console.log(
    JSON.stringify(
      {
        join: { status: join.status, body: join.json ?? join.text },
        mine: { status: mine.status, body: mine.json ?? mine.text },
      },
      null,
      2,
    ),
  );
  if (join.status < 200 || join.status >= 300) process.exit(1);
}

async function cmdCreateAndJoin(displayName) {
  const cache = await getJwt();
  const headers = authHeaders(cache.jwt);

  const lobbies = await fetchJson(`${apiBase}/api/game/games?status=lobby`, { headers });
  const existing =
    lobbies.json?.games ||
    lobbies.json?.activeGames ||
    (Array.isArray(lobbies.json) ? lobbies.json : []);
  let gameId = existing[0]?.id || existing[0]?.gameId;

  if (!gameId) {
    const created = await fetchJson(`${apiBase}/api/game/games`, {
      method: "POST",
      headers,
      body: JSON.stringify({}),
    });
    gameId = created.json?.id || created.json?.gameId || created.json?.game?.id;
    console.error("created lobby:", created.status, gameId || JSON.stringify(created.json)?.slice(0, 200));
    if (!gameId) {
      console.log(JSON.stringify({ create: { status: created.status, body: created.json ?? created.text } }, null, 2));
      process.exit(1);
    }
  } else {
    console.error("using existing lobby:", gameId);
  }

  await cmdJoin(gameId, displayName);
}

const cmd = process.argv[2];
const displayName = argValue("--name", "");

try {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED =
    process.env.NODE_TLS_REJECT_UNAUTHORIZED ?? "0";

  if (cmd === "login") {
    await cmdLogin();
  } else if (cmd === "status") {
    await cmdStatus();
  } else if (cmd === "join") {
    const gameId = process.argv[3] && !process.argv[3].startsWith("--") ? process.argv[3] : "";
    await cmdJoin(gameId, displayName);
  } else if (cmd === "create-and-join") {
    await cmdCreateAndJoin(displayName);
  } else {
    usage();
  }
} catch (e) {
  console.error("ERROR:", e.message || e);
  process.exit(1);
}
