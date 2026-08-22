#!/usr/bin/env node
/**
 * Unit tests for lib-openclaw-cache-config.mjs (no Podman).
 *
 * Run: node scripts/test-openclaw-cache-config-unit.mjs
 */
import assert from "node:assert/strict";
import {
  applyOpenclawCacheConfig,
  extractUsageFromJsonlLine,
  formatCacheStatsLine,
  normalizeUsage,
  readConfiguredSessionId,
  summarizeAgentCacheStats,
  summarizeUsageRows,
} from "./lib-openclaw-cache-config.mjs";
import { createTally, reportFinding } from "./lib-test-report.mjs";

const tally = createTally();

function runCase(surface, fn) {
  try {
    fn();
    tally.add(reportFinding(surface, true));
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    tally.add(reportFinding(surface, false, msg));
  }
}

process.stdout.write("OpenClaw cache config / stats (unit)\n\n");

runCase("applyOpenclawCacheConfig injects sticky session_id + headers", () => {
  const data = {
    agents: {
      defaults: {
        models: {
          "openrouter/deepseek/deepseek-v4-flash": {},
          "openrouter/qwen/qwen3-coder": {},
          "google/gemini-2.5-flash": {},
        },
      },
    },
    models: { providers: { openrouter: { timeoutSeconds: 120 } } },
    diagnostics: { stuckSessionWarnMs: 1 },
  };
  applyOpenclawCacheConfig(data, {
    sessionId: "identyclaw",
    cacheTrace: true,
    openrouterEnabled: true,
  });
  const flash = data.agents.defaults.models["openrouter/deepseek/deepseek-v4-flash"];
  assert.equal(flash.params.extra_body.session_id, "identyclaw");
  assert.equal(
    data.agents.defaults.models["openrouter/qwen/qwen3-coder"].params.extra_body
      .session_id,
    "identyclaw",
  );
  assert.equal(
    data.agents.defaults.models["google/gemini-2.5-flash"].params,
    undefined,
  );
  assert.equal(data.models.providers.openrouter.headers["x-session-id"], "identyclaw");
  assert.equal(
    data.models.providers.openrouter.request.headers["x-session-id"],
    "identyclaw",
  );
  assert.equal(data.diagnostics.cacheTrace.enabled, true);
  assert.equal(data.diagnostics.cacheTrace.includeMessages, undefined);
  assert.equal(data.diagnostics.cacheTrace.includePrompt, undefined);
  assert.equal(data.diagnostics.cacheTrace.includeSystem, undefined);
  assert.equal(readConfiguredSessionId(data), "identyclaw");
});

runCase("applyOpenclawCacheConfig clears sticky fields when disabled", () => {
  const data = {
    agents: {
      defaults: {
        models: {
          "openrouter/deepseek/deepseek-v4-flash": {
            params: { extra_body: { session_id: "old", keep: 1 } },
          },
        },
      },
    },
    models: {
      providers: {
        openrouter: {
          headers: { "x-session-id": "old", "X-Title": "x" },
          request: { headers: { "x-session-id": "old" } },
        },
      },
    },
  };
  applyOpenclawCacheConfig(data, {
    sessionId: "",
    cacheTrace: false,
    openrouterEnabled: true,
  });
  const entry = data.agents.defaults.models["openrouter/deepseek/deepseek-v4-flash"];
  assert.equal(entry.params.extra_body.session_id, undefined);
  assert.equal(entry.params.extra_body.keep, 1);
  assert.equal(data.models.providers.openrouter.headers["x-session-id"], undefined);
  assert.equal(data.models.providers.openrouter.headers["X-Title"], "x");
  assert.equal(data.diagnostics.cacheTrace.enabled, false);
});

runCase("normalizeUsage maps OpenRouter cached_tokens", () => {
  const n = normalizeUsage({
    prompt_tokens: 1000,
    completion_tokens: 50,
    prompt_tokens_details: { cached_tokens: 900 },
  });
  assert.deepEqual(n, {
    input: 1000,
    output: 50,
    cacheRead: 900,
    cacheWrite: 0,
  });
});

runCase("extractUsageFromJsonlLine + summarize hit rate", () => {
  const a = extractUsageFromJsonlLine(
    JSON.stringify({ usage: { input: 1000, output: 10, cacheRead: 900, cacheWrite: 0 } }),
  );
  const b = extractUsageFromJsonlLine(
    JSON.stringify({ message: { usage: { input: 1000, output: 5, cacheRead: 0 } } }),
  );
  const s = summarizeUsageRows([a, b]);
  assert.equal(s.turns, 2);
  assert.equal(s.cacheRead, 900);
  assert.equal(s.input, 2000);
  // cacheRead ⊆ input → OpenRouter-style hit = 900/2000
  assert.ok(Math.abs(s.hitRate - 0.45) < 1e-9);
});

runCase("summarizeUsageRows uses anthropic-style denom when cacheRead > input", () => {
  const s = summarizeUsageRows([
    { input: 1500, output: 20, cacheRead: 40000, cacheWrite: 0 },
  ]);
  assert.ok(Math.abs(s.hitRate - 40000 / (1500 + 40000)) < 1e-9);
});

runCase("extractUsageFromJsonlLine reads cache-trace session:after messages[].usage", () => {
  const nested = extractUsageFromJsonlLine(
    JSON.stringify({
      stage: "session:after",
      messages: [
        { role: "user", content: "hi" },
        {
          role: "assistant",
          usage: { input: 1500, output: 20, cacheRead: 40000, cacheWrite: 0 },
        },
      ],
    }),
  );
  assert.deepEqual(nested, {
    input: 1500,
    output: 20,
    cacheRead: 40000,
    cacheWrite: 0,
  });
  const skipped = extractUsageFromJsonlLine(
    JSON.stringify({
      stage: "prompt:before",
      messages: [
        {
          role: "assistant",
          usage: { input: 1500, output: 20, cacheRead: 40000, cacheWrite: 0 },
        },
      ],
    }),
  );
  assert.equal(skipped, null);
});

runCase("summarizeAgentCacheStats + format line", () => {
  const sessionsJson = JSON.stringify({
    main: { inputTokens: 500, outputTokens: 20, cacheRead: 400, cacheWrite: 0 },
  });
  const s = summarizeAgentCacheStats({
    agentId: "agent-a",
    sessionId: "identyclaw",
    cacheTraceEnabled: true,
    sessionsJson,
    jsonlTexts: [
      JSON.stringify({ usage: { input: 500, output: 10, cacheRead: 450 } }) + "\n",
    ],
  });
  assert.equal(s.agentId, "agent-a");
  assert.equal(s.turns, 2);
  assert.equal(s.cacheRead, 850);
  const line = formatCacheStatsLine(s);
  assert.match(line, /agent-a:/);
  assert.match(line, /sticky=identyclaw/);
  assert.match(line, /cacheTrace=on/);
});

tally.printSummary("openclaw-cache-config");
process.exit(tally.exitCode());
