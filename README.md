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
        ├── .env              # Rodit / IdentyClaw env (synced from NEAR creds + Passport)
        ├── workspace/        # Agent workspace, skills docs
        ├── secrets/
        │   ├── near-credentials/
        │   │   └── <implicit-account-id-not-set>.json   # IdentyClaw Passport (NEAR key) — required for identity
        │   ├── imap.pass              # Optional Migadu password (set-password)
        │   └── openrouter.key         # LLM API key (set-api-key)
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

| Item | Purpose |
|------|---------|
| **OpenRouter** or **OpenCode** API key | LLM (`set-api-key`) |
| **IdentyClaw Passport** JSON | NEAR credentials under `agents/<id>/secrets/near-credentials/` |
| **NEAR RPC URL** | `IDENTYCLAW_NEAR_RPC_URL` in `env.local` |
| **Public hostname** | DNS, or `/etc/hosts` / `USE_LOCAL_RESOLVE=1` for local testing |
| **TLS** | Self-signed (`generate-certs`) or CA PEMs in `certs/` |

Optional: Migadu (or compatible) mailbox for Himalaya email / HOLA mail probes.

---

## Dependencies: what is fetched when

**`init` does not download dependencies.** It only scaffolds the app directory, copies `env.example` → `env.local`, and writes starter config (`openclaw.json`, Himalaya TOML templates) under `agents/<id>/`.

| Phase | Command | What gets obtained |
|-------|---------|-------------------|
| **Build images** | `./identyclaw.sh build-image` or `deploy-local-podman.sh` (first step) | Pulls `OPENCLAW_BASE_IMAGE` from GHCR; builds `openclaw-himalaya:local` (Himalaya binary from GitHub releases, Chromium in image, Discord plugin seeded via `openclaw plugins install` in the Containerfile); builds `identyclaw-nginx` image |
| **Deploy** | `./scripts/deploy-local-podman.sh` → `deploy-pod.sh` | **ClawHub plugins** into `agents/<id>/extensions/` via ephemeral `podman run` + `openclaw plugins install` (A2A, identyclaw-tools, webhooks — versions pinned in `env.local`); **identyclaw skill** via `openclaw skills install`; starts pod + nginx; renders nginx config; ensures TLS PEMs |
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
| `sk-or-OPENROUTER-API-KEY-NOT-SET` | OpenRouter key (via `set-api-key`, not in `env.local`) |

### 3. Add IdentyClaw Passport credentials

Copy your Passport JSON (NEAR account + private key) to:

```text
../identyclaw-agents-app/agents/agent-name-not-set/secrets/near-credentials/<implicit-account-id-not-set>.json
```

This file is the **root of trust** for RODiT auth. Never commit it.

### 4. Register Passport metadata

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

### 5. LLM API key

```bash
./identyclaw.sh set-api-key agent-name-not-set
# Or OpenCode: ./identyclaw.sh set-opencode-key agent-name-not-set
```

### 6. Build images

```bash
./identyclaw.sh build-image
```

Builds `openclaw-himalaya:local` (OpenClaw + Himalaya). Does **not** create the app directory — you should have run `init` already.

### 7. TLS for nginx

```bash
./identyclaw.sh generate-certs
```

Uses SANs from Passport-derived hostnames (or `AGENT_*_PUBLIC_HOST` if set). Or place CA-issued `fullchain.pem` + `privkey.pem` in `../identyclaw-agents-app/certs/`.

### 8. Deploy

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

After deploy, use the operator CLI copied to the app dir:

```bash
../identyclaw-agents-app/repo/identyclaw.sh restart all
../identyclaw-agents-app/repo/identyclaw.sh status
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

### Required on disk (not in `env.local`)

| Path | Purpose |
|------|---------|
| `agents/<id>/secrets/near-credentials/<implicit-account-id-not-set>.json` | IdentyClaw Passport NEAR credentials |
| Passport `metadata.webhook_url` | Public HTTPS base for ingress + A2A (e.g. `https://agent-domain-not-set.example.com:9443`) |
| LLM key via `set-api-key` | OpenRouter / OpenCode auth (`sk-or-OPENROUTER-API-KEY-NOT-SET` placeholder until set) |

### Optional overrides (leave unset for Passport self-config)

| Variable | When to set |
|----------|-------------|
| `AGENT_*_PUBLIC_HOST` | Force hostname instead of Passport `webhook_url` |
| `AGENT_*_A2A_PUBLIC_BASE_URL` | Force A2A base URL |
| `AGENT_*_EMAIL` / `AGENT_*_DISPLAY_NAME` | Force mailbox / agent card name |
| `AGENT_*_PASSWORD` | Migadu IMAP/SMTP password |
| `IDENTYCLAW_API_BASE_URL` | Override IdentyClaw API base (default: Passport `subjectuniqueidentifier_url`) |
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

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Empty public host / A2A URL | NEAR creds present? `metadata.webhook_url` set in Passport? `IDENTYCLAW_RODIT_SELF_CONFIGURE=1`? |
| Deploy fails “set AGENT_*_EMAIL” | Add NEAR creds before deploy, or set `AGENT_*_EMAIL` in `env.local` |
| `/a2a` 401 | Passport creds, inbound audience (`owner_id`), peer JWT |
| Health check fails | `generate-certs` or CA PEMs, firewall on `:9443`, DNS vs `USE_LOCAL_RESOLVE=1` |
| Plugin build errors | Node 22+, npm, network; retry deploy or `upgrade-plugins` |

For unit tests on webhook URL resolution:

```bash
node scripts/test-peer-gateway-resolution.mjs
```
