/**
 * Shared Rodit / NEAR env helpers. API base URL comes from Passport
 * metadata.subjectuniqueidentifier_url via RoditClient.getConfigOwnRodit(),
 * with optional IDENTYCLAW_API_BASE_URL / IDENTYCLAW_BASE_URL override.
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function parseNearCreds(credPath) {
  const creds = JSON.parse(readFileSync(credPath, "utf8"));
  const accountId = creds.implicit_account_id || creds.account_id || "";
  const privateKey = creds.private_key || "";
  if (!accountId || !privateKey) {
    throw new Error("credentials missing account_id or private_key");
  }
  return { accountId, privateKey, credPath };
}

export function applyNearRoditEnv({ accountId, privateKey, credPath }) {
  process.env.RODIT_NEAR_CREDENTIALS_SOURCE = "file";
  process.env.NEAR_CREDENTIALS_FILE_PATH = credPath;
  process.env.IDENTYCLAW_ACCOUNT_ID = accountId;
  process.env.IDENTYCLAW_NEAR_PRIVATE_KEY = privateKey;
  process.env.NEAR_CONTRACT_ID =
    process.env.NEAR_CONTRACT_ID ||
    process.env.IDENTYCLAW_NEAR_CONTRACT_ID ||
    "genaaaa-identyclaw-com.near";
  process.env.LOG_LEVEL = process.env.LOG_LEVEL || "error";
  process.env.SUPPRESS_NO_CONFIG_WARNING = "true";
  process.env.SUPPRESS_STRICTNESS_CHECK = "true";
}

export function apiBaseOverrideFromEnv() {
  const raw = process.env.IDENTYCLAW_API_BASE_URL || process.env.IDENTYCLAW_BASE_URL || "";
  return normalizeApiBaseUrl(raw);
}

export function normalizeApiBaseUrl(raw) {
  const trimmed = String(raw || "").trim().replace(/\/+$/, "");
  if (!trimmed) {
    return "";
  }
  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  return `https://${trimmed}`;
}

/** Passport metadata.subjectuniqueidentifier_url — same field RoditClient uses as apiendpoint. */
export function apiBaseFromOwnRoditMeta(meta = {}) {
  return normalizeApiBaseUrl(meta.subjectuniqueidentifier_url || "");
}

export function loadRoditAuthBe(extDir) {
  const pkgPath = join(extDir, "package.json");
  const require = createRequire(pathToFileURL(pkgPath));
  return require("@rodit/rodit-auth-be");
}

export async function resolveRoditApiBaseUrl({ extDir, credPath }) {
  const override = apiBaseOverrideFromEnv();
  if (override) {
    return override;
  }

  const creds = parseNearCreds(credPath);
  applyNearRoditEnv(creds);
  const { RoditClient } = loadRoditAuthBe(extDir);
  const client = await RoditClient.create({ role: "client" });
  const own = await client.getConfigOwnRodit();
  const apiBase = apiBaseFromOwnRoditMeta(own?.own_rodit?.metadata ?? {});
  if (!apiBase) {
    throw new Error("Passport metadata missing subjectuniqueidentifier_url (api base)");
  }
  return apiBase;
}

export async function applyRoditApiBaseEnv({ extDir, credPath }) {
  const apiBase = await resolveRoditApiBaseUrl({ extDir, credPath });
  process.env.IDENTYCLAW_BASE_URL = apiBase;
  return apiBase;
}
