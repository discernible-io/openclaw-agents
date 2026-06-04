#!/usr/bin/env node
/**
 * Preflight checks before `openclaw plugins install` or `clawhub package publish`.
 * Does not mutate files; exits non-zero on validation errors.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function fail(message) {
  console.error(`[prepare:publish] ${message}`);
  process.exit(1);
}

function warn(message) {
  console.warn(`[prepare:publish] warning: ${message}`);
}

const pkg = readJson(join(root, "package.json"));
const manifest = readJson(join(root, "openclaw.plugin.json"));

if (!pkg.name?.startsWith("@identyclaw/")) {
  warn(`package name is ${pkg.name}; ClawHub scope must match publisher owner @identyclaw`);
}

if (pkg.dependencies?.openclaw) {
  fail(
    "openclaw must not be in dependencies (use peerDependencies + devDependencies). " +
      "Bundled openclaw duplicates the gateway and breaks plugin install peer linking."
  );
}

const peer = pkg.peerDependencies?.openclaw;
if (!peer) {
  fail("peerDependencies.openclaw is required (e.g. \">=2026.5.27\")");
}

const openclawMeta = pkg.openclaw;
if (!openclawMeta?.compat?.pluginApi) {
  fail("openclaw.compat.pluginApi is required for ClawHub code-plugin publish");
}
if (!openclawMeta?.build?.openclawVersion) {
  fail("openclaw.build.openclawVersion is required for ClawHub code-plugin publish");
}
if (!openclawMeta?.extensions?.length) {
  fail("openclaw.extensions must list at least one entrypoint");
}

const runtimeExtensions = openclawMeta?.runtimeExtensions ?? [];
if (runtimeExtensions.length !== openclawMeta.extensions.length) {
  fail(
    "openclaw.runtimeExtensions length must match openclaw.extensions " +
      `(got ${runtimeExtensions.length} runtime, ${openclawMeta.extensions.length} source)`
  );
}
for (const entry of runtimeExtensions) {
  const absolute = join(root, entry);
  if (!existsSync(absolute)) {
    fail(
      `missing built runtime entry ${entry} — run "npm run build" before install/publish`
    );
  }
}

const manifestTools = new Set(manifest.contracts?.tools ?? []);
const requiredTools = [
  "identyclaw_list_agents",
  "identyclaw_get_my_identity",
  "identyclaw_get_nonce",
  "identyclaw_verify_hola",
  "identyclaw_list_resources",
  "identyclaw_get_resource"
];
for (const tool of requiredTools) {
  if (!manifestTools.has(tool)) {
    fail(`openclaw.plugin.json contracts.tools missing ${tool}`);
  }
}

const optionalProtected = [
  "identyclaw_get_my_identity",
  "identyclaw_get_nonce",
  "identyclaw_verify_hola"
];
for (const tool of optionalProtected) {
  if (!manifest.toolMetadata?.[tool]?.optional) {
    fail(`${tool} must have toolMetadata.${tool}.optional = true`);
  }
}

if (manifest.id !== "identyclaw-tools") {
  warn(`manifest id is ${manifest.id}; plugins.entries key should match this id`);
}

console.log("[prepare:publish] OK");
console.log(`  package: ${pkg.name}@${pkg.version}`);
console.log(`  plugin id: ${manifest.id}`);
console.log(`  peer openclaw: ${peer}`);
console.log(`  build.openclawVersion: ${openclawMeta.build.openclawVersion}`);
console.log(`  tools: ${[...manifestTools].join(", ")}`);
console.log("");
console.log("Next on a gateway host (Node 22+, OpenClaw CLI):");
console.log(`  openclaw plugins install ${root}`);
console.log("  openclaw doctor --fix   # relink peer openclaw if install warns");
console.log("  merge docs/openclaw.sample.json into ~/.openclaw/openclaw.json");
console.log("  restart gateway, then exercise each allowlisted tool");
