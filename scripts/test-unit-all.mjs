#!/usr/bin/env node
/**
 * Run all repo-local unit tests (no Podman, no rodit-auth-be regression).
 *
 * Run: node scripts/test-unit-all.mjs
 */
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));

const suites = [
  "test-peer-gateway-resolution.mjs",
  "test-hola-format-unit.mjs",
  "test-peer-identity-unit.mjs",
  "test-a2a-webhook-smoke-responder-unit.mjs",
  "test-a2a-hola-smoke-responder-unit.mjs",
  "test-agent-card-validate-unit.mjs",
  "test-mail-responder-format-unit.mjs",
  "test-openclaw-cache-config-unit.mjs",
  "test-openclaw-model-routing-unit.py",
  "test-nginx-sidecar-unit.mjs",
  "test-pod-restart-image-unit.mjs",
  "test-channels-calendar-unit.mjs",
];

process.stdout.write("Unit test orchestrator\n\n");

let failed = 0;
for (const suite of suites) {
  const path = join(root, suite);
  process.stdout.write(`======== ${suite} ========\n`);
  const cmd = suite.endsWith(".py") ? "python3" : process.execPath;
  const result = spawnSync(cmd, [path], { stdio: "inherit" });
  if (result.status !== 0) {
    failed += 1;
  }
  process.stdout.write("\n");
}

process.stdout.write(`--- Unit suites: ${suites.length - failed} passed, ${failed} not-passed ---\n`);
process.exit(failed > 0 ? 1 : 0);
