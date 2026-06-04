# IdentyClaw OpenClaw Plugin Implementation Plan

This document captures the next steps to validate, harden, and publish the plugin.

## 1) Goals

- Verify the plugin works end-to-end against IdentyClaw API.
- Ensure protected tools are safe and predictable on main deployments.
- Publish to ClawHub with clear install and usage instructions.

## 2) Current Status

- Plugin scaffold exists in `openclaw-identyclaw-plugin/`.
- Tool entrypoint implemented in `index.ts`.
- Manifest exists in `openclaw.plugin.json`.
- Protected tools are marked optional:
  - `identyclaw_get_my_identity`
  - `identyclaw_get_nonce`
  - `identyclaw_verify_hola`
- Smoke test script exists: `scripts/smoke-test.mjs`.

## 3) Phase 1 - Local Validation

### 3.1 Configure runtime values

Set required values (config or env):

- `IDENTYCLAW_BASE_URL` (default `https://api.identyclaw.com`)
- `IDENTYCLAW_ACCOUNT_ID`
- `IDENTYCLAW_NEAR_PRIVATE_KEY`

Optional for smoke tests:

- `IDENTYCLAW_JWT` (to include protected endpoint smoke checks without login bootstrap)

### 3.2 Run base checks

From `openclaw-identyclaw-plugin/`:

```bash
npm install
npm run build
npm run smoke:test
```

Then run protected checks:

```javascript
IDENTYCLAW_JWT = "<jwt>" npm run smoke:test;
```

### 3.3 Acceptance criteria

- Public endpoints return 2xx and expected payload shape.
- Protected endpoints return 2xx with valid JWT.
- Failures are reproducible and include actionable details.

## 4) Phase 2 - OpenClaw Runtime Testing

### 4.1 Install plugin locally

On a host with OpenClaw gateway + Node 22:

```bash
cd openclaw-identyclaw-plugin
npm install
npm run build
npm run prepare:publish
openclaw plugins install "$(pwd)"
openclaw doctor --fix   # if peer openclaw link warning under ~/.openclaw/extensions
```

Merge `docs/openclaw.sample.json` into gateway config, restart, then run tool checks in §4.2.

### 4.2 Tool-by-tool validation

Execute each tool once with known-good inputs:

- `identyclaw_list_agents`
- `identyclaw_list_resources`
- `identyclaw_get_resource`
- `identyclaw_get_my_identity`
- `identyclaw_get_nonce`
- `identyclaw_verify_hola`

### 4.3 Auth lifecycle tests

- First protected call triggers login bootstrap.
- Subsequent protected calls reuse cached JWT.
- Near-expiry JWT is refreshed successfully.

### 4.4 Negative tests

- Missing `accountid` and/or `nearPrivateKey`.
- Invalid private key format/length.
- Invalid HOLA payload for verify tool.
- API 401/403/429/5xx behavior and user-visible error handling.

## 5) Phase 3 - Hardening Tasks

1. Improve error transparency:
   - Include API response body when available on non-2xx.
2. Add retry strategy:
   - Retry transient failures (`429`, `502`, `503`, `504`) with capped backoff.
3. Add timeout controls:
   - Abort long-running requests and return explicit timeout errors.
4. CI-friendly testing:
   - Add `MOCK_FETCH=1` mode for deterministic smoke tests without network access.
5. Optional telemetry hooks:
   - Log tool success/failure counts (without sensitive key material).

## 6) Phase 4 - Packaging and Publish

### 6.1 Pre-publish checklist

- `package.json` OpenClaw metadata is valid.
- `openclaw.plugin.json` includes:
  - all tools in `contracts.tools`
  - `toolMetadata.optional` for protected tools
- README includes:
  - required configuration
  - install and test commands
  - basic tool usage examples

### 6.2 Publish flow (ClawHub)

```bash
npm run build
npm run prepare:publish
clawhub package publish . --family code-plugin --dry-run
clawhub package publish . --family code-plugin
openclaw plugins install clawhub:@identyclaw/openclaw-identyclaw-plugin
openclaw doctor --fix
```

### 6.3 Post-publish verification

- Install from `clawhub:` spec in clean environment.
- Re-run tool validation and auth lifecycle tests.
- Tag release and record changelog entry.

## 7) Rollout Strategy

- Start with public tools enabled.
- Keep protected tools optional/allowlisted initially.
- Expand adoption after successful runtime tests and stable auth behavior.

## 8) Definition of Done

- All tools validated in OpenClaw runtime.
- Protected auth flow stable with refresh behavior confirmed.
- Smoke tests pass in CI (mock mode) and at least one real network environment.
- Plugin published and installable via ClawHub.
