# OpenClaw Agents 🦞

**This is [Discernible](https://www.discernible.io/)'s deployment template for
[OpenClaw](https://github.com/openclaw/openclaw).**
Upstream remains the gateway runtime (Control UI, channels, skills, plugins).
This checkout adds a rootless **Podman** operator, **IdentyClaw Passport**
identity, agent-to-agent (A2A) messaging, and optional nginx TLS ingress so
agents can onboard at [api.identyclaw.com](https://api.identyclaw.com) and then
log in to **any federated peer API** built from
[discernible-io/api-idc](https://github.com/discernible-io/api-idc) — for
example [api.lastcradle.io](https://api.lastcradle.io) — **with no API key and
no extra credentials**. The Passport *is* the credential.

| | [OpenClaw](https://github.com/openclaw/openclaw) (upstream) | This template ([discernible-io/openclaw-agents](https://github.com/discernible-io/openclaw-agents)) |
|---|---|---|
| Gateway image | `ghcr.io/openclaw/openclaw` | Pinned slim image + Himalaya, near-cli-rs, Discord (`Containerfile.agent`) |
| Host install | `openclaw onboard`, Docker, npm | Rootless **Podman** via `./identyclaw.sh` |
| Runtime state | `~/.openclaw/` | Sibling `../openclaw-agents-app/` (`./identyclaw.sh init`) |
| Agent identity | Not included | IdentyClaw Passport + `identyclaw-tools` plugin |
| Calling peer APIs | Vendor API keys in config | Prove Passport key possession; peer mints a JWT. No API keys. |
| Multi-agent / A2A | Bring your own | `identyclaw-a2a` plugin, RODiT JWT, optional peer discovery |
| Email / TLS ingress | Bring your own | Himalaya (Migadu) + optional nginx sidecar |

Operator reference: [`OPERATOR.md`](./OPERATOR.md). Product overview:
[discernible.io](https://www.discernible.io/). Enrollment contract:
[`.well-known/enrollment`](https://api.identyclaw.com/.well-known/enrollment).
Purchase: [purchase.identyclaw.com](https://purchase.identyclaw.com). Parallel
Hermes template: [discernible-io/hermes-agent](https://github.com/discernible-io/hermes-agent).

If you only want stock OpenClaw, use the
[upstream docs](https://docs.openclaw.ai). The sections below describe this
template; skip to [IdentyClaw Passport](#identyclaw-passport-discernible) for
onboarding and federated API login.

Website · [Docs](https://docs.openclaw.ai) · [Getting started](https://docs.openclaw.ai/start/getting-started) · [Showcase](https://docs.openclaw.ai/start/showcase) · [FAQ](https://docs.openclaw.ai/help/faq)

OpenClaw is a personal AI assistant that runs on your devices and meets you in
the channels you already use. It connects models, tools, messaging channels,
and optional companion apps through one Gateway. This repo packages that
runtime for multi-agent Podman hosts with IdentyClaw identity.

---

## IdentyClaw Passport (Discernible)

This template wires OpenClaw to [IdentyClaw](https://www.discernible.io/) —
portable, cryptographically verifiable agent identity on NEAR (RODiT / HOLA).

You mint a Passport **once** at IdentyClaw home. Peers resolve you by a stable
12-letter `tokenId` across hosts and redeploys. The same Passport then logs the
agent into **any federated peer** that implements the IdentyClaw login contract
— without creating an account there, without an API key, and without extra
credentials.

| Role | Host | What it does |
|------|------|----------------|
| **Home** | [api.identyclaw.com](https://api.identyclaw.com) | Issues Passport / HOLA identity, agent discovery, DID. Does **not** authorize third-party APIs. |
| **Peer** | e.g. [api.lastcradle.io](https://api.lastcradle.io), or any API from [api-idc](https://github.com/discernible-io/api-idc) | Same login challenge (`GET /api/login/timestamp` → `POST /api/login`). Mints a JWT valid **only** for that peer. |

Clients remint a JWT **per peer**. A home JWT is not accepted at lastcradle (or
any other peer), and peer tokens are not portable across peers. The
`identyclaw-tools` plugin caches each host’s JWT per agent and never exposes
raw tokens to the model.

```text
┌─────────────────────┐         ┌──────────────────────────┐
│ IdentyClaw home     │         │ Federated peer           │
│ api.identyclaw.com  │         │ e.g. api.lastcradle.io   │
│ mint Passport once  │         │ POST /api/login → JWT    │
└─────────┬───────────┘         └────────────┬─────────────┘
          │ Passport keys                    │
          └──────────────┬───────────────────┘
                         ▼
         identyclaw_ensure_session({ apiEndpoint: "<peer>" })
              (prove key possession; no API key)
```

Checkout is a **human** step. Keep NEAR private keys on disk only — never paste
them into chat. LLM providers (OpenRouter, OpenCode, …) are a separate concern;
Passport replaces **service API keys** for federated peers, not model keys.

Enrollment contract:
[`.well-known/enrollment`](https://api.identyclaw.com/.well-known/enrollment) ·
purchase: [purchase.identyclaw.com](https://purchase.identyclaw.com).

### 1. Install this repo (Podman)

Requires rootless [Podman](https://podman.io/) and Node.js 22+ on the host.
Full operator reference: [`OPERATOR.md`](./OPERATOR.md).

```bash
git clone https://github.com/discernible-io/openclaw-agents.git ~/identyclaw-agents
cd ~/identyclaw-agents
chmod +x identyclaw.sh
./identyclaw.sh init          # creates ../openclaw-agents-app/ and env.local
# Edit ../openclaw-agents-app/env.local — set AGENT_IDS (e.g. agent-a), emails, ports
./identyclaw.sh build-image
./identyclaw.sh start all
```

Runtime state lives in `../openclaw-agents-app/` (override with
`IDENTYCLAW_APP_DIR`). LLM keys and Migadu passwords can wait until after
Passport enrollment if you only need identity/A2A smoke tests.

### 2. Create a NEAR implicit account

Create credentials **before** purchasing a Passport. Keys stay on disk under
the agent’s app state — **never paste private keys into chat**.

**Option A — inside the running agent** (near-cli-rs is in the image):

```bash
podman exec -u node openclaw-agent-a \
  bash -lc 'cd /home/node/.openclaw/workspace && bash scripts/idcp-wallet.sh genaccount'
./identyclaw.sh near-activate agent-a <implicit_account_id>
```

**Option B — host [gennearaccount](https://github.com/discernible-io/gennearaccount):**

```bash
mkdir -p ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
chmod 700 ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
gennearaccount ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
./identyclaw.sh near-activate agent-a <implicit_account_id>
```

Result: `…/near-credentials/<implicit_account_id>.json` (mode `0600`) plus
`.active`. Save the 64-character hex id — it is the Passport recipient.

### 3. Get NEAR (HOT Wallet buy or swap)

Minting costs NEAR on mainnet (gas + Passport fee). Personal tier starts around
**~0.066 Ⓝ**; live quotes are on the purchase portal. A practical path is
**[HOT Wallet](https://hot-labs.org/wallet/)**:

1. Install HOT Wallet and create or import a funded NEAR account.
2. Buy NEAR, swap another asset to NEAR, or withdraw from an exchange into HOT.
3. Keep enough NEAR for the tier you will mint (plus a small gas buffer).

The agent’s **implicit** account holds the Passport keys on the server. HOT is
the human-side wallet that **pays and signs** the mint. You will paste the
agent’s 64-char hex id as the **NEAR account that receives the Passport**.

### 4. Craft the Passport at purchase.identyclaw.com

1. Open **[https://purchase.identyclaw.com](https://purchase.identyclaw.com)**.
2. Connect NEAR Wallet (HOT) and approve in the extension / popup.
3. Paste the agent’s **64-char hex** `implicit_account_id` as the recipient
   (implicit hex, not a named `*.near` account).
4. Fill creature/role, name, optional Contact URI / webhook URL
   (`./identyclaw.sh webhook-url agent-a`), pick a tier, and mint.
5. Wait for chain confirmation (~seconds).

FAQ: [purchase.identyclaw.com/faq](https://purchase.identyclaw.com/faq).

### 5. Activate on OpenClaw (home session)

This logs into **IdentyClaw home** (`https://api.identyclaw.com`) — identity,
HOLA, discovery. It does **not** log you into other APIs.

```bash
./identyclaw.sh near-activate agent-a <implicit_account_id>   # if not already active
./identyclaw.sh restart agent-a
```

Confirm Passport binding via Control UI / `./identyclaw.sh chat agent-a`, or the
`identyclaw_get_my_identity` tool. The plugin signs the peer’s login challenge
with the Passport Ed25519 key. No password, no API key, no extra account.

Day-to-day on home: `identyclaw_create_hola` / `identyclaw_verify_hola` /
`identyclaw_request` (omit `apiEndpoint`). Optional docs MCP (home JWT only):

```bash
# Inside the agent workspace — home API MCP, not federated peers
openclaw mcp add IdentyClawDocs --url https://api.identyclaw.com/mcp
```

| Path | Role |
|------|------|
| `identyclaw-agents/` | Podman scripts + `Containerfile.agent` |
| `../openclaw-agents-app/agents/<id>/secrets/near-credentials/` | NEAR key JSON + `.active` |
| `../openclaw-agents-app/agents/<id>/workspace/` | `IDENTYCLAW.md`, wallet helpers, peer skill copies |
| Plugin JWT cache | Per API host inside `identyclaw-tools` (not printed to chat) |

### 6. Log in to any federated peer (no API key)

After the Passport exists, the same keypair logs into every peer that ships the
IdentyClaw challenge-response contract. Seed known peers in `env.local`:

```bash
# ../openclaw-agents-app/env.local
IDENTYCLAW_API_ENDPOINTS=https://api.lastcradle.io
```

Restart, then via Control UI chat or `./identyclaw.sh chat`:

1. `identyclaw_ensure_session({ apiEndpoint: "https://api.lastcradle.io" })`
2. Discover that peer’s surface: `identyclaw_list_resources` / peer `skill.md`
3. Call product routes: `identyclaw_request({ method, path, apiEndpoint })`

You do not register at the peer, you do not collect a vendor key, and you must
**not** send the home JWT to the peer.

Auth contract (same on home and every [api-idc](https://github.com/discernible-io/api-idc) peer):

| Step | Endpoint | Notes |
|------|----------|--------|
| 1 | `GET /api/login/timestamp` | Fresh timestamp from **this** peer |
| 2 | Sign locally | UTF-8 `account_id` + `timestamp_iso` (Ed25519 → base64url) |
| 3 | `POST /api/login` | Signature → peer-minted `jwt_token` |
| 4 | Protected calls | `Authorization: Bearer <jwt_token>` via `identyclaw_request` |

#### Example: Synthetics' Last Cradle

```bash
OPENCLAW_HOME=~/openclaw-agents-app/agents/agent-a \
  COMPARE_LOGIN_PEER=https://api.lastcradle.io \
  node scripts/compare-login-endpoints.mjs
```

In chat, ensure a session against `https://api.lastcradle.io`, then call routes
from that peer’s skill.md. Public playbook (no JWT): peer `skill.md` ·
`peer-auth.md` · OpenAPI on the peer host.

#### Run your own peer

Fork **[discernible-io/api-idc](https://github.com/discernible-io/api-idc)** —
keep the login spine, replace the sample CRUDA, point `SERVICE_NAME` / OpenAPI
`servers` at your hostname. Then:

```bash
# Add your base to IDENTYCLAW_API_ENDPOINTS, restart, then:
identyclaw_ensure_session({ apiEndpoint: "https://your-peer.example" })
identyclaw_request({ method: "GET", path: "/api/token/claims", apiEndpoint: "https://your-peer.example" })
```

Federation shares **Rodit login only**. Home IdentyClaw routes (HOLA, DID, …)
stay on `api.identyclaw.com`. Prefer skill paths + `identyclaw_request` for
federated peers — OpenClaw remote MCP headers are static and do not use the
plugin JWT cache (see [`OPERATOR.md`](./OPERATOR.md)).

---

## Quick start

```bash
cd ~/identyclaw-agents
./identyclaw.sh init
# Edit ../openclaw-agents-app/env.local — AGENT_IDS, emails, ports
./identyclaw.sh build-image
./identyclaw.sh start all
./identyclaw.sh status
```

Then per agent in `AGENT_IDS`:

```bash
./identyclaw.sh set-password agent-a      # Migadu, when ready
./identyclaw.sh set-api-key agent-a       # OpenRouter sk-or-...
./identyclaw.sh onboard agent-a
./identyclaw.sh restart agent-a
./identyclaw.sh chat agent-a
```

- **Standalone dev:** `http://127.0.0.1:<AGENT_*_GATEWAY_PORT>/` (defaults 18789 / 18793 / 18797)
- **Pod mode:** `https://<AGENT_*_PUBLIC_HOST>:<ingress-port>/` — token: `./identyclaw.sh token <id>`
- Remote laptop: SSH tunnel the gateway ports, or use `./identyclaw.sh chat` over SSH

See [`OPERATOR.md`](./OPERATOR.md) for multi-agent layout, boot persistence,
channels, ingress, and troubleshooting.

## How it fits together

- Each agent is an isolated OpenClaw **Gateway** in a Podman container (config,
  workspace, and secrets under `../openclaw-agents-app/agents/<id>/`).
- The Control UI, CLI (`./identyclaw.sh chat` / `ask`), and TUI talk to that Gateway.
- [Channels](https://docs.openclaw.ai/channels) (Telegram, Discord, email via
  Himalaya, …) meet you where you already chat.
- IdentyClaw Passport + plugins add federated API login, A2A messaging, and
  RODiT-signed webhooks.

`AGENT_IDS` in `env.local` chooses which agents this host runs (default
`agent-a agent-c agent-e`). Trim or extend that list per machine.

## Security

Treat inbound messages as untrusted input. DM-capable channels pair unknown
senders by default. Tools run in the agent container unless you configure
further sandboxing.

Gateways bind to `127.0.0.1` by default (`PUBLISH_HOST`). Prefer SSH tunnels
over publishing Control UI on the public internet. A2A and webhooks use RODiT /
Passport credentials — not the Control UI gateway token. Read OpenClaw’s
[security](https://docs.openclaw.ai/gateway/security),
[exposure](https://docs.openclaw.ai/gateway/security/exposure-runbook), and
[sandboxing](https://docs.openclaw.ai/gateway/sandboxing) guides before
exposing a Gateway remotely.

## Documentation

| Goal | Start here |
|------|------------|
| Stock OpenClaw (models, channels, plugins) | [Docs](https://docs.openclaw.ai) · [Getting started](https://docs.openclaw.ai/start/getting-started) |
| This template (Podman, multi-agent, ingress) | [`OPERATOR.md`](./OPERATOR.md) · [`env.example`](./env.example) |
| IdentyClaw product / mint | [discernible.io](https://www.discernible.io/) · [purchase.identyclaw.com](https://purchase.identyclaw.com) |
| Federated peer API | [api-idc](https://github.com/discernible-io/api-idc) · [api.lastcradle.io](https://api.lastcradle.io) |
| Parallel Hermes template | [discernible-io/hermes-agent](https://github.com/discernible-io/hermes-agent) |

## Commands

| Command | Description |
|---------|-------------|
| `./identyclaw.sh init` | Create sibling app dir + `env.local` |
| `./identyclaw.sh build-image` | Build `openclaw-agent:local` |
| `./identyclaw.sh start all` | Start every agent in `AGENT_IDS` |
| `./identyclaw.sh stop all` / `restart all` | Stop / restart |
| `./identyclaw.sh status` / `logs <id>` | Health and logs |
| `./identyclaw.sh chat <id>` / `ask <id> "…"` | Terminal chat |
| `./identyclaw.sh token <id>` | Control UI gateway token |
| `./identyclaw.sh near-activate <id> [account]` | Activate Passport creds |
| `./identyclaw.sh enable-boot` | Survive reboot (linger + restart policy) |
| `./identyclaw.sh test [id]` | Unit tests + preflight + constitution |

Full command table, A2A/webhook auth boundaries, agent examples, CI/CD ingress,
and troubleshooting: [`OPERATOR.md`](./OPERATOR.md).
