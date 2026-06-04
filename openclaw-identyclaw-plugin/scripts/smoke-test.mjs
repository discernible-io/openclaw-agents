#!/usr/bin/env node

/**
 * Lightweight HTTP smoke test for identyclaw plugin endpoint coverage.
 * This validates API reachability and payload shape, independent of OpenClaw runtime.
 */

const baseUrl = process.env.IDENTYCLAW_BASE_URL || "https://api.identyclaw.com";
const jwt = process.env.IDENTYCLAW_JWT || "";

async function getJson(path, auth = false) {
  const headers = {};
  if (auth) {
    if (!jwt) {
      throw new Error(`Missing IDENTYCLAW_JWT for protected endpoint ${path}`);
    }
    headers.authorization = `Bearer ${jwt}`;
  }

  const response = await fetch(`${baseUrl}${path}`, { headers });
  const text = await response.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { raw: text };
  }
  return { ok: response.ok, status: response.status, data };
}

function printResult(name, result) {
  const status = result.ok ? "PASS" : "FAIL";
  console.log(`\n[${status}] ${name} -> HTTP ${result.status}`);
  console.log(JSON.stringify(result.data, null, 2));
}

async function main() {
  const tests = [
    { name: "public: list agents", path: "/api/agents?limit=2", auth: false },
    { name: "public: list resources", path: "/api/mcp/resources?limit=3", auth: false },
    { name: "public: get resource", path: "/api/mcp/resource/openapi:swagger", auth: false }
  ];

  if (jwt) {
    tests.push(
      { name: "protected: my identity", path: "/api/me/identity", auth: true },
      { name: "protected: nonce", path: "/api/holanonce16ts", auth: true }
    );
  } else {
    console.log("IDENTYCLAW_JWT not set: protected endpoint tests will be skipped.");
  }

  let failures = 0;
  for (const t of tests) {
    try {
      const result = await getJson(t.path, t.auth);
      printResult(t.name, result);
      if (!result.ok) failures += 1;
    } catch (error) {
      failures += 1;
      console.error(`\n[FAIL] ${t.name} -> ${error.message}`);
    }
  }

  if (failures > 0) {
    console.error(`\nSmoke test completed with ${failures} failure(s).`);
    process.exit(1);
  }

  console.log("\nSmoke test completed successfully.");
}

main().catch((error) => {
  console.error(`Unexpected error: ${error.message}`);
  process.exit(1);
});
