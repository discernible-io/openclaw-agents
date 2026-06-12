# TEST CONSTITUTION — identyclaw-agents

Mission: verify each deployed **OpenClaw agent gateway** (A2A ingress, RODiT-signed webhooks, optional mail and IdentyClaw API touchpoints) behaves correctly on this host. Report **findings** (what happened vs what the agent stack requires). Diagnose and fix gateway, plugin, or test-harness gaps when findings show incorrect behavior.

**Out of scope here:** the IdentyClaw API deployment-time suite in the sibling [`clienttest-idc`](../clienttest-idc) repo (`target-swagger.json`, `SPEC_PERF_*`, `clienttest-idc-container`). Run that suite against `https://api.identyclaw.com` when validating API contract and performance gates.

Terminology: test outcomes are only **`passed`** or **`not-passed`** (not "success/failure"). Scripts may print `PASS`/`FAIL` on stdout; treat `PASS` → `passed` and `FAIL` → `not-passed` in reports.

## Core Workflow (Do This Every Run)

1. **Preconditions**
   - Agents are running: `podman ps` shows `openclaw-agent-a`, `openclaw-agent-b`, and/or `openclaw-agent-c` (pod mode) or standalone containers from `./identyclaw.sh start`.
   - Runtime config lives under `../identyclaw-agents-app/` (`env.local`, `agents/<id>/`, TLS certs) — not in the git checkout.
   - For HTTPS ingress tests, nginx sidecar is up (`identyclaw-nginx`) and `AGENT_*_PUBLIC_HOST` / ingress URLs in `env.local` match the tier (development **4443**, main **9443**).

2. **Run the suites** (operator-driven; not a single startup hook):
   ```bash
   ./identyclaw.sh test-a2a agent-a agent-b
   ./identyclaw.sh test-webhook agent-a
   ./identyclaw.sh test-webhook-p2p agent-b agent-a
   ./identyclaw.sh test-mail agent-a
   ```
   Advanced / CI-style runs execute `scripts/*.mjs` inside an agent container (see [Test inventory](#test-inventory)).

3. **Start with output, then logs**
   - Capture stdout/stderr from the command above; search for `FAIL`, non-zero exit, or `not-passed`.
   - For gateway-side evidence: `podman logs openclaw-agent-<id>` and `podman logs identyclaw-nginx`.

4. For every **not-passed** case, answer all three (findings only):
   - **What happened?** (HTTP status, body, headers, receipt entries, timing — observed facts)
   - **What should the agent have done or not done?** (per [Expected behavior](#expected-behavior) below)
   - **What must change?** (test script, `identyclaw.sh`, plugin, nginx config, Passport `webhook_url`, or upstream API)

5. If you cannot explain what should have happened → fix the test script or document the contract in this file first.
6. If you cannot explain what happened → improve test logging (`scripts/lib-rodit-webhook-test.mjs`, suite `.mjs` files) until the next run is fully explainable.

Do not ask preliminary questions before inspecting command output and container logs.

## Expected Behavior

These are the contracts this repo's tests enforce (not OpenAPI from `clienttest-idc`).

| Surface | Should do | Should not do |
| --- | --- | --- |
| `POST /a2a` without `Authorization` | Return **401** | Accept unauthenticated JSON-RPC |
| Agent-card discovery (`/.well-known/agent-card.json`) | Return **200** with reachable card when agent is up | 404/5xx while gateway is healthy |
| `POST /hooks/wake` (and `/hooks/agent`) without RODiT origin signature | Return **400** or **401** | Accept unsigned or garbage `x-signature` |
| `POST /hooks/*` with valid `@rodit/rodit-auth-be` signature | Return **200** / accepted webhook response | Reject a correctly signed peer payload |
| P2P webhook delivery (`send_rodit_webhook` / `send-rodit-webhook.mjs`) | Peer records event on `GET /hooks/_receipts` | Silent drop with no receipt |
| `/api/testhola` → agent `webhook_url` (optional, `SKIP_TESTHOLA=0`) | Signed delivery to `/hooks/wake` and `/hooks/agent` | Skip verification when HOLA is valid |
| IMAP (`test-mail`) | Authenticate and list envelopes when mailbox password is set | Fail auth when credentials are configured |

Reference implementation for single-host webhook ingress: [`clienttest-idc`](../clienttest-idc).

## Test Inventory

| Entry point | Module | What it exercises |
| --- | --- | --- |
| `./identyclaw.sh test-a2a <from> <to>` | `identyclaw.sh` | Agent-card fetch both ways; unauthenticated `POST /a2a` → 401 |
| `./identyclaw.sh test-webhook <id>` | `scripts/test-rodit-webhooks.mjs` (+ optional outbound, testhola) | Unsigned/invalid-sig rejection; signed ingress via `rodit-auth-be` |
| `./identyclaw.sh test-webhook-p2p <sender> <receiver>` | `scripts/test-webhooks-p2p-suite.mjs` | Outbound + inbound P2P webhook receipts |
| `./identyclaw.sh test-mail <id>` | Himalaya in container | IMAP connectivity |
| `scripts/test-a2a-p2p-suite.mjs` | A2A + webhooks | Mediated/P2P auth, optional webhook section |
| `scripts/test-p2p-peer-suite.mjs` | Dual-mode A2A | Positive and negative P2P cases |
| `scripts/test-a2a-rodit-auth.mjs` | RODiT on `/a2a` | Bearer rejection matrix |
| `scripts/test-webhooks-testhola.mjs` | IdentyClaw API + agent | HOLA-triggered webhook delivery |
| `openclaw-identyclaw-plugin/scripts/smoke-test.mjs` | IdentyClaw HTTP API | Public/protected endpoint reachability (needs `IDENTYCLAW_JWT` for auth routes) |

Shared helpers: `scripts/lib-rodit-webhook-test.mjs` (receipts, outbound/inbound runners).

## RODiT / SDK-First Policy

Use **`@rodit/rodit-auth-be`** from the agent's A2A extension (`/home/node/.openclaw/extensions/a2a`) for valid signed flows — same path production peers use.

For authenticated normal-client calls:
- Prefer `RoditClient`, `login_server`, and SDK signing helpers loaded from the extension.
- Do not replace SDK auth with hand-rolled requests that can drop `Authorization` or mis-canonicalize the signed body.

Skipping the SDK is allowed and often required for **negative** cases:
- missing or malformed `x-signature` / `x-timestamp`
- unsigned POST bodies
- wrong `Content-Type`
- truncated payloads

In those cases, use direct `fetch` against the agent ingress URL so real nginx + gateway middleware are exercised.

## Protocol-Sensitive Rule (Do Not Alter While Debugging)

Do not change protocol-critical formats or canonicalization rules during debugging. This includes:
- ISO timestamp format
- HOLA field order
- delimiter behavior
- signed message construction
- checksum algorithm
- signature encoding requirements

Changing these can invalidate digital signatures and produce misleading **not-passed** outcomes.

## Cryptographic Signature Requirements

Use real Ed25519 signatures via NEAR credential JSON and `@rodit/rodit-auth-be`.

Do not use fake or placeholder signatures for positive cases. Negative probes may send intentionally invalid hex strings.

## Findings-First Reporting

**Logs and published results must report findings**, not expectation jargon.

Use this shape:
- **What happened** — observed HTTP status, response body fields, receipt rows, errors, timings.
- **What the stack requires** — from [Expected behavior](#expected-behavior) (should do / should not do).
- **Outcome** — `passed` if behavior matches; `not-passed` if it does not.

Do not write "not-passed as expected" or "failed as expected." A negative probe where the gateway correctly rejects invalid input is a **`passed`** test; say "agent returned 401 with unsigned POST" (finding), not "failed as expected."

In structured sub-results, `expected` / `actual` mean **per-contract vs observed**, not test-runner wishful thinking.

## Passed vs Not-Passed Logic

**`passed`** — the agent (or integrated API touchpoint) behaved as required for that case, including correct rejection of invalid input.

**`not-passed`** — wrong status/payload, missing receipt, broken discovery, or acceptance of input that must be rejected.

Never hide, mock away, or fallback around real errors in ways that obscure root cause.

## Exceptional Tests (Cross-Service)

Some tests validate integration side effects not fully specified in a single OpenAPI file:

1. **Webhook receipt verification** — `GET /hooks/_receipts` after P2P or outbound delivery (`lib-rodit-webhook-test.mjs`).
2. **`/api/testhola` delivery** — IdentyClaw API signs and POSTs to the agent's Passport `webhook_url` (`test-webhooks-testhola.mjs`; gated by `SKIP_TESTHOLA`, default `1` in `identyclaw.sh`).

Rules:
- Documented in this section; do not silently remove assertions.
- Use real runtime paths (no mocked delivery).
- Preserve protocol-sensitive and cryptographic rules above.
- Report with the same what happened / what should happen / required fix structure.

## Reporting Defects

When a **not-passed** outcome is caused by implementation (not test logic), document:

### Title
**Surface**: e.g. `POST https://agent-b…/hooks/wake`  
**Test**: e.g. `test-rodit-webhooks.mjs` → `signed POST via rodit-auth-be`  
**What happened**: Observed status, body, receipts  
**What should happen**: Row from [Expected behavior](#expected-behavior)  
**Evidence**: Command output or `podman logs` excerpt  
**Required fix**: Concrete change (plugin, nginx, Passport metadata, `identyclaw.sh`, or upstream API)

## Credentials

Per-agent NEAR keys — never committed.

| Role | Location | Used for |
| --- | --- | --- |
| Agent primary | `../identyclaw-agents-app/agents/<id>/secrets/near-credentials/*.json` (mounted in container) | JWT login, webhook signing, A2A auth |
| Peer (second agent) | `../identyclaw-agents-app/agents/<peer-id>/secrets/near-credentials/*.json` or `--peer-creds` | P2P webhook inbound simulation, dual-agent suites |

Deploy/bootstrap: `./identyclaw.sh init` seeds agent trees under `../identyclaw-agents-app/agents/`; `deploy-pod.sh` / `./scripts/deploy-local-podman.sh` start the pod.

**App root resolution:** `IDENTYCLAW_APP_DIR` defaults to `../identyclaw-agents-app` (sibling of the git clone). Override with `export IDENTYCLAW_APP_DIR=…` on CI hosts where the layout differs.

**Legacy migration:** app-level `secrets/*.json` and `secrets/peer-credentials/<id>/` are still read once; bootstrap copies into `agents/<id>/secrets/near-credentials/`.

Optional: `IDENTYCLAW_API_BASE_URL` in `env.local` (default `https://api.identyclaw.com`) for testhola and plugin smoke tests.

## Test Reliability Heuristic

Prefer **`./identyclaw.sh`** wrappers over ad-hoc curls — they resolve ingress URLs, copy scripts into containers, and set `NODE_TLS_REJECT_UNAUTHORIZED=0` for self-signed tier certs.

When comparing failures, treat **`scripts/lib-rodit-webhook-test.mjs`** and **`test-rodit-webhooks.mjs`** as the canonical webhook patterns; newer suites should align with their signing and receipt checks.

Inspect git history for older modules when a newer suite disagrees with an established pattern.

## Continuous Improvement

If you identify ambiguity or recurring failure patterns, propose a constitution improvement with concrete wording in this file.
