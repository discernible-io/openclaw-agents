# Identyclaw OpenClaw (Podman)

Deploy isolated [OpenClaw](https://docs.openclaw.ai) AI agent gateways with Podman — email (Himalaya), IdentyClaw identity tools, and agent-to-agent (A2A) messaging.

## Overview

This repository is an **operations toolkit** for running OpenClaw agents on **main** or **development** tiers. Each agent gets its own Podman container, config directory, workspace, and secrets. The repo itself is **code-only** (safe to clone publicly); runtime state lives in a sibling app directory.

**Typical use cases:**

- **Email-capable agents** — customer support or triage via Migadu/IMAP (Himalaya skill)
- **IdentyClaw integrations** — HOLA/Passport verification, A2A peer messaging, RODiT-signed webhooks
- **Multi-agent deployments** — one or more agents per host, with optional cross-host A2A
- **Main-tier ingress** — nginx TLS sidecar, GitHub Actions deploy, health checks

**You choose how many agents run on each host** via `AGENT_IDS` in `env.local` (see [Choosing agents on this host](#choosing-agents-on-this-host)). The defaults in `env.example` illustrate a three-agent layout (`agent-a`, `agent-c`, `agent-e`); trim or extend that list to match your deployment.

## Related guides

| Guide | Use when |
| --- | --- |
| [IdentyClaw overview (discernible.io)](https://www.discernible.io/#get-started) | Official Get Started: NEAR account → Passport mint |
| [Developers / deploy template](https://www.discernible.io/developers.html) | Clone this repo, plugins, SDKs |
| [Agent hive (A2A + email)](https://dev.to/discernible-io/build-an-openclaw-agent-hive-with-identyclaw-a2a-email-out-of-the-box-125b) | Narrative walkthrough of this repo |
| [OpenClaw + Passport onboarding](https://dev.to/discernible-io/onboard-openclaw-agents-with-identyclaw-passport-a2a-webhooks-and-multi-tenant-collaboration-3i4k) | Mint, plugins, collaboration envelopes |
| [Verify before execute](https://dev.to/discernible-io/verify-before-execute-hola-recipes-for-agent-verifiers-4a0d) | HOLA / task trust on inbound work |
| [Passport vs static secrets](https://dev.to/discernible-io/identyclaw-passport-vs-static-secrets-when-cryptographic-agent-identity-beats-api-keys-pm0) | Decide whether to mint |
| [Passport threat model](https://dev.to/discernible-io/passport-threat-model-triangle-of-trust-threats-and-how-the-architecture-counters-them-3mo6) | Triangle of Trust / threat → control |

## Features & capabilities

| Area | What this repo provides |
| --- | --- |
| **Runtime** | Isolated OpenClaw gateways in Podman (rootless by default); standalone loopback dev or nginx TLS **pod** ingress (main / development tiers) |
| **Image** | Local `openclaw-agent:local` (`Containerfile.agent`) from GHCR OpenClaw **2026.7.1-slim**, Himalaya **v1.2.0**, [near-cli-rs](https://github.com/near/near-cli-rs) **v0.29.0**, Chromium for browser skills, Discord plugin pinned to the gateway version |
| **Email** | Migadu IMAP/SMTP via **himalaya** skill; inbox list/read/delete helpers; reciprocal email HOLA; optional LLM **inbox heartbeat** (concierge replies) |
| **Identity** | **identyclaw** skill + **identyclaw-tools** plugin — HOLA verify/create, Passport lookup, DID, federated API sessions, generic `identyclaw_request` |
| **A2A** | **identyclaw-a2a** @0.4.10 — Agent Card discovery, P2P JWT auth, messaging, files, tasks, artifacts |
| **Webhooks** | **identyclaw-webhooks** @0.1.9 — RODiT-signed `POST /hooks/*` ingress + outbound `send_rodit_webhook` |
| **Peer discovery** | Passport `token_id` → gateway URL via API `GET /full` `metadata.webhook_url` (on-chain fallback); optional `GET /api/agents` seeding (`IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1` or `./identyclaw.sh discover-a2a-peers`) |
| **Channels** | Discord (bundled); optional Telegram, Instagram, X/Twitter (bird-twitter), LinkedIn (ClawLink + linkedin-social) via ClawHub |
| **LLM** | **OpenRouter** (default) or **OpenCode** Zen/Go; model chain + failover timeouts synced from `env.local`; OpenRouter sticky `session_id` + prompt-cache stats (`cache-stats`) |
| **Memory** | QMD BM25 + session-memory hook; memory-core dreaming (nightly → `MEMORY.md`); Active Memory left off by default |
| **Security** | Gateway token auth, rate limiting, tool/knowledge scope in workspace docs, RODiT JWT boundaries for A2A vs webhooks vs Control UI |
| **Testing** | Repo-local unit tests (CI); constitution gateway suites with per-agent **preflight**; multi-agent and multi-peer sweeps |
| **Ops** | Boot persistence (`enable-boot`), GitHub Actions deploy, self-signed TLS generation, agent export/import, `restore-host-access` for credential edits |

## Federated APIs

Set `IDENTYCLAW_API_ENDPOINTS` (comma-separated) so the IdentyClaw plugin knows federated peers such as `https://slc.discernible.io:8443`. Native vs federated login is the same Rodit challenge — only the login URL changes (`identyclaw_ensure_session({ apiEndpoint })`).

**How OpenClaw agents play SLC**

1. Fetch the live playbook: `GET /api/game/skill.md` on `:8443` (via `identyclaw_request` with `auth: false`, `responseType: "text"`).
2. Open a federated session: `identyclaw_ensure_session({ apiEndpoint: "https://slc.discernible.io:8443" })`.
3. Call game routes with generic `identyclaw_request({ method, path, apiEndpoint })` using paths from that skill (lobbies, tasks, join, message, action/tick with an explicit action body, …).

The IdentyClaw plugin stays **generic** (home API + federated login + `identyclaw_request`). Product routes live in the peer skill, not as plugin-specific tools.

**Important:** federation shares **Rodit login only**. Do not expect home IdentyClaw routes (`/api/me/identity`, HOLA, DID, …) on a federated peer. After `ensure_session`, discover that peer’s surface and call its paths via `identyclaw_request`. Keep Passport/HOLA tools on `api.identyclaw.com` (omit `apiEndpoint`).

### OpenClaw limitation: remote MCP and federated JWT

OpenClaw’s `mcp.servers.*.headers` are **static** at connect time. They do **not** call into the IdentyClaw plugin’s per-URL JWT cache. So wiring `mcp.servers.slc` → `https://slc.discernible.io:8443/mcp` leaves game tools unauthenticated (`AUTH_REQUIRED`) even after a successful `ensure_session`.

This fleet therefore **does not wire** remote SLC MCP for agents. SLC’s `/mcp` game tools remain **authenticated** on the server (correct for any client that can attach a Bearer). Re-enable remote MCP for OpenClaw only after:

- an OpenClaw hook that injects dynamic auth from the plugin session, or  
- a local stdio MCP proxy that uses RoditClient / the same federated session.

Until then, use **skill paths + `identyclaw_request`**, and for required SLC submits use **`identyclaw_game_tick`** (or `POST .../tick` / `.../action`) **with an explicit action body** from state (plugin ≥ 1.8.3). Empty tick bodies return `action_required` — they are not a silent `none`. Require live skill ≥ **1.8.6**.

Optional SLC heartbeat: `IDENTYCLAW_ENABLE_SLC_HEARTBEAT=1` or `./identyclaw.sh enable-slc-heartbeat <agent-id> [interval]` (writes a real `slc-game` HEARTBEAT task, removes stale local `SLC.md` / cached skills, installs a RAG copy of the unattended operator prompt). Playbook stays on `:8443` only. Unattended loops **must never create lobbies** — resume via `games/mine` or join a peer lobby; idle with `HEARTBEAT_OK` when nothing is active (solo create burns ~400k tokens/tick).

**Ask to play unattended:** paste [`scripts/templates/knowledge/slc-play-unattended.md`](scripts/templates/knowledge/slc-play-unattended.md) — operator arming prompt that points at the live skill (not a local playbook).

## Standards

This repo follows shared RODiT standards vendored at [`../docs/docs/`](../docs/docs/). Key references:

| Topic | Document |
| --- | --- |
| Deployment tiers (`main` / `development`) | [`vocabulary-standard.md`](../docs/docs/vocabulary-standard.md) |
| Integration test outcomes (`passed` / `not-passed`) | [`test-constitution.md`](../docs/docs/test-constitution.md) |
| CI/CD and Podman deploy | [`cicd-deployment-standard.md`](../docs/docs/cicd-deployment-standard.md) |
| API→chain peer URL fallback (logged) | [`allowed-fallback-standard.md`](../docs/docs/allowed-fallback-standard.md) |

## Prerequisites

| Requirement | Notes |
| --- | --- |
| **Podman** (rootless recommended) | AlmaLinux / RHEL / Fedora: `sudo dnf install -y podman` |
| **Node.js 22+** (host) | Used by test/probe scripts; CI runs `node scripts/test-unit-all.mjs` |
| **Sibling app directory** | Default `../openclaw-agents-app` — created by `./identyclaw.sh init` |
| **Migadu mailboxes** | One per agent you enable in `AGENT_IDS`; set `AGENT_*_EMAIL` in `env.local` |
| **OpenRouter or OpenCode key** | Before onboard/chat: `./identyclaw.sh set-api-key` or `set-opencode-key` |
| **NEAR Passport credentials** | Required for A2A, webhooks, and HOLA — see [IdentyClaw Passport enrollment](#identyclaw-passport-enrollment) (`secrets/near-credentials/*.json`, `.active`; wallet helpers: `workspace/scripts/idcp-*.sh`) |
| **Optional host CLI** | `openclaw` on the host for advanced management outside containers |

Mailbox passwords are **not** required for `init`, `build-image`, or `start` — add them later (see [Set email passwords later](#set-email-passwords-later)).

For main-tier **pod** deploy, also prepare TLS material under `~/openclaw-agents-app/certs/` (`./identyclaw.sh generate-certs`) and set `IDENTYCLAW_DEPLOY_MODE=pod` with per-agent `AGENT_*_PUBLIC_HOST`.

## IdentyClaw Passport enrollment

A2A messaging, RODiT-signed webhooks, and HOLA identity tools need a minted [IdentyClaw Passport](https://www.discernible.io/#get-started) on NEAR. You do **not** register with IdentyClaw to exist — you create a NEAR account, fund it, and mint at the purchase portal. Canonical overview: [discernible.io Get Started](https://www.discernible.io/#get-started) · [Developers](https://www.discernible.io/developers.html) · enrollment API: [`.well-known/enrollment`](https://api.identyclaw.com/.well-known/enrollment).

Do this **once per agent** (or share one Passport only inside a closed trust boundary — see [Passport vs static secrets](https://dev.to/discernible-io/identyclaw-passport-vs-static-secrets-when-cryptographic-agent-identity-beats-api-keys-pm0)).

### 1. Install this repo and bring an agent up

```bash
git clone https://github.com/discernible-io/openclaw-agents.git ~/identyclaw-agents
cd ~/identyclaw-agents
chmod +x identyclaw.sh
./identyclaw.sh init          # creates ../openclaw-agents-app/ and env.local
# Edit ../openclaw-agents-app/env.local — set AGENT_IDS (e.g. agent-a), emails, ports
./identyclaw.sh build-image
./identyclaw.sh start all
```

Install Podman and Node 22+ first (see [Prerequisites](#prerequisites)). LLM keys and Migadu passwords can wait until after Passport enrollment if you only need identity/A2A smoke tests.

### 2. Create a NEAR implicit account

Create credentials **before** purchasing a Passport. Keys stay on disk under the agent’s app state — **never paste private keys into chat**.

**Option A — inside the running agent** (near-cli-rs is in the image; preferred once `start` has run):

```bash
podman exec -u node openclaw-agent-a \
  bash -lc 'cd /home/node/.openclaw/workspace && bash scripts/idcp-wallet.sh genaccount'
```

Copy the printed 64-character hex `implicit_account_id`. Activate it on the host:

```bash
./identyclaw.sh near-activate agent-a <implicit_account_id>
```

**Option B — host [gennearaccount](https://github.com/discernible-io/gennearaccount)** (same JSON layout; no container required):

```bash
mkdir -p ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
chmod 700 ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
gennearaccount ~/openclaw-agents-app/agents/agent-a/secrets/near-credentials
./identyclaw.sh near-activate agent-a <implicit_account_id>
```

Result: `~/openclaw-agents-app/agents/agent-a/secrets/near-credentials/<implicit_account_id>.json` (mode `0600`) plus `.active`.

### 3. Get NEAR (buy or swap with HOT Wallet)

Minting needs mainnet NEAR for the Passport fee and gas (personal tier starts around **0.066 NEAR** for 30 days; check live pricing on the portal). Two common paths:

**Buy NEAR on an exchange** (Binance, Coinbase, Kraken, OKX, …) and withdraw to a wallet you control. Confirm the exchange supports NEAR mainnet withdrawals.

**Or use [HOT Wallet](https://hot-labs.org/wallet/)** (browser extension / mobile — the wallet the [purchase portal](https://purchase.identyclaw.com) integrates for mint signing):

1. Install HOT Wallet from [hot-labs.org/wallet](https://hot-labs.org/wallet/).
2. Create or import a funded NEAR account in HOT.
3. If you hold other assets, use HOT’s **Swap / bridge** to convert them to **NEAR** on mainnet.
4. Keep enough NEAR in HOT to cover the Passport tier you will mint (plus a small buffer for gas).

The agent’s **implicit** account holds the Passport keys on the server. HOT Wallet is the human-side wallet that **pays and signs** the mint on [purchase.identyclaw.com](https://purchase.identyclaw.com). You will paste the agent’s 64-char hex id as the **NEAR account that receives the Passport** on the form.

Optional: send a little NEAR to the implicit account itself (e.g. via HOT transfer to the hex address, or `idcp-wallet.sh <funding> <implicit> init`) if you later need on-chain ops from that account; mint checkout can also cover first-time funding depending on portal flow.

### 4. Craft the Passport at purchase.identyclaw.com

Human checkout step ([Get Started](https://www.discernible.io/#get-started)):

1. Open **[https://purchase.identyclaw.com](https://purchase.identyclaw.com)**.
2. Click **Connect NEAR Wallet** and choose **HOT Wallet** (approve in the HOT popup / extension).
3. Fill the mint form:
   - **NEAR account that will receive the Passport** — the agent’s 64-char hex `implicit_account_id` from step 2 (implicit, not a named `*.near` account).
   - **Creature** — profession/role for discovery (e.g. `Customer Support Agent`).
   - **Name**, optional **Contact URI** (`email:example.com:you@example.com`), and facial traits as prompted.
   - Recommended: **Webhook URL** = this agent’s public HTTPS base with no path (e.g. `https://agent-a.identyclaw.com:9443` from `./identyclaw.sh webhook-url agent-a`).
4. Pick a tier (Personal / Enterprise / Collectible), review the NEAR fee, and **mint**.
5. Approve the transaction in HOT Wallet; wait for chain confirmation (~seconds).

FAQ: [purchase.identyclaw.com/faq](https://purchase.identyclaw.com/faq). Support: support@identyclaw.com.

### 5. Wire credentials into the gateway and verify

Credentials from step 2 should already be on disk. Restart so bootstrap syncs `IDENTYCLAW_*` / plugin config:

```bash
./identyclaw.sh near-activate agent-a <implicit_account_id>   # if not already active
./identyclaw.sh restart agent-a
```

Confirm Passport binding (via Control UI / `./identyclaw.sh chat agent-a`, or the `identyclaw_get_my_identity` tool). Then register or update Passport `metadata.webhook_url` if you skipped it at mint time.

Skip minting only when peers stay inside one closed trust boundary. Deeper walkthrough: [OpenClaw + Passport onboarding](https://dev.to/discernible-io/onboard-openclaw-agents-with-identyclaw-passport-a2a-webhooks-and-multi-tenant-collaboration-3i4k). Wallet helpers after enrollment: `workspace/scripts/idcp-*.sh` and the `idcp-wallet` skill.

## Repository vs app directory

This repository is **code-only** — safe to clone publicly. Runtime secrets, TLS material, and per-agent state never belong in the git checkout.

The **git checkout** holds scripts and image definitions only. **Config, TLS, and agent state** live in a sibling app directory (default `../openclaw-agents-app`):

| Path | Purpose |
|------|---------|
| `identyclaw-agents/` | Clone of this repo — run `./identyclaw.sh` from here |
| `../openclaw-agents-app/env.local` | Runtime settings (chmod 600; created by `./identyclaw.sh init`) |
| `../openclaw-agents-app/agents/<agent-id>/` | Per-agent state (`openclaw.json`, `secrets/near-credentials/`, workspace) |
| `../openclaw-agents-app/certs/` | TLS for main-tier pod (not used in standalone dev) |

Override the app root: `export IDENTYCLAW_APP_DIR=/custom/path` (default: `../openclaw-agents-app` next to the clone).

## Choosing agents on this host

How many gateways run on a machine is controlled in `~/openclaw-agents-app/env.local`:

| Variable | Purpose |
|----------|---------|
| `AGENT_IDS` | Space-separated list of agents **started on this host** (`start all`, `stop all`, `restart all`, `enable-boot`, pod deploy, test suites) |
| `A2A_PEER_AGENTS` | Collaboration partners as Passport **token_id** values (space-separated) — used for smoke tests and optional bootstrap seeding; **URLs are not configured here** |
| `IDENTYCLAW_PEER_TOKEN_ID` | Optional single peer `token_id` for `./identyclaw.sh test-a2a` when `A2A_PEER_AGENTS` lists multiple peers |

Peer gateway bases are resolved from IdentyClaw API **`GET /api/identity/token/{tokenId}/full`** → **`metadata.webhook_url`**, with on-chain NEAR `rodit_token` fallback, when `IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1` or `IDENTYCLAW_A2A_OPEN_P2P=1` is set. Optional static override: `A2A_PEER_URLS` JSON map (`token_id` → `https://peer-host:port`).

Default (if unset): `AGENT_IDS=agent-a agent-c agent-e`.

**Examples:**

```bash
# Single agent on this host (common for dev or one agent per VM)
AGENT_IDS=agent-a

# Two agents on one host
AGENT_IDS=agent-a agent-c

# Stock three-agent template
AGENT_IDS=agent-a agent-c agent-e

# Split across hosts — peers identified by Passport token_id; URLs from API
# Host 1 env.local:
#   AGENT_IDS=agent-a
#   IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1
#   A2A_PEER_AGENTS=<agent-c-token-id>
# Host 2 env.local:
#   AGENT_IDS=agent-c
#   IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1
#   A2A_PEER_AGENTS=<agent-a-token-id>
```

`./identyclaw.sh init` seeds state directories for **agent-a, agent-c, and agent-e** from `env.example`. Agents not listed in `AGENT_IDS` are simply not started — you can leave their mailbox passwords and API keys unset until you need them.

Per-agent settings in `env.local` use the `AGENT_<LETTER>_` prefix matching the id suffix (`agent-a` → `AGENT_A_EMAIL`, `AGENT_A_GATEWAY_PORT`, etc.). The stock template covers `a`, `c`, and `e`; add matching blocks if you introduce custom ids.

Set `AGENT_IDS` **before** the first `./identyclaw.sh start all` (or edit `env.local` right after `init`).

## Quick start (rootless — recommended)

Run as your normal user (not `root`):

```bash
cd ~/identyclaw-agents
chmod +x identyclaw.sh
./identyclaw.sh init          # creates ../openclaw-agents-app/ and env.local from env.example
# Edit ../openclaw-agents-app/env.local — set AGENT_IDS, emails, ports; passwords optional
./identyclaw.sh build-image
./identyclaw.sh start all     # starts every id in AGENT_IDS
./identyclaw.sh status
```

When Migadu passwords are ready, configure **each agent in `AGENT_IDS`**:

```bash
./identyclaw.sh set-password agent-a
# ./identyclaw.sh set-password agent-c   # if agent-c is in AGENT_IDS
./identyclaw.sh restart all
./identyclaw.sh test-mail agent-a
./identyclaw.sh set-api-key agent-a    # OpenRouter sk-or-... (validated)
./identyclaw.sh onboard agent-a        # skips hatch TUI / health checks by default
./identyclaw.sh restart agent-a
# repeat set-password / set-api-key / onboard for each agent in AGENT_IDS
```

**Recommended before first onboard:** rebuild the image once so `/openclaw.mjs`, OpenClaw **2026.7.1+**, and bundled plugins (Discord) are in the image:

```bash
./identyclaw.sh build-image
./identyclaw.sh restart all
```

The local image pins `ghcr.io/openclaw/openclaw:2026.7.1-slim` (see `env.example`) and pre-installs `@openclaw/discord@2026.7.1` at build time. On each container start, the entrypoint copies that plugin tree into the agent’s mounted `~/.openclaw/npm` if Discord is not already present — agents do not need to run `openclaw plugins install` or `npm i -g openclaw` at runtime.

- **Pod mode** (per agent): `https://<AGENT_*_PUBLIC_HOST>:<ingress-port>/` — token: `./identyclaw.sh token <agent-id>`
- **Standalone dev** (default ports from `env.local`): agent-a → `http://127.0.0.1:18789/`, agent-c → `http://127.0.0.1:18793/`, agent-e → `http://127.0.0.1:18797/`

See [Accessing agents (CLI and browser)](#accessing-agents-cli-and-browser) for terminal chat and remote laptop access.

## Accessing agents (CLI and browser)

By default gateways bind to **`127.0.0.1`** only (`PUBLISH_HOST=127.0.0.1` in `env.local`). That means they are reachable on the **server**, not directly from a remote laptop, unless you use an SSH tunnel or change the publish bind (below).

### Chat via CLI (no browser)

Interactive terminal chat on the **server** (SSH session as your normal user). No loopback HTTP from your laptop required. Use any agent id in `AGENT_IDS`:

**Interactive chat** (easiest):

```bash
cd ~/identyclaw-agents
./identyclaw.sh chat agent-a
# ./identyclaw.sh chat agent-c   # when agent-c is in AGENT_IDS
```

Exit with **Ctrl+C** or the TUI quit command.

**One-shot question:**

```bash
./identyclaw.sh ask agent-a "Summarize what you can help with for customer support."
./identyclaw.sh ask agent-c "Draft a short reply to a shipping delay inquiry."
```

**Gateway-backed TUI** (same session as Control UI — advanced):

```bash
cd ~/identyclaw-agents
podman exec -it openclaw-agent-a node dist/index.js tui \
  --url ws://127.0.0.1:18789 \
  --token "$(./identyclaw.sh token agent-a)"
```

Use the matching `AGENT_*_GATEWAY_PORT` from `env.local` and `./identyclaw.sh token <agent-id>` for other agents.

**Health check** (not a chat UI — returns HTTP status only):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18789/
# 200 = gateway responding
```

### Control UI from the server (local browser)

On the machine running Podman:

```bash
cd ~/identyclaw-agents
./identyclaw.sh token agent-a
# open http://127.0.0.1:18789/ and paste the token (or use #token=... in the URL hash)
```

### Remote browser — SSH tunnel (recommended)

No need to expose OpenClaw ports on the public internet. On your **laptop**, forward each `AGENT_*_GATEWAY_PORT` from `env.local` (defaults: 18789, 18793, 18797):

```bash
ssh -L 18789:127.0.0.1:18789 -L 18793:127.0.0.1:18793 user@YOUR_SERVER_IP
```

Keep that SSH session open. In the laptop browser (one row per agent you tunnel):

| Agent | URL (example) |
|-------|----------------|
| agent-a | `http://127.0.0.1:18789/#token=TOKEN` |
| agent-c | `http://127.0.0.1:18793/#token=TOKEN` |
| agent-e | `http://127.0.0.1:18797/#token=TOKEN` |

Get tokens on the server: `./identyclaw.sh token <agent-id>` (e.g. `agent-a`).

Or chat over SSH without a browser:

```bash
ssh user@YOUR_SERVER_IP
cd ~/identyclaw-agents
./identyclaw.sh chat agent-a
```

### Remote browser — public IP (optional)

Only if you intentionally want the Control UI on the internet. Prefer HTTPS via a reverse proxy on main; raw HTTP + token is risky.

**1. Publish on all interfaces** — in `env.local`:

```bash
PUBLISH_HOST=0.0.0.0
```

**2. Allow your origin** — in `~/openclaw-agents-app/agents/agent-a/openclaw.json` (and agent C on 18793):

```json
"controlUi": {
  "allowedOrigins": [
    "http://127.0.0.1:18789",
    "http://localhost:18789",
    "http://YOUR_SERVER_IP:18789"
  ]
},
"bind": "lan"
```

Replace `YOUR_SERVER_IP` with your server’s public IP or hostname.

**3. Firewall** (example — allow agent ports + SSH only):

```bash
sudo firewall-cmd --permanent --add-port=18789/tcp
sudo firewall-cmd --permanent --add-port=18793/tcp
sudo firewall-cmd --reload
```

**4. Restart and verify:**

```bash
cd ~/identyclaw-agents
./identyclaw.sh restart all
ss -tlnp | grep -E '18789|18793'   # expect 0.0.0.0:...
```

**5. Laptop browser:**

```text
http://YOUR_SERVER_IP:18789/#token=TOKEN
```

Get `TOKEN` on the server with `./identyclaw.sh token agent-a`.

## Set email passwords later

You can bring agents up before mail is configured. Himalaya reads credentials from each agent’s `secrets/` directory (not from `env.local` at runtime).

**Option A — interactive (recommended)**

```bash
./identyclaw.sh set-password agent-a
# ./identyclaw.sh set-password agent-c   # repeat for each agent in AGENT_IDS
./identyclaw.sh restart all
./identyclaw.sh test-mail agent-a
```

**Option B — one-time in `env.local`**

Set `AGENT_A_PASSWORD`, `AGENT_C_PASSWORD`, and `AGENT_E_PASSWORD` in `env.local`, then re-run init (only writes secrets if the password fields are non-empty):

```bash
# edit env.local, then:
./identyclaw.sh init
./identyclaw.sh restart all
```

**Changing a mailbox password** (e.g. after a Migadu reset): run `set-password` again for that agent and `restart`.

**Verify mail works**

```bash
./identyclaw.sh test-mail agent-a
```

Success lists INBOX envelopes. `Authentication failed` means the Migadu password in `secrets/imap.pass` is wrong — fix with `set-password`, not by editing the pass file by hand.

### Reciprocal email HOLA (peers test us, we test peers)

Email verification is symmetric: just as `test-mail-hola` sends a HOLA probe to a peer and expects a signed reply, peers send probes to us and expect ours. Two pieces make this work:

- **Responder** (`respond-mail`): a deterministic script that polls INBOX for `IDENTYCLAW_HOLA_PROBE:{id}:{variant}` messages, verifies each inbound HOLA via the IdentyClaw API, and replies `HOLA_RESPONSE:{id}:{variant}` — with a signed HOLA only when the probe verifies (a tampered probe gets a no-credential rejection). Schedule it with `./identyclaw.sh enable-mail-responder` so inbound probes don't time out.
- **Bidirectional test** (`test-mail-hola`): the **outbound** direction probes the peer and polls for its reply; the **inbound** direction P2P-logs into the peer and (via A2A `message/send`) asks it to email *us* a probe, then exercises our own responder to confirm we receive, verify, and reply. Both directions are best-effort (reported as skips) unless `REQUIRE_MAIL_HOLA=1`, which turns missing replies into failures.

```bash
./identyclaw.sh enable-mail-responder          # keep our inbox answered on a timer
REQUIRE_MAIL_HOLA=1 ./identyclaw.sh test-mail-hola agent-a <peer-token-id>
```

### Inbox heartbeat (concierge)

Optional LLM-driven inbox polling replies to inbound mail on a schedule (workspace `AGENTS.md` defines concierge scope and trust tiers):

```bash
./identyclaw.sh enable-inbox-check agent-a 1h
./identyclaw.sh restart agent-a
```

Or set `IDENTYCLAW_ENABLE_INBOX_HEARTBEAT=1` and `IDENTYCLAW_INBOX_HEARTBEAT_INTERVAL=1h` in `env.local` before bootstrap/restart.

## Rootful (optional, not recommended)

Only if you intentionally run Podman as root:

```bash
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh build-image
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh init
# Set passwords and start as root; state under /root/openclaw-agents-app/agents/
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh start all
```

Rootless is safer: config stays in your home directory with your UID.

## Run in background and survive reboot

Agents listed in `AGENT_IDS` run as **detached Podman containers** (`podman run -d`). They keep running when you close SSH, and can start again after a **machine reboot** once boot persistence is enabled.

Identyclaw does **not** use OpenClaw’s host systemd daemon. Onboarding warnings about *“Systemd unavailable”* or *“Gateway not detected”* are normal — ignore them.

### How it works

| Layer | What it does |
|-------|----------------|
| `podman run -d` | Agents run in the background |
| `--restart always` | Podman restarts a container if it crashes |
| `loginctl enable-linger` | User systemd keeps running after logout |
| `podman-restart.service` | On boot, starts containers with `--restart always` |

**Note:** AlmaLinux’s `podman-restart.service` only picks up **`always`**, not `unless-stopped`. `identyclaw.sh start` uses **`always`** for this reason.

### One-time setup (run once)

```bash
cd ~/identyclaw-agents
./identyclaw.sh enable-boot
```

This will ask for **sudo** once if linger is not already enabled (`loginctl enable-linger`). It then:

1. Enables linger for your user  
2. Enables `podman-restart.service` (user systemd)  
3. Recreates every agent in `AGENT_IDS` with `--restart always`  

**Manual equivalent:**

```bash
sudo loginctl enable-linger "$(whoami)"
systemctl --user enable --now podman-restart.service
cd ~/identyclaw-agents
./identyclaw.sh restart all
```

### Verify

```bash
loginctl show-user "$(whoami)" | grep Linger          # Linger=yes
systemctl --user is-enabled podman-restart.service    # enabled
# Inspect each running agent container (adjust ids to match AGENT_IDS):
podman inspect openclaw-agent-a \
  --format '{{.Name}} policy={{.HostConfig.RestartPolicy.Name}} state={{.State.Status}}'
# policy=always  state=running
./identyclaw.sh status
```

### After a machine reboot

Wait ~30 seconds for user systemd and Podman, then:

```bash
./identyclaw.sh status
# Health-check each agent in AGENT_IDS (ports from env.local):
curl -s -o /dev/null -w 'agent-a: %{http_code}\n' http://127.0.0.1:18789/
```

Containers for agents in `AGENT_IDS` should show **Up** without running `./identyclaw.sh start`.

### Day-to-day commands

```bash
./identyclaw.sh status      # are they running?
./identyclaw.sh logs agent-a
./identyclaw.sh restart all # after config changes
./identyclaw.sh stop all    # stop until next reboot (podman-restart starts them again on boot)
```

### Optional: Quadlet units

On main-tier hosts, you can replace manual starts with Podman Quadlet units under `~/.config/containers/systemd/` (see [OpenClaw Podman docs](https://docs.openclaw.ai/install/podman)).

### Cleanup stray onboard containers

If onboarding was interrupted, remove one-off containers (they are not restarted on boot):

```bash
podman rm -f openclaw-agent-a-onboard openclaw-agent-c-onboard 2>/dev/null || true
```

## Configuration

Each agent has isolated state under `~/openclaw-agents-app/agents/<agent-id>/`. Host ports and `AGENT_IDS` come from `~/openclaw-agents-app/env.local`; OpenClaw settings live in each agent’s `openclaw.json`.

**Never commit or paste gateway tokens or API keys.** Use `./identyclaw.sh token agent-a` when you need the Control UI token.

### IdentyClaw identity + A2A peer messaging

Each agent uses **three** published integrations (installed on `./identyclaw.sh start` / restart):

| Integration | Source | Purpose |
|-------------|--------|---------|
| **identyclaw** skill + `identyclaw-tools` plugin | [ClawHub: identyclaw/identyclaw](https://clawhub.ai/identyclaw/identyclaw) | HOLA verify/create, Passport lookup, DID, API workflows |
| **identyclaw-a2a** plugin | [ClawHub: @identyclaw/openclaw-a2a-plugin](https://clawhub.ai/plugins/@identyclaw/openclaw-a2a-plugin) | Agent-to-agent messaging (`a2a_send_message`, tasks, files) with RODiT JWT auth |
| **identyclaw-webhooks** plugin | [ClawHub: @identyclaw/openclaw-identyclaw-webhooks-plugin](https://clawhub.ai/plugins/@identyclaw/openclaw-identyclaw-webhooks-plugin) | RODiT-signed inbound webhooks + outbound `send_rodit_webhook` to configured peers |

Bootstrap writes `workspace/IDENTYCLAW.md` with operator guidance. Passport credentials go in `secrets/near-credentials/*.json` per agent (synced to `IDENTYCLAW_*` env vars). The active signing account is recorded in `secrets/near-credentials/.active`.

**Enrollment (Passport per agent):** follow [IdentyClaw Passport enrollment](#identyclaw-passport-enrollment) — install this repo, create a NEAR implicit account, fund/swap NEAR via [HOT Wallet](https://hot-labs.org/wallet/) (or an exchange), mint at [purchase.identyclaw.com](https://purchase.identyclaw.com), then `near-activate` / restart and confirm with `identyclaw_get_my_identity`. Official steps: [discernible.io Get Started](https://www.discernible.io/#get-started). Longer narrative: [OpenClaw + Passport onboarding](https://dev.to/discernible-io/onboard-openclaw-agents-with-identyclaw-passport-a2a-webhooks-and-multi-tenant-collaboration-3i4k). Skip minting only when peers stay inside one closed trust boundary — see [Passport vs static secrets](https://dev.to/discernible-io/identyclaw-passport-vs-static-secrets-when-cryptographic-agent-identity-beats-api-keys-pm0).

**NEAR wallet / Passport rotation:** after `build-image` (near-cli-rs) and bootstrap, agents get `workspace/scripts/idcp-wallet.sh`, `idcp-rotate-passport.sh`, and `idcp-activate-account.sh` plus the `idcp-wallet` skill. Rotate transfers the Passport on-chain and re-points `.active` / `.env` / plugin config; the agent then asks for `./identyclaw.sh restart <id>` (or operators run `./identyclaw.sh near-activate <id>`). Prefer new implicit accounts; do not reuse retired wallets.

**A2A peer discovery:** list partner Passport **token_id** values in `A2A_PEER_AGENTS` (optional seed list). API roster seeding is **off by default** (`IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=0` in `env.example` — slow at deploy). Set it to `1`, or run `./identyclaw.sh discover-a2a-peers all`, so agents call **`GET /api/agents`**, resolve each peer’s gateway via **`/full`** `metadata.webhook_url` (on-chain fallback), probe **`/.well-known/agent-card.json`** for liveness, and seed `openclaw.json` `outbound.agents`.

Enable API-based peer URL resolution (pick one in `env.local`):

```bash
IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1   # dynamic outbound + inbound JWT learning
# IDENTYCLAW_A2A_OPEN_P2P=1             # same + promiscuous inbound P2P login
```

Pin and install plugins (defaults in `env.example`):

```bash
IDENTYCLAW_CLAWHUB_A2A_PLUGIN=clawhub:@identyclaw/openclaw-a2a-plugin@0.4.10
IDENTYCLAW_CLAWHUB_PLUGIN=git:github.com/discernible-io/openclaw-identyclaw-plugin@main
IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN=clawhub:@identyclaw/openclaw-identyclaw-webhooks-plugin@0.1.9
```

Each agent's own public base can come from Passport `metadata.webhook_url` when `IDENTYCLAW_RODIT_SELF_CONFIGURE=1` (default).

```bash
# After near-credentials + A2A_PEER_AGENTS token_ids + dynamic flag:
./identyclaw.sh upgrade-plugins all   # ensure a2a 0.4.10+ (agent-card skills + task history via tasks/get historyLength)
./identyclaw.sh restart all
./identyclaw.sh test-a2a              # resolves peer URL via API; token_id from A2A_PEER_AGENTS
./identyclaw.sh test                  # full suite (see ../docs/docs/test-constitution.md)
# Optional: backfill discovered URLs into env.local for ops visibility
./identyclaw.sh sync-a2a-peers all
```

RODiT JWT details, main-tier ingress, and cross-machine A2A (Option A — public HTTPS on **9443**) are documented in local operator docs (`security-compliance-improvements.md`, not in this repo).

#### Where the contract is defined

Unlike the IdentyClaw API (authoritative OpenAPI in `api-docs/swagger.json` / [`clienttest-idc`](../clienttest-idc) `target-swagger.json`), agent-to-agent collaboration has **layered** contracts:

| Layer | Source | What it specifies |
|-------|--------|-------------------|
| Wire protocol | [A2A Protocol Specification](https://a2a-protocol.org/latest/specification/) | JSON-RPC on `POST /a2a`, Agent Card at `GET /.well-known/agent-card.json`, tasks/messages/artifacts |
| Implementation | `identyclaw-a2a` plugin (`openclaw.plugin.json`, `a2afork.md`) | RODiT JWT auth, P2P `/api/login`, outbound peer map, plugin tools |
| Webhooks | `identyclaw-webhooks` plugin | Signed `POST /hooks/*`, outbound `send_rodit_webhook` |
| Deployment | [`../docs/docs/test-constitution.md`](../docs/docs/test-constitution.md) | Expected behavior on this host (401 without auth, signed webhook rejection, receipts, etc.) |
| Runtime | `~/openclaw-agents-app/agents/<id>/openclaw.json` | Per-agent inbound/outbound auth modes, peer URLs, audiences |

Deployed Agent Cards advertise **`protocolVersion: "0.3.0"`** (OpenClaw A2A plugin binding). Validate deployments with `./identyclaw.sh test` — not against IdentyClaw API swagger.

#### Two channels — different jobs

Peer collaboration uses **two HTTP surfaces**. They are complementary, not interchangeable.

| Channel | Endpoint(s) | Purpose |
|---------|-------------|---------|
| **A2A** | `GET /.well-known/agent-card.json`, `POST /a2a` | Structured **messaging, files, tasks, artifacts** between agents |
| **Webhooks** | `POST /hooks/wake`, `/hooks/agent`, custom `/hooks/<name>` | Signed **wake / event ping** — nudge a peer gateway, record an event |

**Guidance:** prefer **A2A** for ongoing work with known peers (`a2a_send_message`). Use **`send_rodit_webhook`** to wake a peer via RODiT-signed webhook (not A2A). Use **HOLA / IdentyClaw API tools** (`identyclaw_*`) for identity verification of unknown senders — that is a separate surface from A2A wire protocol. For delegated task payloads, [verify before execute](https://dev.to/discernible-io/verify-before-execute-hola-recipes-for-agent-verifiers-4a0d).

#### A2A — permitted and forbidden

**HTTP surfaces**

| Request | Auth | Allowed? |
|---------|------|----------|
| `GET /.well-known/agent-card.json` | None (public discovery) | Yes |
| `GET /api/login/timestamp`, `POST /api/login` | Passport sign (P2P) | Yes — bootstrap enables `roditLogin` when inbound auth is RODiT |
| `POST /a2a` | `Authorization: Bearer <RODiT JWT>` | Yes — JSON-RPC A2A operations |
| `POST /a2a` without Bearer | — | **No** → HTTP **401** (`allowUnauthenticated` is never enabled by bootstrap) |
| `POST /a2a` to arbitrary hosts | — | **No** — only configured peers in `outbound.agents` |

**Tools** (local LLM → remote peer via `identyclaw-a2a`):

| Tool | Action |
|------|--------|
| `a2a_get_agents` | List configured outbound peers (keys are Passport `token_id`) |
| `a2a_get_agent` | Read a peer's skills/capabilities from its Agent Card |
| `a2a_send_message` | Send **text and files**; returns `context_id` / `task_id` |
| `a2a_get_task` | Poll long-running peer tasks |
| `a2a_view_text_artifact` / `a2a_view_data_artifact` | Fetch minimized large responses |
| `a2a_update_agent_card` | Update **this** agent's public Agent Card metadata |

A2A is **not text-only**: the plugin supports messages, file attachments (plugin docs: ~**1 MB** outbound), long-running tasks, streaming (Agent Card: `streaming: true`), and artifacts. Inbound JSON-RPC body limit: **1 MB**.

**Outbound limits:** outbound peers are keyed by Passport **token_id**. Bootstrap and `./identyclaw.sh test-a2a` resolve each peer’s gateway from API **`/full`** **`metadata.webhook_url`** (on-chain fallback; same field as webhooks and P2P JWT `rodit_webhookurl`). Inbound P2P can also register peers dynamically. Static `A2A_PEER_URLS` overrides lookup when set. Outbound auth is **P2P-only**: per-peer JWT from `{loginBaseUrl}/api/login`.

**Inbound limits:** JWT validated per `inbound.auth` (`issuer`, `audience` = own passport `owner_id`). Sender identity from JWT `token_id` (`identityClaim`); conversations keyed by sender + `context_id`.

**Forbidden via A2A**

| Action | Why |
|--------|-----|
| Remote execution of arbitrary OpenClaw tools on a peer | Only A2A JSON-RPC methods — opaque execution; no direct tool proxy |
| Gateway admin / Control UI access | Separate `OPENCLAW_GATEWAY_TOKEN` trust boundary |
| Messaging arbitrary hosts | Outbound resolves peers by Passport `token_id` only |
| Access to peer workspace, memory, or internal state | A2A delivers messages/tasks; each agent processes locally |

#### Webhooks — permitted and forbidden

**Inbound** (peers / integrators → your agent):

| Endpoint | Auth | Behavior |
|----------|------|----------|
| `POST /hooks/wake` | RODiT `x-signature` + `x-timestamp` | Validates signature → triggers **gateway heartbeat** (`mode: now` or `next-heartbeat`) |
| `POST /hooks/agent` | Same | Accepts payload → `{ ok: true, accepted: true }` (accept-only in current plugin) |
| Custom `/hooks/<name>` | Same | Configurable via `identyclaw-webhooks` `endpoints` |
| `GET/DELETE /hooks/_receipts` | None | Test helper for constitution runs |
| Unsigned or invalid signature | — | **No** → HTTP **400** or **401** |

**Outbound** (your agent → peer), via `send_rodit_webhook` tool:

| Permitted | Details |
|-----------|---------|
| Sign + POST to configured peer's `/hooks/wake` (default) | Peer base from `outbound.agents` |
| Path override | e.g. `hooks/agent` |
| Default delay | 10 seconds before send |

| Forbidden | Details |
|-----------|---------|
| Send to non-configured peer | Error: peer not in `outbound.agents` |
| Unsigned delivery | Must use `@rodit/rodit-auth-be` at origin |
| Arbitrary URLs | Only webhook paths on known peer bases |

**Webhook nuance:** `/hooks/wake` parses `text` / `event` from the body (validation + receipt logging) but the handler primarily calls **`requestGatewayHeartbeat(mode)`** — it does **not** inject that text into an A2A conversation. Webhooks are a **wake signal**, not a full message bus. Body limit: **256 KB**.

#### Auth boundaries (do not conflate credentials)

| Credential | Unlocks |
|------------|---------|
| **A2A inbound JWT** | `POST /a2a` only (P2P-issued, `aud` = receiver `owner_id`) |
| **Webhook RODiT signature** | `POST /hooks/*` only |
| **Gateway token** | Control UI / operator — **not** for peers |
| **IdentyClaw API JWT** (`login_server`) | `identyclaw_*` API tools (HOLA, identity) — **not** used for A2A wire auth |
| **P2P JWT** (peer `/api/login`) | Direct peer A2A |

Rotating one credential does not automatically revoke the others. See trust-boundary notes in local `security-compliance-improvements.md` (operator doc, not in this repo). Threat table behind these surfaces: [Passport threat model (Triangle of Trust)](https://dev.to/discernible-io/passport-threat-model-triangle-of-trust-threats-and-how-the-architecture-counters-them-3mo6).

**Wire auth ≠ task trust.** A valid A2A JWT or signed webhook proves who may speak on the channel. It does **not** prove which Passport delegated `task.payload`. On inbound work that carries a HOLA line or `identyclaw.collaboration.v1` envelope: verify HOLA first, match `peerTokenId` to `from.tokenId` / published canonical id, then execute — [verify before execute](https://dev.to/discernible-io/verify-before-execute-hola-recipes-for-agent-verifiers-4a0d).

#### Collaboration summary

| Action | A2A | Webhook |
|--------|-----|---------|
| Discover peer capabilities | Yes (public Agent Card) | No |
| Send conversational message | Yes (`a2a_send_message`) | No |
| Send files to peer | Yes (via A2A) | No |
| Poll tasks / fetch artifacts | Yes | No |
| Wake peer gateway | Indirectly (message triggers work) | Yes (`/hooks/wake`) |
| Deliver signed event string | Via message content | Yes (payload `event`/`text`; receipt logged) |
| Call peer without Passport JWT | No | No |
| Administer peer gateway | No | No |

**Typical flow:** (1) public Agent Card discovery → (2) optional HOLA trust via `identyclaw-tools` → (3) ongoing work via **`a2a_send_message`** (verify HOLA in collaboration envelopes before tools) → (4) optional **`send_rodit_webhook`** wake when a lightweight signed ping is enough.

**Verify:** `./identyclaw.sh test` — unit tests, **preflight**, then A2A smoke, RODiT auth, webhook ingress, P2P webhook receipts, mail (suites per [`../docs/docs/test-constitution.md`](../docs/docs/test-constitution.md)).

### Optional chat channels

Beyond email-first defaults, agents can enable:

| Channel | Setup | Notes |
| --- | --- | --- |
| **Discord** | `./identyclaw.sh set-discord-token agent-a` | Bundled in image; guild channel bootstrap on start |
| **Telegram** | Bot token in `openclaw.json` / onboard | DM approvers synced from NEAR `owner_id` on bootstrap |
| **X / Twitter** | `set-twitter` or `set-twitter-cookies` | bird-twitter skill (session cookies, not paid API) |
| **Instagram** | `./identyclaw.sh set-instagram agent-a` | Browser-based; reCAPTCHA may require manual login |
| **LinkedIn** | ClawLink plugin + linkedin-social skill | OAuth via ClawLink — no API keys in chat |

See `env.example` for ClawHub pin variables (`IDENTYCLAW_CLAWHUB_TWITTER_SKILL`, etc.).

### Agent A (example main-tier pod setup)

Reference configuration for a customer-support oriented agent with email + OpenRouter + DuckDuckGo. **Main-tier pod** uses `IDENTYCLAW_DEPLOY_MODE=pod` in `env.local`.

| Setting | Value |
|---------|--------|
| State dir | `~/openclaw-agents-app/agents/agent-a` |
| Container | `openclaw-agent-a` (in `identyclaw-agents-pod` with `identyclaw-nginx`) |
| Display name | Identyclaw Agent A (override via `AGENT_A_DISPLAY_NAME`) |
| Mailbox | `agent-a@identyclaw.com` (Migadu) |
| **Ingress port (public)** | **9443** — `https://agent-a.identyclaw.com:9443` |
| Gateway port (pod-internal) | **18789** (UI/API), **18790** (bridge) — nginx upstream only |
| Control UI | `https://agent-a.identyclaw.com:9443/` (or `curl -sk -H 'Host: agent-a.identyclaw.com' https://127.0.0.1:9443/` until DNS is live) |
| A2A | `POST https://agent-a.identyclaw.com:9443/a2a` |
| Token | `./identyclaw.sh token agent-a` |
| Deploy mode | `pod` (`IDENTYCLAW_INGRESS_PORT=9443` in `env.local`) |
| Gateway bind | `lan` (reachable from nginx sidecar inside the pod) |
| Gateway auth | token |
| Model | **Primary:** `openrouter/deepseek/deepseek-v4-flash` → **fallback 1:** `openrouter/qwen/qwen3-coder` → **fallback 2:** `openrouter/google/gemini-2.5-flash` (override via `OPENCLAW_MODEL_*` in `env.local`) |
| OpenRouter cache | Sticky `session_id` / `x-session-id` = `OPENCLAW_OPENROUTER_SESSION_ID` (default `identyclaw`); `diagnostics.cacheTrace` when `OPENCLAW_CACHE_TRACE=1`; inspect with `./identyclaw.sh cache-stats` |
| Web search | DuckDuckGo, region **`es-es`**, SafeSearch off |
| Email skill | **himalaya** enabled (password via `set-password`) |
| Memory | `qmd` (`@tobilu/qmd` in agent image; BM25 `searchMode`); dreaming on (`IDENTYCLAW_DREAMING_ENABLED`) |
| Session scope | `per-channel-peer` |
| Hooks | **session-memory** enabled |
| Chat channels | none (email-first; channels skipped at onboard) |
| Tools profile | `coding` |

Key `openclaw.json` excerpts (secrets redacted):

```json
{
  "gateway": {
    "port": 18789,
    "bind": "lan",
    "auth": { "mode": "token" }
  },
  "agents": {
    "defaults": {
      "models": {
        "openrouter/deepseek/deepseek-v4-flash": {
          "params": { "extra_body": { "session_id": "identyclaw" } }
        },
        "openrouter/qwen/qwen3-coder": {
          "params": { "extra_body": { "session_id": "identyclaw" } }
        },
        "openrouter/google/gemini-2.5-flash": {
          "params": { "extra_body": { "session_id": "identyclaw" } }
        }
      },
      "model": {
        "primary": "openrouter/deepseek/deepseek-v4-flash",
        "fallbacks": [
          "openrouter/qwen/qwen3-coder",
          "openrouter/google/gemini-2.5-flash"
        ]
      }
    }
  },
  "diagnostics": {
    "cacheTrace": {
      "enabled": true,
      "includeMessages": false,
      "includePrompt": false,
      "includeSystem": false
    }
  },
  "models": {
    "providers": {
      "openrouter": {
        "headers": { "x-session-id": "identyclaw" },
        "request": { "headers": { "x-session-id": "identyclaw" } }
      }
    }
  },
  "tools": {
    "web": {
      "search": { "provider": "duckduckgo", "enabled": true }
    }
  },
  "plugins": {
    "entries": {
      "openrouter": { "enabled": true },
      "duckduckgo": {
        "enabled": true,
        "config": {
          "webSearch": { "region": "es-es", "safeSearch": "off" }
        }
      }
    }
  },
  "skills": {
    "entries": { "himalaya": { "enabled": true } }
  },
  "hooks": {
    "internal": {
      "entries": { "session-memory": { "enabled": true } }
    }
  },
  "auth": {
    "profiles": {
      "openrouter:default": { "provider": "openrouter", "mode": "api_key" }
    }
  }
}
```

Webhooks use the same ingress hostname — no extra port. In pod mode: `POST https://agent-a.identyclaw.com:9443/hooks/wake` with **RODiT origin signature** (`x-signature` + `x-timestamp` via `@rodit/rodit-auth-be`) — same pattern as [`clienttest-idc`](../clienttest-idc). No `hooks.token` or HMAC. Standalone dev uses host port **18789**. See [Troubleshooting](#webhooks-and-port-conflicts-two-agents).

**Standalone dev** (other hosts or local loopback): `PUBLISH_HOST=127.0.0.1`, Control UI at `http://127.0.0.1:18789/`, `./identyclaw.sh start agent-a`.

**Fix OpenRouter auth** (if onboard saved a shell command instead of `sk-or-...`):

```bash
./identyclaw.sh set-api-key agent-a
./identyclaw.sh restart agent-a
```

### Agent C

Mirrors agent A’s setup (OpenRouter, DuckDuckGo `es-es`, himalaya, session-memory) on ports **18793/18794**.

| Setting | Value |
|---------|--------|
| State dir | `~/openclaw-agents-app/agents/agent-c` |
| Container | `openclaw-agent-c` |
| Mailbox | `agent-c@identyclaw.com` (Migadu) |
| Gateway ports (host) | **18793** (UI/API), **18794** (bridge) |
| Control UI | http://127.0.0.1:18793/ |
| Token | `./identyclaw.sh token agent-c` |

**Fast setup (copy from agent A — no interactive onboard):**

```bash
cd ~/identyclaw-agents
./identyclaw.sh mirror agent-c agent-a
./identyclaw.sh restart agent-c
./identyclaw.sh set-password agent-c   # when Migadu password is ready
./identyclaw.sh test-mail agent-c
```

**CLI chat:** `./identyclaw.sh chat agent-c`

### Agent E

Mirrors agent A’s setup on ports **18797/18798**.

| Setting | Value |
|---------|--------|
| State dir | `~/openclaw-agents-app/agents/agent-e` |
| Container | `openclaw-agent-e` |
| Mailbox | `agent-e@identyclaw.com` (Migadu — edit `env.local`) |
| Gateway ports (host) | **18797** (UI/API), **18798** (bridge) |
| Control UI | http://127.0.0.1:18797/ |
| Token | `./identyclaw.sh token agent-e` |

**Fast setup (copy from agent A):**

```bash
cd ~/identyclaw-agents
./identyclaw.sh init                    # creates agent-e dir if missing
./identyclaw.sh mirror agent-e agent-a
./identyclaw.sh restart agent-e
./identyclaw.sh set-password agent-e    # when Migadu password is ready
./identyclaw.sh test-mail agent-e
```

**CLI chat:** `./identyclaw.sh chat agent-e`

**Interactive onboard instead** (if you prefer the wizard over `mirror`):

```bash
./identyclaw.sh onboard agent-e
```

## Preflight

Gateway tests run **preflight** checks before constitution suites. Preflight prints `passed` / `not-passed` / `skipped` per check (outcomes follow [`../docs/docs/test-constitution.md`](../docs/docs/test-constitution.md)).

### Per-agent preflight (`./identyclaw.sh test [agent-id]`)

Emitted at the start of each agent’s constitution run:

| Check | Passed | Not-passed / skipped |
| --- | --- | --- |
| **webhook_url** | Passport `metadata.webhook_url` from API `GET /full` matches this host’s ingress base | Missing NEAR creds; API/chain URL missing; registered URL ≠ nginx/loopback base |
| **agent-card** | HTTP 200 at `{ingress}/.well-known/agent-card.json` | Gateway down, wrong bind, or pod not routing |
| **POST /a2a** | Unauthenticated request returns **401/403** (auth-gated) | Open `/a2a` or unreachable peer base |
| **webhooks plugin** | `identyclaw-webhooks` installed at the version pinned in `env.local` | No NEAR creds; plugin missing or stale — run `./identyclaw.sh upgrade-plugins` |

Requires `IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1` (or Open P2P) for live `webhook_url` resolution against the IdentyClaw API.

### Multi-agent preflight (`./identyclaw.sh test-all-agents`)

Before starting containers, verifies **Migadu mailbox passwords** exist for every id in `AGENT_IDS`. Then starts agents, syncs A2A outbound peers, prints the live peer roster, and runs unit tests + constitution per agent.

### Useful preflight commands

```bash
./identyclaw.sh test agent-a              # unit tests + preflight + local/peer constitution suites
./identyclaw.sh test-candidates           # remote peers per agent and test mode (a2a / a2a+email / email)
./identyclaw.sh test-unit                 # repo-local unit tests only (no Podman; CI-safe)
./identyclaw.sh discover-a2a-peers all    # refresh outbound.agents from GET /api/agents
./identyclaw.sh status                    # container state + ingress URLs
```

Skip slow or failing suites while debugging via `CONSTITUTION_SKIP_SUITES` in `env.local` (see `env.example`).

## Troubleshooting

### `build-image`: Himalaya download 404

If the build log shows a URL like `.../releases/download//himalaya..tgz`, build-args were not applied in the image `RUN` step. The repo’s `Containerfile.agent` re-declares `ARG HIMALAYA_VERSION` and `ARG HIMALAYA_ARCH` **after** `FROM` so the correct asset is fetched (e.g. `himalaya.x86_64-linux.tgz` for amd64). Pull the latest repo and run `./identyclaw.sh build-image` again.

### `start`: tries to pull `registry.access.redhat.com/openclaw-agent:local`

On AlmaLinux / RHEL / CentOS, Podman `short-name-mode = "enforcing"` resolves bare image names to Red Hat’s registry. Use the fully qualified local name in `env.local`:

```bash
OPENCLAW_LOCAL_IMAGE=localhost/openclaw-agent:local
```

Then rebuild and start. Confirm the image exists:

```bash
podman images localhost/openclaw-agent
```

### `build-image` failed but `start` ran anyway

`start` only works after a successful `build-image`. If the Himalaya layer failed, fix the build first — do not rely on a partial `<none>` intermediate image.

### `test-mail`: Authentication failed

- Wrong or placeholder password in `~/openclaw-agents-app/agents/agent-*/secrets/imap.pass`
- Mailbox not created in Migadu yet
- IMAP login must match `AGENT_*_EMAIL` in `env.local`

Fix: `./identyclaw.sh set-password agent-a` then `./identyclaw.sh restart all`.

### SMTP send: `535` or `cannot connect to smtp server using tls`

Migadu’s web UI lists **SMTP port 465 + TLS**. Himalaya in the OpenClaw image must use **`smtp.migadu.com:587`** with **`start-tls`** (see `scripts/lib.sh` → `write_himalaya_config`). Port 465 often hangs or fails auth even when IMAP on 993 works.

Also ensure:

- `message.send.backend.login` and `From:` match the mailbox (e.g. `agent-a@identyclaw.com`)
- Password is in `~/openclaw-agents-app/agents/agent-a/secrets/` via `./identyclaw.sh set-password agent-a` (do not paste passwords into `config.toml`)

**Pod deploy — IPv6 SMTP reset:** If IMAP works but SMTP fails with `Connection reset by peer`, glibc may be preferring broken IPv6 records for `smtp.migadu.com`. Pod deploy pins the hostname to Migadu mta1 IPv4 via `--add-host` (override with `MIGADU_SMTP_IPV4` in `env.local`). Recreate the pod after changing: `./scripts/deploy-local-podman.sh --skip-build`.

Quick check: `./identyclaw.sh test-mail agent-a` (IMAP) then send with `sh scripts/himalaya-send.sh …` inside the container.

### `onboard`: Address already in use (port 18789 / 18793)

The running gateway already binds that agent’s port. Onboarding is a **CLI-only** wizard and does not need its own port mapping (fixed in current `identyclaw.sh`). Pull the latest script, or stop the agent first:

```bash
./identyclaw.sh stop agent-a
./identyclaw.sh onboard agent-a
./identyclaw.sh start agent-a
```

With the fixed script you can run `onboard` while `start all` is up.

### `onboard`: Too many arguments

`agent-a` / `agent-c` is for **this script** (which config dir to mount), not for `openclaw onboard`. Do not run `openclaw onboard agent-a` manually. Use:

```bash
./identyclaw.sh onboard agent-a
```

Extra OpenClaw flags go after the agent id: `./identyclaw.sh onboard agent-a --flow quickstart`

### Onboarding: `/auth openrouter` → `Cannot find module '/openclaw.mjs'`

The hatch TUI spawns auth as `node /openclaw.mjs`, but the CLI lives at `/app/openclaw.mjs` in the container. This is **not** a network or API-key visibility issue.

**Quick fix (running containers):**

```bash
podman exec -u root openclaw-agent-a-onboard ln -sf /app/openclaw.mjs /openclaw.mjs
# retry /auth openrouter in the TUI
```

**Better fix — use configure on the gateway container** (exit the hatch TUI first with Ctrl+C):

```bash
podman exec -it openclaw-agent-a node dist/index.js configure --section model
```

Choose OpenRouter → **API key** → paste `sk-or-...` (not a shell command).

Rebuild the image to bake in the symlink (`Containerfile.agent`):

```bash
./identyclaw.sh build-image
./identyclaw.sh restart all
```

If auth still fails after a real key is saved, check `~/openclaw-agents-app/agents/agent-a/agents/main/agent/auth-profiles.json` — the `key` field must start with `sk-or-`, not a command like `cd ~/...`.

### Onboarding: systemd / gateway not detected

During `./identyclaw.sh onboard`, warnings about **systemd unavailable** or **Gateway ECONNREFUSED** are normal. Onboarding runs in a temporary container; the real gateway is the Podman container from `./identyclaw.sh start`. Do **not** install the OpenClaw systemd daemon on the host.

After onboarding:

```bash
./identyclaw.sh restart agent-a   # picks up config; applies --restart always
```

### Webhooks and port conflicts (two agents)

Each agent’s webhooks are HTTP paths on **that agent’s gateway** — they do not need separate ports. In **main-tier pod** mode, external senders use HTTPS on the agent subdomain (not host ports 18789/18793/18797).

| Mode | agent-a webhook wake (example) |
|------|--------------------------------|
| Standalone dev | `http://127.0.0.1:18789/hooks/wake` |
| Main-tier pod | `https://agent-a.identyclaw.com:9443/hooks/wake` |

Keep `AGENT_*_GATEWAY_PORT` unique in `env.local`. Webhook senders **sign at origin** with RODiT/Passport credentials (`x-signature` + `x-timestamp`) — not the Control UI gateway token. External services must call the correct subdomain. See [Main-tier ingress](#main-tier-ingress-cicd--nginx-tls-sidecar) and `./identyclaw.sh webhook-url agent-a`.

### Run as your normal user, not `root`

`init` / `start` / `onboard` expect rootless mode as your normal user. State lives under `~/openclaw-agents-app/agents/<agent-id>/` for each provisioned agent. Use root only for `dnf install podman` or optional rootful mode above.

## Commands

| Command | Description |
|---------|-------------|
| `./identyclaw.sh build-image` | Pull GHCR OpenClaw 2026.7.1+ + Himalaya + near-cli-rs + Discord plugin layer |
| `./identyclaw.sh near-activate <id> [account]` | Set active NEAR creds (`.active` + `.env` + plugin) then restart |
| `./identyclaw.sh init` | Create agent state dirs (`agent-a`, `agent-c`, `agent-e` from `env.example`) and `env.local` |
| `./identyclaw.sh set-password agent-a` | Store Migadu password locally |
| `./identyclaw.sh set-discord-token agent-a` | Store Discord bot token in `secrets/` (synced to `.env` on start) |
| `./identyclaw.sh set-instagram agent-a` | Store Instagram username/password in `secrets/` |
| `./identyclaw.sh set-twitter agent-a` | Store X/Twitter login; enables hourly DM polling via heartbeat |
| `./identyclaw.sh set-twitter-cookies agent-a` | Store X session cookies (`AUTH_TOKEN` + `CT0`) for bird-twitter skill |
| `./identyclaw.sh set-api-key agent-a` | Store OpenRouter API key (`sk-or-...`) with validation |
| `./identyclaw.sh set-opencode-key agent-a` | Store OpenCode Zen/Go API key (when `OPENCLAW_LLM_PROVIDER=opencode`) |
| `./identyclaw.sh mirror agent-c` | Copy config + LLM auth from another agent (e.g. agent-a → agent-c) |
| `./identyclaw.sh export-agent agent-a [file]` | Pack agent secrets + config for migration (`--with-browser` optional) |
| `./identyclaw.sh import-agent agent-a file` | Restore agent from `export-agent` archive |
| `./identyclaw.sh configure agent-a` | Run `openclaw configure` in the gateway container |
| `./identyclaw.sh start all` | Start every agent in `AGENT_IDS` |
| `./identyclaw.sh stop all` | Stop every agent in `AGENT_IDS` |
| `./identyclaw.sh restart all` | Restart after password or config changes |
| `./identyclaw.sh restore-host-access [id\|all]` | Stop pod agents and restore host ownership (edit creds/`.env` on host) |
| `./identyclaw.sh enable-boot` | One-time: background + start agents in `AGENT_IDS` after reboot |
| `./identyclaw.sh status` | Show podman + health URLs |
| `./identyclaw.sh cache-stats [id\|all]` | Prompt-cache hit rate / sticky OpenRouter `session_id` summary |
| `./identyclaw.sh logs agent-a` | Follow logs |
| `./identyclaw.sh test [id]` | Unit tests + **preflight** + full constitution suite (default: first `AGENT_IDS` entry) |
| `./identyclaw.sh test-unit` | Repo-local unit tests only (no Podman) |
| `./identyclaw.sh test-candidates` | List remote test peers per agent and mode |
| `./identyclaw.sh test-all-agents` | Start `AGENT_IDS`, sync peers, run constitution per local agent |
| `./identyclaw.sh test-all-agents-chat` | Constitution + chat-driven peer discovery per agent |
| `./identyclaw.sh test-all-peers` | Constitution suites against every live `A2A_PEER_AGENTS` peer |
| `./identyclaw.sh test-mail agent-a` | Verify IMAP via Himalaya |
| `./identyclaw.sh test-mail-hola [id] [peer-token-id]` | Reciprocal email HOLA; `REQUIRE_MAIL_HOLA=1` enforces replies |
| `./identyclaw.sh respond-mail [id\|all]` | Poll INBOX, verify inbound HOLA probes, reply (cron/timer entry point) |
| `./identyclaw.sh enable-mail-responder [interval]` | Install user systemd timer running `respond-mail` (default 5min) |
| `./identyclaw.sh enable-inbox-check agent-a [interval]` | Enable LLM inbox heartbeat / concierge (default 1h) |
| `./identyclaw.sh respond-a2a-webhook-smoke [id\|all]` | Handle inbound A2A webhook smoke probes (constitution helper) |
| `./identyclaw.sh enable-a2a-webhook-smoke-responder [interval]` | Timer for `respond-a2a-webhook-smoke` (default 1min) |
| `./identyclaw.sh respond-a2a-hola-smoke [id\|all]` | Send deterministic inbound A2A HOLA probe emails (smoke tests) |
| `./identyclaw.sh enable-a2a-hola-smoke-responder [interval]` | Timer for `respond-a2a-hola-smoke` (default 1min) |
| `./identyclaw.sh generate-certs [--force]` | Issue self-signed TLS PEMs for pod ingress |
| `./identyclaw.sh test-a2a [from] [peer-token-id]` | Agent Card discovery + unauthenticated `/a2a` → 401 |
| `./identyclaw.sh test-a2a-auth [peer-token-id]` | P2P JWT on `/a2a` (peer via API/registry, then local inbound) |
| `./identyclaw.sh test-a2a-messaging [from] [peer]` | `message/send` → `tasks/get` E2E (requires live peer) |
| `./identyclaw.sh test-auth-boundaries [peer-token-id]` | Channel isolation + mutual P2P JWT binding |
| `./identyclaw.sh upgrade-plugins [id\|all]` | Refresh A2A + IdentyClaw + webhooks plugins from ClawHub pins |
| `./identyclaw.sh discover-a2a-peers [id\|all]` | Discover live peers via `GET /api/agents` and refresh `outbound.agents` |
| `./identyclaw.sh sync-a2a-peers [id\|all]` | Backfill `env.local` from discovered peers (optional ops) |
| `./identyclaw.sh test-webhook [id]` | Webhook ingress (unsigned, invalid sig, signed, optional `/api/testhola`) |
| `./identyclaw.sh test-webhook-p2p [from] [to]` | Bidirectional P2P webhook receipts |
| `./identyclaw.sh send-rodit-webhook id peer-token-id [text]` | POST signed `/hooks/wake` to peer after 10s delay |
| `./identyclaw.sh webhook-url agent-a [path]` | Print public HTTPS webhook URL |
| `./identyclaw.sh token agent-a` | Print Control UI gateway token |
| `./identyclaw.sh chat agent-a` | Interactive terminal chat |
| `./identyclaw.sh ask agent-a "..."` | One-shot message to an agent |
| `./identyclaw.sh onboard agent-a` | Interactive OpenClaw setup (skips hatch TUI / health checks by default) |

## Main-tier ingress (CI/CD + nginx TLS sidecar)

Main-tier HTTPS ingress exists primarily for **A2A** (`POST /a2a`, agent-card discovery) and **OpenClaw webhooks** (`POST /hooks/wake`, `/hooks/agent`, custom `/hooks/<name>`). Control UI over the same hostname is optional for operators. Pattern matches [`clienttest-idc`](../clienttest-idc) (nginx TLS sidecar → HTTP upstream), with per-agent subdomains instead of one `webhook.*` host.

| Branch | Primary health host | Agent hosts |
|--------|---------------------|-------------|
| `development` | `agent-a.dev.identyclaw.com:7443` | `agent-c.dev.identyclaw.com`, `agent-e.dev.identyclaw.com` |
| `main` | `agent-a.identyclaw.com:9443` | `agent-c.identyclaw.com`, `agent-e.identyclaw.com` |

Deploy layout: **nginx sidecar** on **9443** (main) or **7443** (development) — TLS, subdomain → gateway upstream — plus one OpenClaw container per id in `AGENT_IDS` (pod-local ports from `AGENT_*_GATEWAY_PORT`, default 18789 / 18793 / 18797). A single-agent host sets `AGENT_IDS=agent-a` and nginx routes only that subdomain. A2A/webhook URL tables are in local `security-compliance-improvements.md`; see [`clienttest-idc`](../clienttest-idc) for the single-host webhook reference implementation.

### Webhook URLs (main tier)

Each agent has its own HTTPS base. External senders must hit the **correct subdomain** and include a **RODiT origin signature** (`x-signature` + `x-timestamp`):

| Agent (main) | Webhook wake | Webhook agent |
|--------------|--------------|---------------|
| agent-a | `https://agent-a.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |
| agent-c | `https://agent-c.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |
| agent-e | `https://agent-e.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |

Use `agent-*.dev.identyclaw.com` on the development branch. Register the base URL in RODiT token metadata `webhook_url` (same field pattern as a single-host webhook service on `https://webhook.example.com:7443`).

```bash
./identyclaw.sh webhook-url agent-a
./identyclaw.sh test-webhook agent-a    # expect 400/401 without RODiT x-signature
./identyclaw.sh status                  # ingress URLs in pod mode
```

Webhook auth matches [`clienttest-idc`](../clienttest-idc): **Ed25519 signed at origin** via `@rodit/rodit-auth-be` (`x-signature` + `x-timestamp` on the raw body). No shared `hooks.token`, no HMAC. Each agent needs `secrets/near-credentials/*.json` for verification. Register `webhook_url` in Passport metadata (base URL without path).

### Host bootstrap (once per environment)

On the deployment host as the SSH deploy user:

```bash
mkdir -p ../openclaw-agents-app/{certs,logs,agents}
chmod 711 ../openclaw-agents-app/certs

# Or: ./identyclaw.sh init  (creates app layout + env.local from env.example)
cp ~/identyclaw-agents/env.example ~/openclaw-agents-app/env.local
chmod 600 ~/openclaw-agents-app/env.local
# Set IDENTYCLAW_DEPLOY_MODE=pod, IDENTYCLAW_INGRESS_PORT, and AGENT_*_PUBLIC_HOST for your branch

# TLS — self-signed bootstrap (same pattern as clienttest-idc):
./identyclaw.sh generate-certs
# Writes ~/openclaw-agents-app/certs/{fullchain.pem,privkey.pem} with SANs for
# AGENT_A/C/E_PUBLIC_HOST. RODiT JWT handles A2A/webhook mutual auth — CA-issued
# certs are optional. Replace with real PEMs when ready (infra/CERTIFICATE-MANAGEMENT.md).
```

Per-agent runtime state lives under `~/openclaw-agents-app/agents/<agent-id>/`. Scripts resolve this automatically (`IDENTYCLAW_AGENT_STATE_ROOT` defaults to `${IDENTYCLAW_APP_DIR}/agents`). Set `AGENT_IDS` to the agents this host should run, then initialize passwords and API keys:

```bash
./identyclaw.sh set-password agent-a
./identyclaw.sh set-api-key agent-a
```

### GitHub Actions

Workflows:

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) | Push to `main` / `development` | Build image, deploy pod to SSH hosts, health probe |
| [`.github/workflows/test-unit.yml`](.github/workflows/test-unit.yml) | PR + push to `main` / `development` | `node scripts/test-unit-all.mjs` (no Podman) |

Required repository secrets (same names as other IdentyClaw `-idc` repos): `SSH_HOST_MAIN`, `SSH_USER_MAIN`, `SSH_PRIVATE_KEY_MAIN`, `SSH_KNOWN_HOSTS_MAIN`, and the `*_DEVELOPMENT` variants, plus `GHCR_PULL_TOKEN`.

Push to `main` or `development` to build and deploy. Images are tagged `<commit-sha>-main` or `<commit-sha>-development` so development and main tiers do not overwrite each other on GHCR. Health check probes `https://<DOMAIN>:9443/health` (main) or `:7443/health` (development) — advisory; may fail from the runner while the pod is healthy on the host).

### Local deploy (same layout as CI)

```bash
./identyclaw.sh generate-certs          # optional; deploy-pod auto-generates if PEMs are missing
./scripts/deploy-local-podman.sh
TARGET=main ./scripts/deploy-local-podman.sh
USE_LOCAL_RESOLVE=1 ./scripts/deploy-local-podman.sh   # before DNS points here; curl -k for self-signed TLS
```

Standalone dev (`./identyclaw.sh start`) on loopback is unchanged — use SSH tunnels for local webhook testing, or pod deploy above for public HTTPS A2A/webhooks.

## State layout

```
~/openclaw-agents-app/agents/agent-a/
  openclaw.json
  .env                    # OPENCLAW_GATEWAY_TOKEN, IDENTYCLAW_*, NEAR_*
  workspace/
    IDENTITYCLAW.md       # operator guidance (A2A + identity)
    EMAIL.md              # Himalaya / concierge instructions
    scripts/              # himalaya-*.sh, idcp-wallet.sh, idcp-rotate-passport.sh, idcp-activate-account.sh
    skills/idcp-wallet/   # NEAR wallet / Passport rotation skill
  .config/himalaya/config.toml
  secrets/imap.pass       # never commit
  secrets/near-credentials/*.json
  secrets/near-credentials/.active  # active Passport owner account id
  secrets/imap.sh         # auth helper for Himalaya

~/openclaw-agents-app/agents/agent-c/      # same structure

~/openclaw-agents-app/agents/agent-e/      # same structure
```

## Host CLI (optional)

```bash
export OPENCLAW_CONTAINER=openclaw-agent-a
export OPENCLAW_CONFIG_DIR=$HOME/openclaw-agents-app/agents/agent-a
openclaw doctor
```
