/**
 * OpenRouter sticky session_id + prompt-cache observability helpers.
 *
 * Sticky routing: one fixed session_id (or x-session-id) pins OpenRouter traffic
 * to the same backend so KV/prompt cache stays warm across agents/turns.
 * See https://openrouter.ai/docs/guides/best-practices/prompt-caching
 */

/**
 * @typedef {{
 *   sessionId?: string,
 *   cacheTrace?: boolean,
 *   openrouterEnabled?: boolean,
 * }} CacheConfigOptions
 */

/**
 * Apply sticky OpenRouter session_id + diagnostics.cacheTrace onto openclaw.json data.
 * Mutates and returns `data`.
 *
 * @param {Record<string, unknown>} data
 * @param {CacheConfigOptions} opts
 */
export function applyOpenclawCacheConfig(data, opts = {}) {
  const sessionId = normalizeSessionId(opts.sessionId);
  const cacheTrace = opts.cacheTrace !== false;
  const openrouterEnabled = opts.openrouterEnabled !== false;

  const agents = asObject(data.agents) || (data.agents = {});
  const defaults = asObject(agents.defaults) || (agents.defaults = {});
  const modelsAllow = asObject(defaults.models) || (defaults.models = {});

  for (const [modelId, rawEntry] of Object.entries(modelsAllow)) {
    const entry = asObject(rawEntry) || {};
    modelsAllow[modelId] = entry;
    if (!openrouterEnabled || !sessionId || !String(modelId).startsWith("openrouter/")) {
      stripStickySessionFromModelEntry(entry);
      continue;
    }
    const params = asObject(entry.params) || (entry.params = {});
    const extraBody =
      asObject(params.extra_body) ||
      asObject(params.extraBody) ||
      (params.extra_body = {});
    delete params.extraBody;
    params.extra_body = extraBody;
    extraBody.session_id = sessionId;
  }

  const models = asObject(data.models) || (data.models = {});
  const providers = asObject(models.providers) || (models.providers = {});
  const openrouter = asObject(providers.openrouter) || (providers.openrouter = {});

  if (openrouterEnabled && sessionId) {
    const headers = asObject(openrouter.headers) || (openrouter.headers = {});
    headers["x-session-id"] = sessionId;
    const request = asObject(openrouter.request) || (openrouter.request = {});
    const reqHeaders = asObject(request.headers) || (request.headers = {});
    reqHeaders["x-session-id"] = sessionId;
  } else {
    stripStickySessionFromProvider(openrouter);
  }

  const diagnostics = asObject(data.diagnostics) || (data.diagnostics = {});
  const ct = asObject(diagnostics.cacheTrace) || (diagnostics.cacheTrace = {});
  ct.enabled = cacheTrace;
  // OpenClaw 2026.7.2+ rejects these keys — strip leftovers from older syncs.
  delete ct.includeMessages;
  delete ct.includePrompt;
  delete ct.includeSystem;

  return data;
}

/**
 * Read sticky session id currently configured on openclaw.json data (if any).
 * @param {Record<string, unknown>} data
 * @returns {string}
 */
export function readConfiguredSessionId(data) {
  const providers = asObject(asObject(data.models)?.providers);
  const openrouter = asObject(providers?.openrouter);
  const headerId =
    asObject(openrouter?.headers)?.["x-session-id"] ||
    asObject(asObject(openrouter?.request)?.headers)?.["x-session-id"];
  if (typeof headerId === "string" && headerId.trim()) return headerId.trim();

  const modelsAllow = asObject(asObject(asObject(data.agents)?.defaults)?.models) || {};
  for (const entry of Object.values(modelsAllow)) {
    const params = asObject(asObject(entry)?.params);
    const extra =
      asObject(params?.extra_body) || asObject(params?.extraBody) || {};
    if (typeof extra.session_id === "string" && extra.session_id.trim()) {
      return extra.session_id.trim();
    }
  }
  return "";
}

/**
 * Normalize a usage-like object into counters.
 * @param {unknown} raw
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number } | null}
 */
export function normalizeUsage(raw) {
  const u = asObject(raw);
  if (!u) return null;
  const input = num(u.input ?? u.inputTokens ?? u.prompt_tokens ?? u.promptTokens);
  const output = num(u.output ?? u.outputTokens ?? u.completion_tokens ?? u.completionTokens);
  const cacheRead = num(
    u.cacheRead ??
      u.cache_read ??
      u.cache_read_input_tokens ??
      asObject(u.prompt_tokens_details)?.cached_tokens ??
      asObject(u.input_tokens_details)?.cached_tokens ??
      asObject(u.promptTokensDetails)?.cachedTokens,
  );
  const cacheWrite = num(
    u.cacheWrite ?? u.cache_write ?? u.cache_creation_input_tokens,
  );
  if (input == null && output == null && cacheRead == null && cacheWrite == null) {
    return null;
  }
  return {
    input: input ?? 0,
    output: output ?? 0,
    cacheRead: cacheRead ?? 0,
    cacheWrite: cacheWrite ?? 0,
  };
}

/**
 * Extract usage from one OpenClaw session JSONL / cache-trace line (best-effort).
 * @param {string} line
 */
export function extractUsageFromJsonlLine(line) {
  const trimmed = String(line || "").trim();
  if (!trimmed) return null;
  let obj;
  try {
    obj = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== "object") return null;

  const stage = typeof obj.stage === "string" ? obj.stage : "";
  // cache-trace repeats the same assistant usage across many stages
  // (prompt:before, stream:context, …). Count once via session:after.
  if (stage && stage !== "session:after") {
    return normalizeUsage(obj.usage);
  }

  const candidates = [
    obj.usage,
    obj.message?.usage,
    obj.data?.usage,
    obj.payload?.usage,
    obj.assistant?.usage,
  ];
  for (const c of candidates) {
    const n = normalizeUsage(c);
    if (n) return n;
  }
  // cache-trace / session rows: usage often lives on messages[].usage
  const messages = Array.isArray(obj.messages) ? obj.messages : [];
  let fromMessages = null;
  for (const m of messages) {
    const n = normalizeUsage(asObject(m)?.usage);
    if (n) fromMessages = n;
  }
  if (fromMessages) return fromMessages;
  // Some transcript rows embed cache counters at the top level (session store shape).
  return normalizeUsage(obj);
}

/**
 * Aggregate usage rows into a cache-hit summary.
 * @param {Array<{ input: number, output: number, cacheRead: number, cacheWrite: number }>} rows
 */
export function summarizeUsageRows(rows) {
  let turns = 0;
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let turnsWithCacheRead = 0;
  for (const row of rows) {
    if (!row) continue;
    turns += 1;
    input += row.input || 0;
    output += row.output || 0;
    cacheRead += row.cacheRead || 0;
    cacheWrite += row.cacheWrite || 0;
    if ((row.cacheRead || 0) > 0) turnsWithCacheRead += 1;
  }
  // Two common shapes:
  // - OpenRouter/DeepSeek: cacheRead ⊆ input → hit = cacheRead/input
  // - Anthropic-style: input is uncached-only → hit = cacheRead/(input+cacheRead)
  let denom = 0;
  if (input > 0 && cacheRead > 0 && cacheRead <= input) {
    denom = input;
  } else if (input > 0 || cacheRead > 0) {
    denom = input + cacheRead;
  }
  const hitRate = denom > 0 ? cacheRead / denom : null;
  const hitRateClamped =
    hitRate == null ? null : Math.max(0, Math.min(1, hitRate));
  return {
    turns,
    input,
    output,
    cacheRead,
    cacheWrite,
    turnsWithCacheRead,
    hitRate: hitRateClamped,
  };
}

/**
 * Summarize one agent from sessions.json + optional jsonl / cache-trace text.
 * @param {{
 *   agentId: string,
 *   sessionId?: string,
 *   cacheTraceEnabled?: boolean,
 *   sessionsJson?: string,
 *   jsonlTexts?: string[],
 *   cacheTraceText?: string,
 * }} input
 */
export function summarizeAgentCacheStats(input) {
  const rows = [];

  if (input.sessionsJson) {
    try {
      const store = JSON.parse(input.sessionsJson);
      if (store && typeof store === "object") {
        for (const entry of Object.values(store)) {
          const n = normalizeUsage(entry);
          if (n && (n.input > 0 || n.output > 0 || n.cacheRead > 0 || n.cacheWrite > 0)) {
            rows.push(n);
          }
        }
      }
    } catch {
      // ignore malformed sessions.json
    }
  }

  for (const text of input.jsonlTexts || []) {
    for (const line of String(text).split("\n")) {
      const n = extractUsageFromJsonlLine(line);
      if (n) rows.push(n);
    }
  }

  if (input.cacheTraceText) {
    for (const line of String(input.cacheTraceText).split("\n")) {
      const n = extractUsageFromJsonlLine(line);
      if (n) rows.push(n);
    }
  }

  const summary = summarizeUsageRows(rows);
  return {
    agentId: input.agentId,
    sessionId: input.sessionId || "",
    cacheTraceEnabled: Boolean(input.cacheTraceEnabled),
    sources: {
      sessionEntries: Boolean(input.sessionsJson),
      jsonlFiles: (input.jsonlTexts || []).length,
      cacheTrace: Boolean(input.cacheTraceText && input.cacheTraceText.trim()),
    },
    ...summary,
  };
}

/**
 * Format a human-readable cache stats line.
 * @param {ReturnType<typeof summarizeAgentCacheStats>} s
 */
export function formatCacheStatsLine(s) {
  const pct =
    s.hitRate == null ? "n/a" : `${(s.hitRate * 100).toFixed(1)}%`;
  return (
    `${s.agentId}: hit=${pct} cacheRead=${s.cacheRead} input=${s.input} ` +
    `output=${s.output} turns=${s.turns} sticky=${s.sessionId || "(unset)"} ` +
    `cacheTrace=${s.cacheTraceEnabled ? "on" : "off"}`
  );
}

function normalizeSessionId(raw) {
  if (raw == null) return "identyclaw";
  const s = String(raw).trim();
  if (!s || s === "0" || s.toLowerCase() === "off" || s.toLowerCase() === "false") {
    return "";
  }
  return s.slice(0, 256);
}

function stripStickySessionFromModelEntry(entry) {
  const params = asObject(entry.params);
  if (!params) return;
  for (const key of ["extra_body", "extraBody"]) {
    const extra = asObject(params[key]);
    if (!extra) continue;
    delete extra.session_id;
    if (Object.keys(extra).length === 0) delete params[key];
  }
  if (Object.keys(params).length === 0) delete entry.params;
}

function stripStickySessionFromProvider(openrouter) {
  const headers = asObject(openrouter.headers);
  if (headers) {
    delete headers["x-session-id"];
    if (Object.keys(headers).length === 0) delete openrouter.headers;
  }
  const request = asObject(openrouter.request);
  if (request) {
    const reqHeaders = asObject(request.headers);
    if (reqHeaders) {
      delete reqHeaders["x-session-id"];
      if (Object.keys(reqHeaders).length === 0) delete request.headers;
    }
    if (Object.keys(request).length === 0) delete openrouter.request;
  }
}

function asObject(v) {
  return v && typeof v === "object" && !Array.isArray(v) ? v : null;
}

function num(v) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) {
    return Number(v);
  }
  return null;
}
