# OpenClaw + IdentyClaw Agent Template

Deploy a single [OpenClaw](https://docs.openclaw.ai) gateway with **IdentyClaw identity** (NEAR Passport / RODiT), A2A peer messaging, and signed webhooks — using Podman on your host or via GitHub Actions.

This repository is **code-only** (safe to clone publicly). Runtime config, secrets, TLS, and agent state live outside the git checkout in a sibling **app directory** (default `../identyclaw-agents-app`).

## What you get

| Component | Role |
|-----------|------|
| **OpenClaw gateway** | Agent runtime, tools, channels (Discord optional), Himalaya email skill |
| **IdentyClaw plugin + skill** | Passport identity, HOLA verification, agent/resource API tools |
| **identyclaw-a2a plugin** | Agent-to-agent messaging with RODiT JWT inbound auth |
| **identyclaw-webhooks plugin** | RODiT-signed inbound webhooks (`/hooks/wake`, `/hooks/agent`) |
| **nginx TLS sidecar** (pod mode) | Public HTTPS on `:9443` → OpenClaw upstream |
| **Workspace governance docs** | `AGENTS.md` "Trust & tool tiers" + `BOOT.md` reset reminder, written on bootstrap |
| **Knowledge base (local docs)** | QMD indexes `workspace/knowledge/` for `memory_search` |
| **QMD memory** | Session recall + `MEMORY.md` / daily notes via `memory_search` |
| **Smoke tests** | `./identyclaw.sh test` — local A2A, webhooks, optional mail |

Mutual auth for A2A and webhooks uses **RODiT JWT / Ed25519 signatures**, not TLS client certificates. TLS is transport encryption only.

---

## Repository vs app directory

| Location | Contents | In git? |
|----------|----------|---------|
| **`identyclaw-agents/`** (this repo) | Scripts, Containerfiles, `env.example`, CI | Yes |
| **`identyclaw-agents-app/`** (default sibling) | `env.local`, `certs/`, `agents/`, `logs/`, `exports/`, `repo/` copy | **No** |

The app directory is **not** created by `build-image`. It is scaffolded by:

- `./identyclaw.sh init` — creates `env.local` from `env.example` + per-agent state under `agents/<id>/`
- `./scripts/deploy-local-podman.sh` — also calls `ensure_app_layout` if you skip `init`
- `./identyclaw.sh generate-certs` — ensures `certs/` exists

Override the app root: `export IDENTYCLAW_APP_DIR=/path/to/your-app`

### App directory layout (after init / deploy)

```
identyclaw-agents-app/
├── env.local                 # Host config (chmod 600) — copied from env.example on first init
├── certs/
│   ├── fullchain.pem         # nginx TLS (self-signed or CA-issued)
│   └── privkey.pem
├── logs/nginx/
├── exports/                  # agent migration archives
├── repo/                     # Synced copy of identyclaw.sh + scripts (operator CLI after deploy)
└── agents/
    └── agent-name-not-set/   # Rename slug in AGENT_IDS + env prefix together
        ├── openclaw.json     # Gateway + plugin config (synced on bootstrap)
        ├── .env              # Gateway token + LLM keys (OPENROUTER_API_KEY / OPENCODE_API_KEY)
        ├── workspace/        # Agent workspace, skills docs
        │   └── knowledge/  # Product/service docs for RAG (see Knowledge base below)
        ├── secrets/
        │   ├── near-credentials/
        │   │   └── <implicit-account-id-not-set>.json   # IdentyClaw Passport (NEAR key)
        │   └── imap.pass              # Optional Migadu password (set-password)
        ├── agents/main/agent/   # OpenClaw runtime state (no LLM keys here)
        └── extensions/         # ClawHub plugins (built during deploy)
```

---

## Prerequisites

**Host tools**

| Tool | Why |
|------|-----|
| **Podman** (rootless recommended) | Runs OpenClaw gateway + nginx containers |
| **Node 22+** on the host | Rodit passport probe scripts (`probe-rodit-passport-urls.mjs`, etc.) during bootstrap; smoke tests |
| **Python 3** | `openclaw.json` / `.env` sync helpers in `scripts/lib.sh` |
| **openssl** | `generate-certs` (optional if you supply CA PEMs) |
| **git** | Clone this repo only — not used during deploy |

Host **npm** is not required for the standard path: ClawHub plugin installs run **inside** the OpenClaw container (or a one-off `podman run --rm` of that image) via `openclaw.mjs plugins install`.

**Network** (during build/deploy): `ghcr.io`, GitHub releases (Himalaya binary), ClawHub registry, npm registry (pulled by OpenClaw inside the container).

**Credentials & config**

| Item | When needed | Purpose |
|------|-------------|---------|
| **OpenRouter** or **OpenCode** API key | Before deploy | LLM (`set-api-key`) |
| **NEAR RPC URL** | Before deploy | `IDENTYCLAW_NEAR_RPC_URL` in `env.local` |
| **Public hostname** | Before TLS / Passport metadata | DNS, `AGENT_*_PUBLIC_HOST`, or Passport `webhook_url` |
| **TLS** | Before deploy | Self-signed (`generate-certs`) or CA PEMs in `certs/` |
| **NEAR implicit account** | After first deploy | `./identyclaw.sh generate-near-account <id>` (Node in container; host npm not required) |
| **IdentyClaw Passport** JSON | After purchase | NEAR credentials under `agents/<id>/secrets/near-credentials/` |

Optional: Migadu (or compatible) mailbox for Himalaya email / HOLA mail probes.

---

## Dependencies: what is fetched when

**`init` does not download dependencies.** It only scaffolds the app directory, copies `env.example` → `env.local`, and writes starter config (`openclaw.json`, Himalaya TOML templates) under `agents/<id>/`.

| Phase | Command | What gets obtained |
|-------|---------|-------------------|
| **Build images** | `./identyclaw.sh build-image` or `deploy-local-podman.sh` (first step) | Pulls `OPENCLAW_BASE_IMAGE` from GHCR; builds `openclaw-himalaya:local` (Himalaya binary from GitHub releases, Chromium in image, Discord plugin seeded via `openclaw plugins install` in the Containerfile); builds `identyclaw-nginx` image |
| **Deploy** | `./scripts/deploy-local-podman.sh` → `deploy-pod.sh` | **ClawHub plugins** into `agents/<id>/extensions/` via ephemeral `podman run` + `openclaw plugins install` (A2A, identyclaw-tools, webhooks — versions pinned in `env.local`); **identyclaw skill** via `openclaw skills install`; starts pod + nginx; renders nginx config; ensures TLS PEMs. Then `./identyclaw.sh generate-near-account <id>` |
| **Bootstrap** | Runs during deploy (`ensure_agent_bootstrap`) and on `start`/`restart` | Host **Node** probes Passport (`RoditClient`, identity API); syncs `.env` and `openclaw.json` plugin config; installs/refreshes plugins if NEAR creds present and versions drift |
| **Runtime** | Container start | Entrypoint seeds bundled Discord plugin from image into the bind-mounted home if versions drift |

Skip plugin downloads on deploy: `SKIP_PLUGIN_UPDATE=1 ./scripts/deploy-local-podman.sh` (extensions must already exist under `agents/<id>/extensions/`).

Refresh plugins later: `./identyclaw.sh upgrade-plugins all`.

Pinned sources (defaults in `env.example`):

- `IDENTYCLAW_CLAWHUB_PLUGIN` — `@identyclaw/openclaw-identyclaw-plugin`
- `IDENTYCLAW_CLAWHUB_A2A_PLUGIN` — `@identyclaw/openclaw-a2a-plugin`
- `IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN` — `@identyclaw/openclaw-identyclaw-webhooks-plugin`
- `IDENTYCLAW_CLAWHUB_SKILL` — `identyclaw` skill on ClawHub
- `OPENCLAW_BUNDLED_PLUGINS` — `@openclaw/discord` (baked into the gateway image at build time)

---

## Create your agent (end-to-end)

Replace `agent-name-not-set` with your slug (e.g. `agent-acme`). Env vars derive from the slug: `agent-acme` → `AGENT_ACME_*`.

### 1. Clone and initialize

```bash
git clone <this-repo> identyclaw-agents
cd identyclaw-agents
chmod +x identyclaw.sh

./identyclaw.sh init
```

This creates `../identyclaw-agents-app/env.local` and `agents/agent-name-not-set/` with a starter `openclaw.json`.

### 2. Configure `env.local`

Edit `../identyclaw-agents-app/env.local`. **Minimum required:**

```bash
# Rename when ready (slug + env prefix must match):
# AGENT_IDS=agent-acme

IDENTYCLAW_NEAR_RPC_URL=https://go.getblock.io/GETBLOCK-API-KEY-NOT-SET
```

Everything else in `env.example` has sensible defaults. See [Configuration](#configuration) below.

Placeholder values use a consistent `not-set` pattern until you replace them:

| Placeholder | Replace with |
|-------------|--------------|
| `agent-name-not-set` | Your agent slug (e.g. `agent-acme`) |
| `AGENT_NAME_NOT_SET_*` | Env prefix derived from that slug |
| `GETBLOCK-API-KEY-NOT-SET` | Your NEAR RPC provider API key |
| `agent-domain-not-set.example.com` | Your public DNS hostname |
| `<implicit-account-id-not-set>` | 64-char NEAR implicit account from Passport enrollment |
| `sk-OPENROUTER-API-KEY-NOT-SET` | OpenRouter key (via `set-api-key`, not in `env.local`) |

### 3. LLM API key

```bash
./identyclaw.sh set-api-key agent-name-not-set
# Or OpenCode: ./identyclaw.sh set-opencode-key agent-name-not-set
```

### 4. Build images

```bash
./identyclaw.sh build-image
```

Builds `openclaw-himalaya:local` (OpenClaw + Himalaya). Does **not** create the app directory — you should have run `init` already.

### 5. TLS for nginx

If you do not have Passport credentials yet, set a public hostname override first (used for cert SANs):

```bash
# In env.local (until Passport metadata.webhook_url is available):
# AGENT_NAME_NOT_SET_PUBLIC_HOST=agent-domain-not-set.example.com
```

Then:

```bash
./identyclaw.sh generate-certs
```

Uses SANs from Passport-derived hostnames (or `AGENT_*_PUBLIC_HOST` if set). Or place CA-issued `fullchain.pem` + `privkey.pem` in `../identyclaw-agents-app/certs/`.

### 6. Deploy

**Production layout (recommended)** — Podman pod + nginx sidecar:

```bash
./scripts/deploy-local-podman.sh
```

Before DNS points at the host:

```bash
USE_LOCAL_RESOLVE=1 ./scripts/deploy-local-podman.sh
```

**Loopback-only (development)** — no nginx pod:

```bash
# In env.local: IDENTYCLAW_DEPLOY_MODE=standalone
./identyclaw.sh start all
```

Deploy **installs ClawHub plugins and the identyclaw skill** into `agents/<id>/extensions/` (IdentyClaw tools, A2A, webhooks — versions pinned in `env.local`), renders nginx config, and starts the gateway.

After deploy, use the operator CLI copied to the app dir:

```bash
../identyclaw-agents-app/repo/identyclaw.sh restart all
../identyclaw-agents-app/repo/identyclaw.sh status
```

#### Generate NEAR implicit account (openclaw-identyclaw plugin)

After the first deploy, the **openclaw-identyclaw plugin** (`identyclaw-tools`) is installed. Create the NEAR implicit account **before** purchasing a Passport.

**Host npm is not required** — Node runs inside the OpenClaw container:

```bash
./identyclaw.sh generate-near-account agent-name-not-set
```

This writes `agents/<id>/secrets/near-credentials/<implicit_account_id>.json` (mode `0600`) and prints the `implicit_account_id` on stdout. Private keys are never printed.

Then:

1. **Purchase** an IdentyClaw Passport at https://purchase.identyclaw.com using that `implicit_account_id` (mint checkout funds the account)

### 7. Add IdentyClaw Passport credentials

After purchase, the NEAR credentials JSON should already be at:

```text
../identyclaw-agents-app/agents/agent-name-not-set/secrets/near-credentials/<implicit-account-id-not-set>.json
```

If you generated the account with the plugin (step 6), the file is already there. Otherwise copy your Passport JSON (NEAR account + private key) to that path.

This file is the **root of trust** for RODiT auth. Never commit it.

Restart the gateway so bootstrap syncs credentials into `.env` and plugin config:

```bash
./identyclaw.sh restart agent-name-not-set
```

### 8. Register Passport metadata

In your IdentyClaw Passport, set:

```text
metadata.webhook_url = https://agent-domain-not-set.example.com:9443
```

- Include **scheme**, **host**, and **port**
- **No path suffix** (no `/a2a`, no `/hooks/...`)
- Example: `https://agent-domain-not-set.example.com:9443`

With NEAR creds present, bootstrap **self-configures** from Passport via `RoditClient.getConfigOwnRodit()` (and identity API `/full` when needed):

| Derived at bootstrap | Passport / Rodit source |
|----------------------|------------------------|
| Public host, ingress port | `metadata.webhook_url` |
| A2A public base URL | `metadata.webhook_url` |
| IdentyClaw API base | `metadata.subjectuniqueidentifier_url` |
| Inbound JWT audience | `owner_id` |
| Own `token_id` | Passport config |
| Display name, email | DN / `contactUri` (env overrides optional) |

Set `IDENTYCLAW_RODIT_SELF_CONFIGURE=0` in `env.local` to disable and use explicit `AGENT_*_PUBLIC_HOST` / `AGENT_*_EMAIL` instead.

Re-run `generate-certs` if TLS SANs should match the Passport hostname, then restart:

```bash
./identyclaw.sh generate-certs --force
./identyclaw.sh restart agent-name-not-set
```

### 9. Validate

```bash
./identyclaw.sh test
./identyclaw.sh token agent-name-not-set    # Control UI gateway token
./identyclaw.sh webhook-url agent-name-not-set
```

Optional mail (after `./identyclaw.sh set-password agent-name-not-set`):

```bash
./identyclaw.sh test-mail agent-name-not-set
```

### 10. Boot persistence (optional)

```bash
./identyclaw.sh enable-boot
```

Enables user linger + `podman-restart.service` so containers survive reboot.

---

## Configuration

### Required in `env.local`

| Variable | Purpose |
|----------|---------|
| `AGENT_IDS` | Space-separated agent slugs (default `agent-name-not-set`) |
| `IDENTYCLAW_NEAR_RPC_URL` | NEAR RPC for RoditClient / on-chain reads |

### Required on disk (not in `env.local`) — after deploy + Passport purchase

| Path / step | Purpose |
|-------------|---------|
| `agents/<id>/extensions/identyclaw-tools` | openclaw-identyclaw plugin (installed by deploy) |
| `./identyclaw.sh generate-near-account <id>` | NEAR implicit account JSON (runs in container) |
| `agents/<id>/secrets/near-credentials/<implicit-account-id-not-set>.json` | NEAR implicit account + private key (from plugin or post-purchase) |
| https://purchase.identyclaw.com | Mint IdentyClaw Passport to your `implicit_account_id` |
| Passport `metadata.webhook_url` | Public HTTPS base for ingress + A2A (e.g. `https://agent-domain-not-set.example.com:9443`) |
| LLM key via `set-api-key` | `agents/<id>/.env` (`OPENROUTER_API_KEY`); sqlite holds env ref only (re-synced on deploy/restart) |

### Optional overrides (leave unset for Passport self-config)

| Variable | When to set |
|----------|-------------|
| `AGENT_*_PUBLIC_HOST` | Force hostname instead of Passport `webhook_url` |
| `AGENT_*_A2A_PUBLIC_BASE_URL` | Force A2A base URL |
| `AGENT_*_EMAIL` / `AGENT_*_DISPLAY_NAME` | Force mailbox / agent card name |
| `AGENT_*_PASSWORD` | Migadu IMAP/SMTP password |
| `IDENTYCLAW_API_BASE_URL` | Override IdentyClaw API base (default: Passport `subjectuniqueidentifier_url`) |
| `IDENTYCLAW_KNOWLEDGE_ENABLED` | Set `0` to disable local document RAG (default `1`) |
| `IDENTYCLAW_KNOWLEDGE_PATH` | Knowledge folder relative to workspace (default `./knowledge`) |
| `A2A_PEER_AGENTS` | Space-separated remote peer `token_id` list |
| `IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1` | Auto-discover peers from `GET /api/agents` |
| `IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1` | Learn peers from inbound P2P JWT logins |

### Agent id naming

Ids must match `agent-{slug}` where slug starts with a letter (`agent-acme`, `agent-name-not-set`). Env prefix = slug with hyphens → underscores: `agent-acme` → `AGENT_ACME_GATEWAY_PORT`.

---

## Architecture (pod mode)

```
Internet
    │
    ▼
nginx :9443 (TLS, self-signed or CA)
    ├── GET  /.well-known/agent-card.json
    ├── POST /a2a                    ← Authorization: Bearer <RODiT JWT>
    └── POST /hooks/wake|agent       ← RODiT x-signature + x-timestamp
    │
    ▼
OpenClaw gateway :18789 (pod internal, lan bind)
    ├── identyclaw-tools plugin      ← HOLA, identity, resources
    ├── identyclaw-a2a plugin        ← P2P messaging
    └── identyclaw-webhooks plugin   ← signed webhook ingress
```

Nginx config is rendered at deploy from `scripts/render-nginx-conf.sh` using Passport-derived hostnames and `AGENT_IDS`.

---

## Common commands

Run from the repo root (or `../identyclaw-agents-app/repo/` after deploy):

| Command | Purpose |
|---------|---------|
| `./identyclaw.sh init` | Create app dir + agent state from `AGENT_IDS` |
| `./identyclaw.sh build-image` | Build OpenClaw + Himalaya image |
| `./identyclaw.sh generate-certs [--force]` | Self-signed TLS for nginx |
| `./scripts/deploy-local-podman.sh` | Full pod + nginx deploy (mirrors CI) |
| `./identyclaw.sh start\|stop\|restart [id\|all]` | Manage gateway containers |
| `./identyclaw.sh status` | Podman state + ingress URLs |
| `./identyclaw.sh test [id]` | Full local smoke suite |
| `./identyclaw.sh upgrade-plugins [id\|all]` | Refresh IdentyClaw plugins from ClawHub |
| `./identyclaw.sh discover-a2a-peers [id\|all]` | Refresh outbound peers from API |
| `./identyclaw.sh knowledge-reindex <id>` | Rebuild local `workspace/knowledge/` index |
| `./identyclaw.sh set-password <id>` | Migadu mailbox password |
| `./identyclaw.sh set-discord-token <id>` | Discord bot token |
| `./identyclaw.sh onboard <id>` | OpenClaw interactive setup |
| `./identyclaw.sh chat <id>` | Terminal chat against running gateway |
| `./identyclaw.sh export-agent <id>` | Pack agent for migration |
| `./identyclaw.sh import-agent <id> <file>` | Restore from export |

---

## GitHub Actions deploy

Push to **`main`** triggers CI:

1. Build images → GHCR tags `<sha>-main`
2. SSH deploy to host using secrets: `SSH_HOST_MAIN`, `SSH_USER_MAIN`, `SSH_PRIVATE_KEY_MAIN`, `SSH_KNOWN_HOSTS_MAIN`, `GHCR_PULL_TOKEN`
3. Post-deploy health check against `https://$HEALTH_CHECK_HOST:9443/health`

Set repository variable **`HEALTH_CHECK_HOST`** to your Passport webhook hostname (or `AGENT_*_PUBLIC_HOST` if overridden).

---

## Multi-agent hosts

Set `AGENT_IDS=agent-a agent-b` and add matching `AGENT_B_*` variables in `env.local`. Each agent gets its own Passport creds, nginx server block, and pod container. Nginx config is rendered per agent at deploy time.

---

## Security

- **Never commit** `env.local`, `secrets/`, gateway tokens, API keys, or NEAR private keys.
- The repo runs **Gitleaks** in CI; runtime secrets belong only under `identyclaw-agents-app/`.
- Replace self-signed certs with CA-issued PEMs before production traffic.
- Inbound A2A rejects unauthenticated requests; webhook ingress requires RODiT origin signatures.
- Chat channels (Telegram/Discord) use `dmPolicy: open` by default in this template. For a per-sender trust and approval model, see [Agent governance](#agent-governance-trust--tool-tiers) below.

---

## Knowledge base (local document RAG)

Bootstrap indexes **local** product and service documentation from `workspace/knowledge/`
via **QMD** (`memory.qmd.paths` → `memory_search`). Use this for FAQs, API references,
pricing sheets, and runbooks.

**Upload path on the host:**

```text
identyclaw-agents-app/agents/<agent-id>/workspace/knowledge/
```

Supported formats: `.md`, `.txt`, `.pdf`, `.csv`, `.json`. Prefer topic-focused Markdown
files over one large PDF. After bulk changes:

```bash
./identyclaw.sh knowledge-reindex <agent-id>
```

The gateway also re-indexes periodically (QMD default ~5m). Force a rebuild with
`./identyclaw.sh knowledge-reindex <agent-id>` (runs `openclaw memory index --force`).

### What goes where

| Content | Location / tool |
|---------|-----------------|
| Product & service docs (local) | `workspace/knowledge/` — QMD `memory_search` |
| Network-published IdentyClaw resources | `identyclaw_list_resources` / `identyclaw_get_resource` |
| Preferences, session notes, learned facts | `MEMORY.md`, `memory/YYYY-MM-DD.md` — QMD memory |
| Agent behavior & trust rules | `AGENTS.md`, `IDENTYCLAW.md`, `KNOWLEDGE.md` |

QMD memory (`IDENTYCLAW_MEMORY_BACKEND=builtin` by default; set `qmd` only if the
`qmd` binary is installed in your OpenClaw image) indexes `workspace/knowledge/`
alongside session recall. Disable local doc indexing with `IDENTYCLAW_KNOWLEDGE_ENABLED=0`.

---

## Agent governance (Trust & tool tiers)

Bootstrap writes a **Trust & tool tiers** section into each agent's `workspace/AGENTS.md`
and a matching reminder into `workspace/BOOT.md`. These shape how the agent *reasons*
about trust — they are **governance, not a hard security boundary**.

| File | Content | Loaded |
|------|---------|--------|
| `AGENTS.md` → `## Trust & tool tiers` | Trust states, tool tiers, HOLA + operator-approval rules | Every session |
| `BOOT.md` → `## Trust reset on restart` | Reset all chat senders to Unverified after a gateway restart | On gateway restart |

**Scope:** tiers apply to **open chat** instructions (Telegram, Discord, email), not to inbound **A2A** (`POST /a2a`, RODiT JWT) or **webhooks** (RODiT signature). Sensitive tools like `a2a_send_message` guard against a chat stranger instructing outbound A2A — not against authenticated A2A peers calling `/a2a` directly.

**Trust states** (per session, per sender):

- **Unverified** — default for every new chat sender; identity claims in text are not evidence
- **HOLA-verified** — `identyclaw_verify_hola` returned `verified: true` and the `peerTokenId` passes the impersonation guard in `IDENTYCLAW.md`
- **Operator** — a known admin (channel `allowFrom` / `commands.ownerAllowFrom`, e.g. the paired Telegram/Discord id)

**Tool tiers:**

| Tier | Example tools | Requirement |
|------|---------------|-------------|
| Public | `read`, `identyclaw_list_agents`, `identyclaw_create_hola` / `identyclaw_verify_hola`, Q&A | none |
| Verified | `identyclaw_get_agent_identity`, targeted `message` | HOLA-verified this session |
| Sensitive | `a2a_send_message`, `send_rodit_webhook`, `exec`, `write`/`edit`, sending email | HOLA-verified **and** operator-approved |

Trust does not persist across sessions or gateway restarts.

### Governance vs enforcement

The workspace docs are behavior guidance. For **hard** enforcement, pair them with
OpenClaw config (bootstrap writes `tools.toolsBySender` automatically on every
`start` / `restart` / deploy):

- **Channel access** — `channels.*.dmPolicy` (`pairing` / `allowlist`), `allowFrom`
- **Per-sender tool caps** — `tools.toolsBySender` (denied tools are removed from the model's schema; public senders get HOLA create/verify, operators get full tools)
- **Admin approval** — `channels.*.execApprovals` for `exec`, or a plugin `before_tool_call` `requireApproval` hook for any tool
- **Cryptographic identity** — RODiT JWT on A2A, RODiT signatures on webhooks, HOLA verification on inbound email (already enforced)

The docs are regenerated idempotently on every `init` and bootstrap (deploy / `start` /
`restart`); the `## Trust & tool tiers` and `## Trust reset on restart` blocks are
upserted in place, so hand-edits outside those blocks are preserved.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Empty public host / A2A URL | NEAR creds present? `metadata.webhook_url` set in Passport? `IDENTYCLAW_RODIT_SELF_CONFIGURE=1`? |
| Deploy fails “set AGENT_*_EMAIL” | Add NEAR creds before deploy, or set `AGENT_*_EMAIL` in `env.local` |
| `/a2a` 401 | Passport creds, inbound audience (`owner_id`), peer JWT |
| Health check fails | `generate-certs` or CA PEMs, firewall on `:9443`, DNS vs `USE_LOCAL_RESOLVE=1` |
| Plugin build errors | Node 22+, npm, network; retry deploy or `upgrade-plugins` |
| Agent can't send Telegram→Discord (or mixes channels / uses raw API) | Restart after deploy so `openclaw.json` gets `tools.message.crossContext.allowAcrossProviders`; agent should read `CHAT_CHANNELS.md` and use the `message` tool with explicit `channel` |

For unit tests on webhook URL resolution:

```bash
node scripts/test-peer-gateway-resolution.mjs
```
