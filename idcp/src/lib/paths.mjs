import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

/**
 * App-dir root for secrets layout.
 * Prefer IDENTYCLAW_HOME = agents/<id>/ (OpenClaw per-agent state).
 * Fallback: sibling ../openclaw-agents-app next to the repo clone.
 */
export function appDir() {
  const raw =
    process.env.IDENTYCLAW_HOME ||
    process.env.IDENTYCLAW_APP_DIR ||
    "";
  if (raw) return path.resolve(raw);
  // idcp/src/lib → ../.. = idcp/ → .. = openclaw-agents/ → sibling app
  const idcpRoot = path.resolve(__dirname, "../..");
  const repoRoot = path.resolve(idcpRoot, "..");
  return path.join(path.dirname(repoRoot), "openclaw-agents-app");
}

export function secretsDir() {
  return path.join(appDir(), "secrets");
}

export function nearCredentialsDir() {
  return (
    process.env.IDENTYCLAW_NEAR_CREDENTIALS_DIR ||
    path.join(secretsDir(), "near-credentials")
  );
}

export function identyclawSecretsDir() {
  return path.join(secretsDir(), "identyclaw");
}

export function sessionsMetaPath() {
  return path.join(identyclawSecretsDir(), "sessions.json");
}

export function defaultBaseUrl() {
  return (process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com").replace(/\/$/, "");
}

export function hostKey(baseUrl) {
  return Buffer.from(baseUrl).toString("base64url");
}

export function jwtPathFor(baseUrl = defaultBaseUrl()) {
  return path.join(identyclawSecretsDir(), `jwt-${hostKey(baseUrl)}.txt`);
}

export function ensureSecretsLayout() {
  for (const dir of [secretsDir(), nearCredentialsDir(), identyclawSecretsDir()]) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    try {
      fs.chmodSync(dir, 0o700);
    } catch {
      /* ignore */
    }
  }
}

/** Load first *.json in near-credentials, or env / explicit path. */
export function loadNearCredentials(credentialsPath) {
  if (credentialsPath) {
    const raw = JSON.parse(fs.readFileSync(credentialsPath, "utf8"));
    return normalizeCreds(raw, credentialsPath);
  }
  if (process.env.IDENTYCLAW_ACCOUNT_ID && process.env.IDENTYCLAW_NEAR_PRIVATE_KEY) {
    return {
      accountid: process.env.IDENTYCLAW_ACCOUNT_ID,
      nearPrivateKey: process.env.IDENTYCLAW_NEAR_PRIVATE_KEY,
      path: "(env)",
    };
  }
  const dir = nearCredentialsDir();
  if (!fs.existsSync(dir)) {
    throw new Error(`No credentials dir: ${dir}`);
  }
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
  if (files.length === 0) {
    throw new Error(`No *.json in ${dir} — run: idcp enroll`);
  }
  // Prefer .active pointer if present
  const active = path.join(dir, ".active");
  let chosen = files[0];
  if (fs.existsSync(active)) {
    const name = fs.readFileSync(active, "utf8").trim();
    if (files.includes(name) || files.includes(`${name}.json`)) {
      chosen = files.includes(name) ? name : `${name}.json`;
    }
  }
  const full = path.join(dir, chosen);
  return normalizeCreds(JSON.parse(fs.readFileSync(full, "utf8")), full);
}

function normalizeCreds(raw, filePath) {
  const accountid = raw.account_id || raw.implicit_account_id;
  const nearPrivateKey = raw.private_key;
  if (!accountid || !nearPrivateKey) {
    throw new Error(`Invalid credentials JSON: ${filePath}`);
  }
  return { accountid, nearPrivateKey, path: filePath };
}

export function loadJwt(baseUrl = defaultBaseUrl()) {
  const p = jwtPathFor(baseUrl);
  if (!fs.existsSync(p)) return null;
  const jwt = fs.readFileSync(p, "utf8").trim();
  return jwt || null;
}

export function saveJwt(jwt, baseUrl = defaultBaseUrl(), meta = {}) {
  ensureSecretsLayout();
  const p = jwtPathFor(baseUrl);
  fs.writeFileSync(p, jwt, { mode: 0o600 });
  const sessions = loadSessionsMeta();
  sessions[baseUrl] = {
    jwt_path: p,
    jwt_length: jwt.length,
    updated_at: new Date().toISOString(),
    ...meta,
  };
  fs.writeFileSync(sessionsMetaPath(), JSON.stringify(sessions, null, 2) + "\n", {
    mode: 0o600,
  });
  return p;
}

export function loadSessionsMeta() {
  const p = sessionsMetaPath();
  if (!fs.existsSync(p)) return {};
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return {};
  }
}

export function loadHolaClient() {
  // CJS package vendored next to this ESM tree
  const vendor = path.join(__dirname, "../../vendor/hola-client/index.js");
  return require(vendor);
}
