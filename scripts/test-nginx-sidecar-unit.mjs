#!/usr/bin/env node
/**
 * Unit tests: nginx sidecar binds live under APP_DIR, never the git clone path.
 *
 * Run: node scripts/test-nginx-sidecar-unit.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const tally = createTally();
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

function bashLib(script, env = {}) {
  const result = spawnSync(
    "bash",
    ["-c", `source "${repoRoot}/scripts/lib.sh"\n${script}`],
    {
      encoding: "utf8",
      env: { ...process.env, ...env },
    },
  );
  if (result.status !== 0) {
    throw new Error(
      `bash exited ${result.status}: ${(result.stderr || result.stdout || "").trim()}`,
    );
  }
  return (result.stdout || "").trim();
}

process.stdout.write("Nginx sidecar APP_DIR binds (unit)\n\n");

runCase("deploy-pod.sh does not bind REPO_ROOT/nginx/inc", () => {
  const src = readFileSync(join(repoRoot, "scripts/deploy-pod.sh"), "utf8");
  assert.equal(src.includes("$REPO_ROOT/nginx/inc"), false);
  assert.equal(src.includes("recreate_pod_nginx_sidecar"), true);
});

runCase("pod_nginx_bind_specs sources stay under APP_DIR even if clone is identyclaw-agents", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  try {
    mkdirSync(join(app, "nginx", "inc"), { recursive: true });
    writeFileSync(join(app, "nginx", "inc", "http-common.inc"), "# test\n");
    const out = bashLib("pod_nginx_bind_specs", {
      IDENTYCLAW_APP_DIR: app,
      REPO_ROOT: "/home/dedalo43/identyclaw-agents",
    });
    const sources = out
      .split("\n")
      .filter(Boolean)
      .map((line) => line.split(":")[0]);
    assert.ok(sources.length >= 3, `got specs:\n${out}`);
    for (const src of sources) {
      assert.equal(
        src.startsWith(`${app}/`),
        true,
        `bind source ${src} is not under APP_DIR ${app}`,
      );
      assert.equal(
        src.includes("/identyclaw-agents/"),
        false,
        `bind source ${src} still uses git clone path`,
      );
    }
    assert.equal(sources.includes(`${app}/nginx/inc`), true);
    assert.equal(sources.includes(`${app}/certs`), true);
    assert.equal(sources.includes(`${app}/nginx/nginx.conf`), true);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("prepare_pod_nginx_host_files copies nginx/inc into APP_DIR", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  try {
    writeFileSync(
      join(app, "env.local"),
      [
        "IDENTYCLAW_DEPLOY_MODE=pod",
        "AGENT_IDS=agent-a",
        "AGENT_A_PUBLIC_HOST=agent-a.example.test",
        "AGENT_A_GATEWAY_PORT=18789",
      ].join("\n") + "\n",
    );
    bashLib("prepare_pod_nginx_host_files", {
      IDENTYCLAW_APP_DIR: app,
      IDENTYCLAW_DEPLOY_MODE: "pod",
      REPO_ROOT: repoRoot,
    });
    const copied = join(app, "nginx", "inc", "http-common.inc");
    const conf = readFileSync(join(app, "nginx", "nginx.conf"), "utf8");
    assert.equal(readFileSync(copied, "utf8").includes("limit_req"), true);
    assert.equal(conf.includes("server_name"), true);
    assert.equal(conf.includes("listen 8443 ssl"), true);
    assert.equal(conf.includes("location = /telegram-webhook"), true);
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("sync_deploy_scripts_to_app_dir copies nginx/ into APP_DIR/repo", () => {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  try {
    bashLib(`sync_deploy_scripts_to_app_dir "${repoRoot}" "${app}"`, {
      IDENTYCLAW_APP_DIR: app,
    });
    assert.equal(
      readFileSync(join(app, "repo", "nginx", "inc", "openclaw-proxy.inc"), "utf8").length > 0,
      true,
    );
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

runCase("deploy_tier_app_port is Telegram-compatible port 8443", () => {
  assert.equal(bashLib('deploy_tier_app_port main'), "8443");
  assert.equal(bashLib('deploy_tier_app_port development'), "8443");
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
