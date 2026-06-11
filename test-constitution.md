# TEST CONSTITUTION

> **Before editing:** Review [`documentation-standard.md`](documentation-standard.md).

YOU ARE THE TEST SUITE

IMPORTANT: Tests run once per deployment. You cannot run them interactively.

Terminology rule: test outcomes are only `passed` or `not-passed` (not "success/failure").

Mission: verify the API **does what it should** and **does not do what it should not**, per `@target-swagger.json`. Report **findings** (what happened vs what the spec requires). Diagnose and fix API implementation gaps when findings show incorrect behavior.

## Core Workflow (Do This Every Run)

1. Start with logs:
   - Run: `podman logs clienttest-idc-container`
   - Search for latest `not-passed` outcomes using log search tools (`rg` or equivalent).
2. For every `not-passed` test, answer all three (findings only):
   - What happened? (status, body, headers, timing — observed facts)
   - What should the API have done or not done? (per `@target-swagger.json`)
   - What must change (test suite or API) so the behavior matches the spec?
3. If you cannot explain what should have happened:
   - Fix the test module/spec alignment first, then verify in the next run.
4. If you cannot explain what happened:
   - Add or improve test logging until behavior is fully explainable in the next run.

Do not ask preliminary questions before log analysis. Diagnose from logs first.

## SDK-First Policy (With Explicit Exceptions)

Use `/sdk` facilities whenever possible, especially for valid JWT flows that should match real RODiT client behavior.

For authenticated normal-client calls:
- Use SDK-authorized `client.request()` patterns.
- Preserve JWT auth behavior.
- Do not replace SDK auth with manual requests that can silently drop/bypass authorization.

When passing custom headers to `client.request()`, ensure authorization is preserved (for example, explicitly include the bearer token if required by SDK behavior).

Skipping the SDK is allowed and often required for negative/protocol-edge cases the SDK is not designed to produce, including:
- intentionally malformed JWT strings
- impossible `Authorization` values
- login payloads with invalid/missing signatures
- rate-limit probes
- incorrect `Content-Type`
- truncated/corrupt payloads

In those cases, use direct HTTP (`fetch` or equivalent) against the API base URL so real middleware and handlers are exercised.

Deep dependencies (shared utilities, targeted SDK internals) are acceptable for diagnostics/coverage as long as protocol-sensitive rules below are respected.

## Protocol-Sensitive Rule (Do Not Alter While Debugging)

Do not change protocol-critical formats or canonicalization rules during debugging. This includes:
- ISO timestamp format
- HOLA field order
- delimiter behavior
- signed message construction
- checksum algorithm
- signature encoding requirements

Changing these can invalidate digital signatures and produce misleading `not-passed` outcomes.

## Cryptographic Signature Requirements

Use real cryptographic signatures (Ed25519, etc.) generated via SDK-compatible key handling.

Do not use fake or placeholder signatures. Signature tests must use real signatures to validate legitimate behavior.

For key-pair handling patterns, consult `/sdk` implementations.

## Findings-First Reporting

Tests may encode any internal case matrix (including fields named `expect*` in code). **Logs and published results must report findings**, not expectation jargon.

Use this shape:
- **What happened** — observed HTTP status, response body fields, errors, timings.
- **What the spec requires** — allowed or required behavior from `@target-swagger.json` (should do / should not do).
- **Outcome** — `passed` if behavior matches the spec; `not-passed` if it does not.

Do not write "not-passed as expected", "failed as expected", or similar. A negative probe where the API correctly rejects invalid input is a **`passed`** test; say "API returned 400 with `checksum_invalid`" (finding), not "failed as expected."

In structured sub-results, `expected` / `actual` mean **per-spec vs observed**, not test-runner wishful thinking.

## Passed vs Not-Passed Logic

`passed` — the API behaved as the spec requires for that case (including correct rejection of invalid input).

`not-passed` — the API did something the spec forbids, omitted something the spec requires, or returned the wrong status/payload/error contract.

Never hide, mock away, or fallback around real errors in ways that obscure root cause.

## Suite Focus and Disabling Policy

To focus debugging effort, passed suites may be disabled in `@config/default.json`:
- move suite names from `ENABLED_TEST_SUITES` to `EXCLUDED_TESTS`
- do not delete tests

IMPORTANT RULE:
- Only passed tests may be disabled by the test system.
- Not-passed tests may only be disabled by the user.
- The test system must never disable not-passed tests.

## Exceptional Tests Outside Swagger

Some tests intentionally validate real integration side effects that are not fully described in `@target-swagger.json`.

Webhook delivery verification (`/webhook`, `/hooks/wake`, `/hooks/agent`) is an approved exceptional category and may be treated as required even when endpoint-side effects are not explicitly specified in swagger.

Rules for exceptional tests:
- Must be explicitly documented in this constitution (like webhooks here).
- Must use real runtime behavior (no mocked delivery path).
- Must preserve protocol-sensitive and cryptographic rules in this document.
- Must report failures with clear "what happened / what should happen / required fix" evidence, same as swagger-backed tests.

When swagger and exceptional-test behavior diverge, do not silently downgrade assertions; update this constitution and keep the intended assertion level explicit.

## Reporting API Bugs

When a `not-passed` test is caused by API implementation (not test logic), document it using:

### Bug Title
**Endpoint**: `/api/endpoint/path`  
**Test**: `testFunctionName`  
**What Happened**: Actual behavior observed in logs  
**What the API Should Do (per spec)**: Required or forbidden behavior from `@target-swagger.json`  
**Logs**: Relevant excerpts proving the not-passed outcome  
**Required Fix**: Concrete API code/config changes required

## Test Reliability Heuristic

Older test modules (inspect via git history) are generally more trustworthy. Compare newer not-passed modules against older established patterns, especially for SDK integration and test harness behavior.

## Cryptographic Credentials

Two Ed25519 key pairs are required for full coverage (self-HOLA + peer/subagent HOLA). Both are supplied as base64-encoded NEAR credential JSON — never committed.

### Primary test / agent credentials (SDK path)
- **Env**: `NEAR_CREDENTIALS_JSON_B64` in host `secrets/secrets.env` (see `configuration-standard.md`)
- **Loader**: SDK config + `src/test-utils/near-test-credentials.js` → `loadPrimaryNearCredentials()`
- **Purpose**: Default agent key for JWT login, HOLA self-tests (`/api/testhola`), and parent-side delegated-signer signatures
- **Used in**: `identyclaw-api`, `hola-verification-coverage`, `testMultipleDelegatedSigners`, `testDelegatedSignerAuthorization` (agent)

### Peer / subagent credentials (test-only, outside SDK config)
- **Env**: `NEAR_TEST_PEER_CREDENTIALS_JSON_B64` in host `secrets/testing.env` (sibling of `secrets.env`; loaded by `src/test-utils/load-testing-env.js`, not mapped in `config/custom-environment-variables.json`)
- **Loader**: `src/test-utils/near-test-credentials.js` → `loadPeerNearCredentials()` (reads `process.env` only)
- **Purpose**: Second key pair for peer-to-peer HOLA, subagent HOLA, and delegated-signer tests that require a distinct signer
- **Used in**: `testSubagentHolaVerification`, `testDelegatedSignerAuthorization` (subagent)
- **Skip behavior**: Tests that need the peer key are skipped with `skipped: true` when `testing.env` is missing or the variable is unset

Deploy passes both env files when present: `--env-file secrets/secrets.env` and optionally `--env-file secrets/testing.env`.

Credential JSON uses NEAR format; tests convert to tweetnacl for signing.

## Performance SLOs (`SPEC_PERF_*`)

Prove Identyclaw is **not** chain-bound for authorization traffic. Run against **`https://api.identyclaw.com`** (main) or a staging host documented in suite config. Measure **end-to-end client latency** (fetch/curl from the test runner), not server-only logs.

### Tags

| Tag | Blocks deploy? | Purpose |
| --- | --- | --- |
| `@perf-main` | — | Requires healthy `/health`; fetch/curl login (not `login_server()` unless `@perf-mitm-path`) |
| `@perf-gate` | **Yes** | Correctness + architectural invariants (must pass) |
| `@perf-metric` | **No** | Latency reporting vs `SPEC_PERF_*` targets (`pass` / `warn` / `fail` — logged only) |
| `@perf-degraded` | Optional | When RPC is down |
| `@perf-mitm-path` | — | May use `login_server()` |

**Environment preconditions (infra abort, not perf regression, if unmet):**

- Target `/health` returns `status: "healthy"` (not `degraded`) for runs tagged `@perf-main`.
- `fetch failed` / HTTP **502** during perf setup → labeled **infra abort**; does not count as `@perf-metric` regression.

Warm-up: discard first sample per endpoint after login.

### `@perf-gate` — pass/fail (blocks deploy)

| Test / spec | Must pass |
| --- | --- |
| `SPEC_PERF_JWT_STEADY_POLL` | All **200** while `secondsUntilSessionExp > 0`; **`renewalCount > 0`** before credential `exp` |
| `SPEC_PERF_HOLANONCE_BURST` | All **200** within 60 s; no **429**/**5xx**; **0 NEAR RPC** delta on S2 |
| `SPEC_PERF_HOLANONCE_S2_ZERO_RPC` | **0 NEAR RPC** during S2 holanonce sampling (when metrics available) |
| `SPEC_PERF_CHAIN_READ_RATIO` | `chainReads / totalRequests ≤ 0.10` |
| `SPEC_PERF_LOGIN_ERROR_BUDGET` | `< 1%` login **5xx**; **0%** timestamp **5xx** |
| `testSessionLifetimePollUntilExpiry` | Per session-lifetime suite (`SPEC_REQUIRES_SESSION_POLL`) |
| `SPEC_PERF_RPC_DEGRADED_HEALTH` | When `/health` is `degraded` (@perf-degraded) |

### `@perf-metric` — report only (does not block deploy)

Record p50/p95/max against targets below. Status: **`pass`** / **`warn`** / **`fail`**. Emit `PERF METRIC` log lines and structured JSON records.

For `SPEC_PERF_JWT_STEADY_POLL`, emit three series:

1. `s2_non_renewal_p95` — session maintenance (apples-to-apples with traditional IAM)
2. `s2_renewal_p95` — poll(s) with `New-Token`
3. `s2_all_polls_p95` — full series (headline only)

Example log line:

```
PERF METRIC  SPEC_PERF_JWT_STEADY_POLL  p95=357ms target=200ms  WARN  (gate: PASS renewalCount=1 all200=true)
PERF GATE    SPEC_PERF_HOLANONCE_BURST  all200=true rpcDelta=0  PASS
```

### Latency targets (`@perf-metric` — reported, not deployment blockers)

| Spec ID | Endpoint / flow | Class | p95 target (ms) | Samples (min) | Notes |
| --- | --- | --- | --- | --- | --- |
| `SPEC_PERF_LOGIN_TIMESTAMP_P95_MS` | `GET /api/login/timestamp` | S1 | **250** | 30 | No auth |
| `SPEC_PERF_LOGIN_POST_P95_MS` | `POST /api/login` (full bootstrap) | S1 | **400** | 20 | Includes local sign |
| `SPEC_PERF_HOLANONCE_P95_MS` | `GET /api/holanonce16ts` | S2 | **150** | 50 | Also `@perf-gate` 0 RPC |
| `SPEC_PERF_JWT_PROTECTED_NOP_P95_MS` | Lightweight protected GET with JWT | S2 | **200** | 30 | JWT middleware only |
| `SPEC_PERF_ME_IDENTITY_P95_MS` | `GET /api/me/identity` | S3 | **1200** | 20 | Chain read expected |
| `SPEC_PERF_VERIFY_HOLA_P95_MS` | `POST /api/identity/verify` (valid fresh HOLA) | S3 | **1500** | 15 | Unique nonce per sample |
| `SPEC_PERF_AGENTS_LIST_P95_MS` | `GET /api/agents?limit=20` | S4 | **800** | 15 | Public |
| `SPEC_PERF_HEALTH_P95_MS` | `GET /health` | — | **200** | 20 | Cached RPC probe |

### Throughput / sustained-session specs

| Spec ID | `@perf-gate` criteria | `@perf-metric` (report only) |
| --- | --- | --- |
| `SPEC_PERF_HOLANONCE_BURST` | All **200**; no **429**/**5xx**; 0 NEAR RPC | p95 vs `SPEC_PERF_HOLANONCE_P95_MS` |
| `SPEC_PERF_JWT_STEADY_POLL` | All **200**; `renewalCount > 0`; min duration | `s2_non_renewal` / `s2_renewal` / `s2_all_polls` p95 vs `SPEC_PERF_JWT_PROTECTED_NOP_P95_MS` |
| `SPEC_PERF_LOGIN_ERROR_BUDGET` | `< 1%` login **5xx**; 0 timestamp **5xx** | — |
| `SPEC_PERF_CHAIN_READ_RATIO` | Ratio ≤ **0.10** | — |

### Degradation (`@perf-degraded`)

| Spec ID | Success criteria |
| --- | --- |
| `SPEC_PERF_RPC_DEGRADED_HEALTH` | When `/health` reports `degraded`: S1/S2 still **200**; S3 verify may **5xx** with `IDENTITY_VERIFICATION_FAILED` — must **not** return `verified: true` without checks |

**Suite module:** `performanceSlo` (`src/test-modules/performance-slo.js`). Thresholds in `src/test-modules/perf-slo-utils.js` (`PERF_SPECS`). Only **`@perf-gate`** failures block deployment (same train as `sessionLifetime`). **`@perf-metric`** warnings are logged in the suite summary (`gateFailures` vs `metricWarnings`).

## Continuous Improvement

If you identify ambiguity or recurring failure patterns, propose a constitution improvement with concrete wording.
