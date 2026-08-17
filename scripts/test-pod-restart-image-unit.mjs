#!/usr/bin/env node
/**
 * Unit tests: pod restart image fallback + restart-all continues remaining agents.
 *
 * Run: node scripts/test-pod-restart-image-unit.mjs
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const tally = createTally();
const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const ghcrImage = "ghcr.io/example/openclaw-agent:deadbeef-development";

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

function writeFakePodman(binDir, script) {
  const path = join(binDir, "podman");
  writeFileSync(path, script);
  chmodSync(path, 0o755);
  return path;
}

function bashLib(script, { fakePodman, allowFailure = false } = {}) {
  const app = mkdtempSync(join(tmpdir(), "openclaw-agents-app-"));
  const bin = mkdtempSync(join(tmpdir(), "openclaw-fake-bin-"));
  writeFileSync(
    join(app, "env.local"),
    [
      "IDENTYCLAW_DEPLOY_MODE=pod",
      "AGENT_IDS=agent-a agent-c agent-e",
      "OPENCLAW_LOCAL_IMAGE=localhost/openclaw-agent:local",
      "",
    ].join("\n"),
  );
  writeFakePodman(bin, fakePodman);
  try {
    const result = spawnSync(
      "bash",
      ["-c", `source "${repoRoot}/scripts/lib.sh"\n${script}`],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          IDENTYCLAW_APP_DIR: app,
        },
      },
    );
    if (!allowFailure && result.status !== 0) {
      throw new Error(
        `bash exited ${result.status}: ${(result.stderr || result.stdout || "").trim()}`,
      );
    }
    return {
      status: result.status ?? 1,
      stdout: (result.stdout || "").trim(),
      stderr: (result.stderr || "").trim(),
    };
  } finally {
    rmSync(app, { recursive: true, force: true });
    rmSync(bin, { recursive: true, force: true });
  }
}

const fakeMissingPreferred = `#!/usr/bin/env bash
cmd="\${1:-}"
shift || true
case "\$cmd" in
  image)
    exit 1
    ;;
  inspect)
    container="\${1:-}"
    if [[ "\$container" == "openclaw-agent-c" ]]; then
      echo "${ghcrImage}"
      exit 0
    fi
    exit 1
    ;;
  images)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
`;

process.stdout.write("Pod restart image fallback (unit)\n\n");

runCase("identyclaw.sh restart all continues remaining AGENT_IDS after one failure", () => {
  const src = readFileSync(join(repoRoot, "identyclaw.sh"), "utf8");
  const start = src.indexOf("cmd_restart()");
  const end = src.indexOf("cmd_near_activate()");
  assert.ok(start >= 0 && end > start, "cmd_restart body not found");
  const body = src.slice(start, end);
  assert.equal(body.includes('start_pod_agent "$id" restart || failed+=("$id")'), true);
  assert.equal(body.includes("Restart failed for:"), true);
});

runCase("resolve_openclaw_run_image uses configured ref when it exists locally", () => {
  const out = bashLib('resolve_openclaw_run_image openclaw-agent-a', {
    fakePodman: `#!/usr/bin/env bash
cmd="\${1:-}"
shift || true
case "\$cmd" in
  image)
    [[ "\${2:-}" == "localhost/openclaw-agent:local" ]] && exit 0
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
`,
  });
  assert.equal(out.stdout, "localhost/openclaw-agent:local");
});

runCase("resolve_openclaw_run_image reuses this container image when configured ref is absent", () => {
  const out = bashLib('resolve_openclaw_run_image openclaw-agent-a', {
    fakePodman: `#!/usr/bin/env bash
cmd="\${1:-}"
shift || true
case "\$cmd" in
  image) exit 1 ;;
  inspect)
    [[ "\${1:-}" == "openclaw-agent-a" ]] || exit 1
    echo "${ghcrImage}"
    exit 0
    ;;
  *) exit 1 ;;
esac
`,
  });
  assert.equal(out.stdout, ghcrImage);
});

runCase("resolve_openclaw_run_image reuses a sibling AGENT_IDS container image", () => {
  const out = bashLib('resolve_openclaw_run_image openclaw-agent-a', {
    fakePodman: fakeMissingPreferred,
  });
  assert.equal(out.stdout, ghcrImage);
});

runCase("resolve_openclaw_run_image reuses a local openclaw-agent image when no containers remain", () => {
  const out = bashLib('resolve_openclaw_run_image openclaw-agent-a', {
    fakePodman: `#!/usr/bin/env bash
cmd="\${1:-}"
shift || true
case "\$cmd" in
  image) exit 1 ;;
  inspect) exit 1 ;;
  images)
    printf '%s\\n' "${ghcrImage}" "localhost/nginx:latest"
    exit 0
    ;;
  *) exit 1 ;;
esac
`,
  });
  assert.equal(out.stdout, ghcrImage);
});

runCase("resolve_openclaw_run_image exits nonzero when no agent image is available", () => {
  const out = bashLib('resolve_openclaw_run_image openclaw-agent-a', {
    fakePodman: `#!/usr/bin/env bash
exit 1
`,
    allowFailure: true,
  });
  assert.notEqual(out.status, 0);
  assert.equal(out.stdout, "");
});

runCase("recreate_pod_agent_container calls resolve_openclaw_run_image", () => {
  const src = readFileSync(join(repoRoot, "scripts/lib.sh"), "utf8");
  const start = src.indexOf("recreate_pod_agent_container()");
  const end = src.indexOf("start_pod_agent()");
  assert.ok(start >= 0 && end > start, "recreate_pod_agent_container body not found");
  const body = src.slice(start, end);
  assert.equal(body.includes('resolve_openclaw_run_image "$container"'), true);
  assert.equal(body.includes("No OpenClaw image configured"), false);
});

tally.printSummary("Summary");
process.exit(tally.exitCode());
