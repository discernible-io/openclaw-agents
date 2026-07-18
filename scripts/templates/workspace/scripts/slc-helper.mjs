#!/usr/bin/env node
/**
 * SLC auth + thin API helpers. NOT the playbook.
 *
 * Playbook (required): fetch and follow GET /api/game/skill.md
 *   node scripts/slc-helper.mjs skill
 * Then poll tasks (or SSE/webhooks) and submit required actions immediately.
 *
 * Safe commands:
 *   node scripts/slc-helper.mjs login
 *   node scripts/slc-helper.mjs skill [--save]
 *   node scripts/slc-helper.mjs tasks
 *   node scripts/slc-helper.mjs status
 *   node scripts/slc-helper.mjs join <gameId> [--name "Display Name"]
 *
 * Anti-patterns (do NOT do these):
 *   - Treat this script or operator TUI chat as the game rules
 *   - Invent /leave /exit /quit endpoints (they do not exist)
 *   - Use gameId 0 or /games/0/...
 *   - create-and-join solo lobbies (minAgents: 3 → empty lobbies cancel)
 *   - Call /honors before status is finished
 *   - Wait for operator chat to advance a turn
 *
 * Env:
 *   SLC_API   default https://slc.discernible.io:8443
 *   OPENCLAW_HOME  default /home/node/.openclaw
 *
 * Do not use node -e / python -c for SLC login — run this file (strictInlineEval).
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
const skillCachePath = join(WORKSPACE, "skills", "synthetics-last-cradle", "SKILL.md");

function usage() {
  console.error(`Usage (auth/helpers only — playbook is skill.md):
  node scripts/slc-helper.mjs login
  node scripts/slc-helper.mjs skill [--save]
  node scripts/slc-helper.mjs tasks
  node scripts/slc-helper.mjs status
  node scripts/slc-helper.mjs join <gameId> [--name "Display Name"]

Play: follow GET ${apiBase}/api/game/skill.md + poll GET /api/game/tasks.
Do not create lobbies unless skill.md says so and teammates share the same gameId.`);
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
  const res = await fetch(url, { ...opts });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    /* plain */
  }
  return { status: res.status, json, text: text.slice(0, 1200), raw: text };
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
        next: `Fetch playbook: node scripts/slc-helper.mjs skill --save`,
      },
      null,
      2,
    ),
  );
}

async function cmdSkill() {
  const res = await fetchJson(`${apiBase}/api/game/skill.md`);
  if (res.status < 200 || res.status >= 300) {
    console.error("skill.md fetch failed:", res.status, res.text);
    process.exit(1);
  }
  const body = res.raw || res.text;
  if (hasFlag("--save")) {
    mkdirSync(dirname(skillCachePath), { recursive: true });
    writeFileSync(skillCachePath, body.endsWith("\n") ? body : body + "\n");
    console.error("saved:", skillCachePath);
  }
  process.stdout.write(body.endsWith("\n") ? body : body + "\n");
}

async function cmdTasks() {
  const cache = await getJwt();
  const tasks = await fetchJson(`${apiBase}/api/game/tasks`, {
    headers: authHeaders(cache.jwt),
  });
  console.log(
    JSON.stringify(
      {
        roditId: cache.roditId,
        reminder:
          "Submit required tasks immediately (message-report + action block the table). Real gameId ULID only — never /games/0/.",
        tasks: { status: tasks.status, body: tasks.json ?? tasks.text },
      },
      null,
      2,
    ),
  );
  if (tasks.status < 200 || tasks.status >= 300) process.exit(1);
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
        playbook: `${apiBase}/api/game/skill.md`,
        reminder:
          "Prefer an existing lobby; share the exact gameId ULID. Do not create solo lobbies.",
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
  if (!gameId || gameId === "0") {
    throw new Error(
      "join requires a real gameId ULID (never 0). Prefer GET /api/game/games?status=lobby and share the exact id with teammates.",
    );
  }
  const cache = await getJwt();
  // Always send a JSON body so displayName is applied when provided.
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
        next: "Poll node scripts/slc-helper.mjs tasks (or SSE/webhooks). Follow skill.md — do not wait for operator chat.",
      },
      null,
      2,
    ),
  );
  if (join.status < 200 || join.status >= 300) process.exit(1);
}

const cmd = process.argv[2];
const displayName = argValue("--name", "");

try {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED =
    process.env.NODE_TLS_REJECT_UNAUTHORIZED ?? "0";

  if (cmd === "login") {
    await cmdLogin();
  } else if (cmd === "skill") {
    await cmdSkill();
  } else if (cmd === "tasks") {
    await cmdTasks();
  } else if (cmd === "status") {
    await cmdStatus();
  } else if (cmd === "join") {
    const gameId = process.argv[3] && !process.argv[3].startsWith("--") ? process.argv[3] : "";
    await cmdJoin(gameId, displayName);
  } else if (cmd === "create-and-join") {
    console.error(`ERROR: create-and-join was removed — it caused solo lobbies that cancel at minAgents: 3.

Playbook:
  1) node scripts/slc-helper.mjs skill --save
  2) node scripts/slc-helper.mjs status   # list open lobbies
  3) Share one gameId ULID with teammates, then:
     node scripts/slc-helper.mjs join <gameId> [--name "Display Name"]
  4) Poll: node scripts/slc-helper.mjs tasks

Only POST /api/game/games to create if status shows zero usable lobbies AND teammates agree on that new id.`);
    process.exit(2);
  } else {
    usage();
  }
} catch (e) {
  console.error("ERROR:", e.message || e);
  process.exit(1);
}
