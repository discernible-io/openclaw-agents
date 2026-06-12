# Identyclaw OpenClaw (Podman)

Three isolated OpenClaw gateways with Himalaya + Migadu (`identyclaw.com`).

## Prerequisites

- Podman (rootless recommended). On AlmaLinux / RHEL / Fedora:

  ```bash
  sudo dnf install -y podman
  ```

- Optional: `openclaw` CLI on the host for advanced management
- Migadu mailboxes: `agent-a@identyclaw.com`, `agent-b@identyclaw.com` (or edit `~/identyclaw-agents-app/env.local`)

Mailbox passwords are **not** required for `init`, `build-image`, or `start` — you can add them later (see [Set email passwords later](#set-email-passwords-later)).

## Repository vs app directory

The **git checkout** holds scripts and image definitions only. **Config, TLS, and agent state** live in a sibling app directory (default `../identyclaw-agents-app`):

| Path | Purpose |
|------|---------|
| `identyclaw-agents/` | Clone of this repo — run `./identyclaw.sh` from here |
| `../identyclaw-agents-app/env.local` | Runtime settings (chmod 600; created by `./identyclaw.sh init`) |
| `../identyclaw-agents-app/agents/agent-{a,b,c}/` | Per-agent state (`openclaw.json`, `secrets/near-credentials/`, workspace) |
| `../identyclaw-agents-app/certs/` | TLS for production pod (not used in standalone dev) |

Override the app root: `export IDENTYCLAW_APP_DIR=/custom/path` (default: `../identyclaw-agents-app` next to the clone).

## Quick start (rootless — recommended)

Run as your normal user (not `root`):

```bash
cd ~/identyclaw-agents
chmod +x identyclaw.sh
./identyclaw.sh init          # creates ../identyclaw-agents-app/ and env.local from env.example
# Edit ../identyclaw-agents-app/env.local if needed (emails, ports; passwords optional)
./identyclaw.sh build-image
./identyclaw.sh start all
./identyclaw.sh status
```

When Migadu passwords are ready:

```bash
./identyclaw.sh set-password agent-a
./identyclaw.sh set-password agent-b
./identyclaw.sh restart all
./identyclaw.sh test-mail agent-a
./identyclaw.sh test-mail agent-b
./identyclaw.sh set-api-key agent-a    # OpenRouter sk-or-... (validated)
./identyclaw.sh onboard agent-a        # skips hatch TUI / health checks by default
./identyclaw.sh restart agent-a
# repeat for agent-b
```

**Recommended before first onboard:** rebuild the image once so `/openclaw.mjs`, OpenClaw **2026.5.27+**, and bundled plugins (Discord) are in the image:

```bash
./identyclaw.sh build-image
./identyclaw.sh restart all
```

The local image pins `ghcr.io/openclaw/openclaw:2026.5.27-slim` and pre-installs `@openclaw/discord` at build time. On each container start, the entrypoint copies that plugin tree into the agent’s mounted `~/.openclaw/npm` if Discord is not already present — agents do not need to run `openclaw plugins install` or `npm i -g openclaw` at runtime.

- **Pod mode** (dedalo43): Agent A UI: `https://agent-a.identyclaw.com:9443/` — token: `./identyclaw.sh token agent-a`
- **Standalone dev**: Agent A UI: http://127.0.0.1:18789/ — Agent B: http://127.0.0.1:18791/

See [Accessing agents (CLI and browser)](#accessing-agents-cli-and-browser) for terminal chat and remote laptop access.

## Accessing agents (CLI and browser)

By default gateways bind to **`127.0.0.1`** only (`PUBLISH_HOST=127.0.0.1` in `env.local`). That means they are reachable on the **server**, not directly from a remote laptop, unless you use an SSH tunnel or change the publish bind (below).

### Chat via CLI (no browser)

Interactive terminal chat on the **server** (SSH session as your normal user). No loopback HTTP from your laptop required.

**Interactive chat** (easiest):

```bash
cd ~/identyclaw-agents
./identyclaw.sh chat agent-a
./identyclaw.sh chat agent-b
```

Exit with **Ctrl+C** or the TUI quit command.

**One-shot question:**

```bash
./identyclaw.sh ask agent-a "Summarize what you can help with for customer support."
./identyclaw.sh ask agent-b "Draft a short reply to a shipping delay inquiry."
```

**Gateway-backed TUI** (same session as Control UI — advanced):

```bash
cd ~/identyclaw-agents
podman exec -it openclaw-agent-a node dist/index.js tui \
  --url ws://127.0.0.1:18789 \
  --token "$(./identyclaw.sh token agent-a)"
```

Use port **18791** and `./identyclaw.sh token agent-b` for agent B.

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

No need to expose OpenClaw ports on the public internet. On your **laptop**:

```bash
ssh -L 18789:127.0.0.1:18789 -L 18791:127.0.0.1:18791 dedalo46@YOUR_SERVER_IP
```

Keep that SSH session open. In the laptop browser:

| Agent | URL |
|-------|-----|
| A | `http://127.0.0.1:18789/#token=TOKEN` |
| B | `http://127.0.0.1:18791/#token=TOKEN` |

Get tokens on the server: `./identyclaw.sh token agent-a` (or `agent-b`).

Or chat over SSH without a browser:

```bash
ssh dedalo46@YOUR_SERVER_IP
cd ~/identyclaw-agents
./identyclaw.sh chat agent-a
```

### Remote browser — public IP (optional)

Only if you intentionally want the Control UI on the internet. Prefer HTTPS via a reverse proxy in production; raw HTTP + token is risky.

**1. Publish on all interfaces** — in `env.local`:

```bash
PUBLISH_HOST=0.0.0.0
```

**2. Allow your origin** — in `~/identyclaw-agents-app/agents/agent-a/openclaw.json` (and agent B on 18791):

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
sudo firewall-cmd --permanent --add-port=18791/tcp
sudo firewall-cmd --reload
```

**4. Restart and verify:**

```bash
cd ~/identyclaw-agents
./identyclaw.sh restart all
ss -tlnp | grep -E '18789|18791'   # expect 0.0.0.0:...
```

**5. Laptop browser:**

```text
http://YOUR_SERVER_IP:18789/#token=TOKEN
```

Get `TOKEN` on the server with `./identyclaw.sh token agent-a`.

## Set email passwords later

You can bring both agents up before mail is configured. Himalaya reads credentials from each agent’s `secrets/` directory (not from `env.local` at runtime).

**Option A — interactive (recommended)**

```bash
./identyclaw.sh set-password agent-a
./identyclaw.sh set-password agent-b
./identyclaw.sh restart all
./identyclaw.sh test-mail agent-a
```

**Option B — one-time in `env.local`**

Set `AGENT_A_PASSWORD` and `AGENT_B_PASSWORD` in `env.local`, then re-run init (only writes secrets if the password fields are non-empty):

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

## Rootful (optional, not recommended)

Only if you intentionally run Podman as root:

```bash
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh build-image
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh init
# Set passwords and start as root; state under /root/identyclaw-agents-app/agents/
sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh start all
```

Rootless is safer: config stays in your home directory with your UID.

## Run in background and survive reboot

Both agents run as **detached Podman containers** (`podman run -d`). They keep running when you close SSH, and can start again after a **machine reboot** once boot persistence is enabled.

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
3. Recreates both agents with `--restart always`  

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
podman inspect openclaw-agent-a openclaw-agent-b \
  --format '{{.Name}} policy={{.HostConfig.RestartPolicy.Name}} state={{.State.Status}}'
# policy=always  state=running
./identyclaw.sh status
```

### After a machine reboot

Wait ~30 seconds for user systemd and Podman, then:

```bash
./identyclaw.sh status
curl -s -o /dev/null -w 'agent-a: %{http_code}\n' http://127.0.0.1:18789/
curl -s -o /dev/null -w 'agent-b: %{http_code}\n' http://127.0.0.1:18791/
```

Both containers should show **Up** without running `./identyclaw.sh start`.

### Day-to-day commands

```bash
./identyclaw.sh status      # are they running?
./identyclaw.sh logs agent-a
./identyclaw.sh restart all # after config changes
./identyclaw.sh stop all    # stop until next reboot (podman-restart starts them again on boot)
```

### Optional: Quadlet units

For production, you can replace manual starts with Podman Quadlet units under `~/.config/containers/systemd/` (see [OpenClaw Podman docs](https://docs.openclaw.ai/install/podman)).

### Cleanup stray onboard containers

If onboarding was interrupted, remove one-off containers (they are not restarted on boot):

```bash
podman rm -f openclaw-agent-a-onboard openclaw-agent-b-onboard 2>/dev/null || true
```

## Configuration

Each agent has isolated state under `~/identyclaw-agents-app/agents/agent-{a,b,c}/`. Host ports come from `~/identyclaw-agents-app/env.local`; OpenClaw settings live in each agent’s `openclaw.json`.

**Never commit or paste gateway tokens or API keys.** Use `./identyclaw.sh token agent-a` when you need the Control UI token.

### IdentyClaw identity + A2A peer messaging

Each agent uses **two** published integrations (installed on `./identyclaw.sh start` / restart):

| Integration | Source | Purpose |
|-------------|--------|---------|
| **identyclaw** skill + `identyclaw-tools` plugin | [ClawHub: identyclaw/identyclaw](https://clawhub.ai/identyclaw/identyclaw) | HOLA verify/create, Passport lookup, DID, API workflows |
| **identyclaw-a2a** plugin | [ClawHub: @identyclaw/openclaw-a2a-plugin](https://clawhub.ai/plugins/@identyclaw/openclaw-a2a-plugin) | Agent-to-agent messaging (`a2a_send_message`, tasks, files) with RODiT JWT auth |

Bootstrap writes `workspace/IDENTYCLAW.md` with operator guidance. Passport credentials go in `secrets/near-credentials/*.json` per agent (synced to `IDENTYCLAW_*` env vars). A2A peers are listed in `A2A_PEER_AGENTS` (`env.local`).

```bash
# After adding near-credentials for agent-a and agent-b:
./identyclaw.sh restart agent-a agent-b
./identyclaw.sh test-a2a agent-a agent-b
./identyclaw.sh ask agent-a 'Verify any inbound HOLA with identyclaw_verify_hola; use a2a_send_message for peer agent-b'
```

See [`security-compliance-improvements.md`](security-compliance-improvements.md#a2a-agent-to-agent-communication-agent-a--agent-b) for RODiT JWT details and production ingress. For agents on **different machines**, follow [Cross-machine A2A (Option A)](security-compliance-improvements.md#cross-machine-a2a-option-a) (public HTTPS on **9443**).

### Agent A (configured — dedalo43 / Juanelo)

Onboarded 2026-05-23. Customer-support oriented setup with email + OpenRouter + DuckDuckGo (Spain). **Production pod** on dedalo43 (`IDENTYCLAW_DEPLOY_MODE=pod`).

| Setting | Value |
|---------|--------|
| State dir | `~/identyclaw-agents-app/agents/agent-a` |
| Container | `openclaw-agent-a` (in `identyclaw-agents-pod` with `identyclaw-nginx`) |
| Display name | Juanelo |
| Mailbox | `juanelo@agenthood.me` (Migadu) |
| **Ingress port (public)** | **9443** — `https://agent-a.identyclaw.com:9443` |
| Gateway port (pod-internal) | **18789** (UI/API), **18790** (bridge) — nginx upstream only |
| Control UI | `https://agent-a.identyclaw.com:9443/` (or `curl -sk -H 'Host: agent-a.identyclaw.com' https://127.0.0.1:9443/` until DNS is live) |
| A2A | `POST https://agent-a.identyclaw.com:9443/a2a` |
| Token | `./identyclaw.sh token agent-a` |
| Deploy mode | `pod` (`IDENTYCLAW_INGRESS_PORT=9443` in `env.local`) |
| Gateway bind | `lan` (reachable from nginx sidecar inside the pod) |
| Gateway auth | token |
| Model | `openrouter/x-ai/grok-4.3` (OpenRouter API key, no fallbacks) |
| Web search | DuckDuckGo, region **`es-es`**, SafeSearch off |
| Email skill | **himalaya** enabled (password via `set-password`) |
| Memory | `qmd` |
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
      "model": { "primary": "openrouter/x-ai/grok-4.3" }
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

Webhooks use the same ingress hostname — no extra port. On dedalo43 (pod): `POST https://agent-a.identyclaw.com:9443/hooks/wake` with **RODiT origin signature** (`x-signature` + `x-timestamp` via `@rodit/rodit-auth-be`) — same pattern as [`clienttest-idc`](../clienttest-idc). No `hooks.token` or HMAC. Standalone dev uses host port **18789**. See [Troubleshooting](#webhooks-and-port-conflicts-two-agents).

**Standalone dev** (other hosts or local loopback): `PUBLISH_HOST=127.0.0.1`, Control UI at `http://127.0.0.1:18789/`, `./identyclaw.sh start agent-a`.

**Fix OpenRouter auth** (if onboard saved a shell command instead of `sk-or-...`):

```bash
./identyclaw.sh set-api-key agent-a
./identyclaw.sh restart agent-a
```

### Agent B

Mirrors agent A’s setup (OpenRouter, DuckDuckGo `es-es`, himalaya, session-memory) on ports **18791/18792**.

| Setting | Value |
|---------|--------|
| State dir | `~/identyclaw-agents-app/agents/agent-b` |
| Container | `openclaw-agent-b` |
| Mailbox | `agent-b@identyclaw.com` (Migadu) |
| Gateway ports (host) | **18791** (UI/API), **18792** (bridge) |
| Control UI | http://127.0.0.1:18791/ |
| Token | `./identyclaw.sh token agent-b` |

**Fast setup (copy from agent A — no interactive onboard):**

```bash
cd ~/identyclaw-agents
./identyclaw.sh mirror agent-b agent-a
./identyclaw.sh restart agent-b
./identyclaw.sh set-password agent-b   # when Migadu password is ready
./identyclaw.sh test-mail agent-b
```

**CLI chat:** `./identyclaw.sh chat agent-b`

### Agent C

Mirrors agent A’s setup on ports **18793/18794**.

| Setting | Value |
|---------|--------|
| State dir | `~/identyclaw-agents-app/agents/agent-c` |
| Container | `openclaw-agent-c` |
| Mailbox | `agent-c@identyclaw.com` (Migadu — edit `env.local`) |
| Gateway ports (host) | **18793** (UI/API), **18794** (bridge) |
| Control UI | http://127.0.0.1:18793/ |
| Token | `./identyclaw.sh token agent-c` |

**Fast setup (copy from agent A):**

```bash
cd ~/identyclaw-agents
./identyclaw.sh init                    # creates agent-c dir if missing
./identyclaw.sh mirror agent-c agent-a
./identyclaw.sh restart agent-c
./identyclaw.sh set-password agent-c    # when Migadu password is ready
./identyclaw.sh test-mail agent-c
```

**CLI chat:** `./identyclaw.sh chat agent-c`

**Interactive onboard instead** (if you prefer the wizard over `mirror`):

## Troubleshooting

### `build-image`: Himalaya download 404

If the build log shows a URL like `.../releases/download//himalaya..tgz`, build-args were not applied in the image `RUN` step. The repo’s `Containerfile.himalaya` re-declares `ARG HIMALAYA_VERSION` and `ARG HIMALAYA_ARCH` **after** `FROM` so the correct asset is fetched (e.g. `himalaya.x86_64-linux.tgz` for amd64). Pull the latest repo and run `./identyclaw.sh build-image` again.

### `start`: tries to pull `registry.access.redhat.com/openclaw-himalaya:local`

On AlmaLinux / RHEL / CentOS, Podman `short-name-mode = "enforcing"` resolves bare image names to Red Hat’s registry. Use the fully qualified local name in `env.local`:

```bash
OPENCLAW_LOCAL_IMAGE=localhost/openclaw-himalaya:local
```

Then rebuild and start. Confirm the image exists:

```bash
podman images localhost/openclaw-himalaya
```

### `build-image` failed but `start` ran anyway

`start` only works after a successful `build-image`. If the Himalaya layer failed, fix the build first — do not rely on a partial `<none>` intermediate image.

### `test-mail`: Authentication failed

- Wrong or placeholder password in `~/identyclaw-agents-app/agents/agent-*/secrets/imap.pass`
- Mailbox not created in Migadu yet
- IMAP login must match `AGENT_*_EMAIL` in `env.local`

Fix: `./identyclaw.sh set-password agent-a` then `./identyclaw.sh restart all`.

### SMTP send: `535` or `cannot connect to smtp server using tls`

Migadu’s web UI lists **SMTP port 465 + TLS**. Himalaya in the OpenClaw image must use **`smtp.migadu.com:587`** with **`start-tls`** (see `scripts/lib.sh` → `write_himalaya_config`). Port 465 often hangs or fails auth even when IMAP on 993 works.

Also ensure:

- `message.send.backend.login` and `From:` match the mailbox (e.g. `juanelo@agenthood.me`)
- Password is in `~/identyclaw-agents-app/agents/agent-a/secrets/` via `./identyclaw.sh set-password agent-a` (do not paste passwords into `config.toml`)

Quick check: `./identyclaw.sh test-mail agent-a` (IMAP) then send with `sh scripts/himalaya-send.sh …` inside the container.

### `onboard`: Address already in use (port 18789 / 18791)

The running gateway already binds that agent’s port. Onboarding is a **CLI-only** wizard and does not need its own port mapping (fixed in current `identyclaw.sh`). Pull the latest script, or stop the agent first:

```bash
./identyclaw.sh stop agent-a
./identyclaw.sh onboard agent-a
./identyclaw.sh start agent-a
```

With the fixed script you can run `onboard` while `start all` is up.

### `onboard`: Too many arguments

`agent-a` / `agent-b` is for **this script** (which config dir to mount), not for `openclaw onboard`. Do not run `openclaw onboard agent-a` manually. Use:

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

Rebuild the image to bake in the symlink (`Containerfile.himalaya`):

```bash
./identyclaw.sh build-image
./identyclaw.sh restart all
```

If auth still fails after a real key is saved, check `~/identyclaw-agents-app/agents/agent-a/agents/main/agent/auth-profiles.json` — the `key` field must start with `sk-or-`, not a command like `cd ~/...`.

### Onboarding: systemd / gateway not detected

During `./identyclaw.sh onboard`, warnings about **systemd unavailable** or **Gateway ECONNREFUSED** are normal. Onboarding runs in a temporary container; the real gateway is the Podman container from `./identyclaw.sh start`. Do **not** install the OpenClaw systemd daemon on the host.

After onboarding:

```bash
./identyclaw.sh restart agent-a   # picks up config; applies --restart always
```

### Webhooks and port conflicts (two agents)

Each agent’s webhooks are HTTP paths on **that agent’s gateway** — they do not need separate ports. In **production pod** mode, external senders use HTTPS on the agent subdomain (not host ports 18789/18791/18793).

| Mode | agent-a webhook wake (example) |
|------|--------------------------------|
| Standalone dev | `http://127.0.0.1:18789/hooks/wake` |
| Production pod (main) | `https://agent-a.identyclaw.com:9443/hooks/wake` |

Keep `AGENT_*_GATEWAY_PORT` unique in `env.local`. Webhook senders **sign at origin** with RODiT/Passport credentials (`x-signature` + `x-timestamp`) — not the Control UI gateway token. External services must call the correct subdomain. See [Production ingress](#production-ingress-cicd--nginx-tls-sidecar) and `./identyclaw.sh webhook-url agent-a`.

### Run as `dedalo46`, not `root`

`init` / `start` / `onboard` expect rootless mode as your normal user. State lives under `~/identyclaw-agents-app/agents/agent-a` and `~/identyclaw-agents-app/agents/agent-b`. Use root only for `dnf install podman` or optional rootful mode above.

## Commands

| Command | Description |
|---------|-------------|
| `./identyclaw.sh build-image` | Pull GHCR OpenClaw 2026.5.27+ + Himalaya + Discord plugin layer |
| `./identyclaw.sh init` | Create `~/identyclaw-agents-app/agents/agent-a`, `~/identyclaw-agents-app/agents/agent-b`, and `~/identyclaw-agents-app/agents/agent-c` |
| `./identyclaw.sh set-password agent-a` | Store Migadu password locally |
| `./identyclaw.sh set-discord-token agent-a` | Store Discord bot token in `secrets/` (synced to `.env` on start) |
| `./identyclaw.sh set-api-key agent-a` | Store OpenRouter API key (`sk-or-...`) with validation |
| `./identyclaw.sh mirror agent-b` | Copy config + OpenRouter auth from agent-a to agent-b |
| `./identyclaw.sh configure agent-a` | Run `openclaw configure` in the gateway container |
| `./identyclaw.sh start all` | Start both containers |
| `./identyclaw.sh stop all` | Stop both |
| `./identyclaw.sh restart all` | Restart after password or config changes |
| `./identyclaw.sh enable-boot` | One-time: background + start both agents after reboot |
| `./identyclaw.sh test-mail agent-a` | Verify IMAP via Himalaya |
| `./identyclaw.sh logs agent-a` | Follow logs |
| `./identyclaw.sh token agent-a` | Print Control UI gateway token |
| `./identyclaw.sh chat agent-a` | Interactive terminal chat |
| `./identyclaw.sh ask agent-a "..."` | One-shot message to an agent |
| `./identyclaw.sh onboard agent-a` | Interactive OpenClaw setup (skips hatch TUI / health checks) |

## Production ingress (CI/CD + nginx TLS sidecar)

Production HTTPS ingress exists primarily for **A2A** (`POST /a2a`, agent-card discovery) and **OpenClaw webhooks** (`POST /hooks/wake`, `/hooks/agent`, custom `/hooks/<name>`). Control UI over the same hostname is optional for operators. Pattern matches [`clienttest-idc`](../clienttest-idc) (nginx TLS sidecar → HTTP upstream), with per-agent subdomains instead of one `webhook.*` host.

| Branch | Primary health host | Agent hosts |
|--------|---------------------|-------------|
| `development` | `agent-a.dihola.io:4443` | `agent-b.dihola.io`, `agent-c.dihola.io` |
| `main` | `agent-a.identyclaw.com:9443` | `agent-b.identyclaw.com`, `agent-c.identyclaw.com` |

Deploy layout: **nginx sidecar** on **9443** (main) or **4443** (development) — TLS, subdomain → gateway upstream — plus OpenClaw containers on pod-local ports 18789 / 18791 / 18793. See [`security-compliance-improvements.md`](security-compliance-improvements.md#production-ingress-cicd--nginx-tls-sidecar) for A2A/webhook URL tables and [`clienttest-idc`](../clienttest-idc) for the single-host webhook reference implementation.

### Webhook URLs (production)

Each agent has its own HTTPS base. External senders must hit the **correct subdomain** and include a **RODiT origin signature** (`x-signature` + `x-timestamp`):

| Agent (main) | Webhook wake | Webhook agent |
|--------------|--------------|---------------|
| agent-a | `https://agent-a.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |
| agent-b | `https://agent-b.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |
| agent-c | `https://agent-c.identyclaw.com:9443/hooks/wake` | `…/hooks/agent` |

Use `agent-*.dihola.io` on the development branch. Register the base URL in RODiT token metadata `webhook_url` (same field as [`clienttest-idc`](../clienttest-idc) uses for `https://webhook.discernible.io:7443`).

```bash
./identyclaw.sh webhook-url agent-a
./identyclaw.sh test-webhook agent-a    # expect 400/401 without RODiT x-signature
./identyclaw.sh status                  # ingress URLs in pod mode
```

Webhook auth matches [`clienttest-idc`](../clienttest-idc): **Ed25519 signed at origin** via `@rodit/rodit-auth-be` (`x-signature` + `x-timestamp` on the raw body). No shared `hooks.token`, no HMAC. Each agent needs `secrets/near-credentials/*.json` for verification. Register `webhook_url` in Passport metadata (base URL without path).

### Host bootstrap (once per environment)

On the deployment host as the SSH deploy user:

```bash
mkdir -p ../identyclaw-agents-app/{certs,logs,agents}
chmod 711 ../identyclaw-agents-app/certs

# Or: ./identyclaw.sh init  (creates app layout + env.local from env.example)
cp ~/identyclaw-agents/env.example ~/identyclaw-agents-app/env.local
chmod 600 ~/identyclaw-agents-app/env.local
# Set IDENTYCLAW_DEPLOY_MODE=pod, IDENTYCLAW_INGRESS_PORT, and AGENT_*_PUBLIC_HOST for your branch

# TLS — self-signed bootstrap (same pattern as clienttest-idc):
./identyclaw.sh generate-certs
# Writes ~/identyclaw-agents-app/certs/{fullchain.pem,privkey.pem} with SANs for
# AGENT_A/B/C_PUBLIC_HOST. RODiT JWT handles A2A/webhook mutual auth — CA-issued
# certs are optional. Replace with real PEMs when ready (infra/CERTIFICATE-MANAGEMENT.md).
```

Per-agent runtime state lives under `~/identyclaw-agents-app/agents/agent-{a,b,c}/`. Scripts resolve this automatically (`IDENTYCLAW_AGENT_STATE_ROOT` defaults to `${IDENTYCLAW_APP_DIR}/agents`). Initialize passwords and API keys with the usual commands:

```bash
./identyclaw.sh set-password agent-a
./identyclaw.sh set-api-key agent-a
```

### GitHub Actions

Workflow: [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)

Required repository secrets (same names as other IdentyClaw `-idc` repos): `SSH_HOST_MAIN`, `SSH_USER_MAIN`, `SSH_PRIVATE_KEY_MAIN`, `SSH_KNOWN_HOSTS_MAIN`, and the `*_DEVELOPMENT` variants, plus `GHCR_PULL_TOKEN`.

Push to `main` or `development` to build and deploy. Images are tagged `<commit-sha>-main` or `<commit-sha>-development` so development and main tiers do not overwrite each other on GHCR. Health check probes `https://<DOMAIN>:9443/health` (main) or `:4443/health` (development) — advisory; may fail from the runner while the pod is healthy on the host).

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
~/identyclaw-agents-app/agents/agent-a/
  openclaw.json
  .env                    # OPENCLAW_GATEWAY_TOKEN
  workspace/
  .config/himalaya/config.toml
  secrets/imap.pass       # never commit
  secrets/imap.sh         # auth helper for Himalaya

~/identyclaw-agents-app/agents/agent-b/      # same structure

~/identyclaw-agents-app/agents/agent-c/      # same structure
```

## Host CLI (optional)

```bash
export OPENCLAW_CONTAINER=openclaw-agent-a
export OPENCLAW_CONFIG_DIR=$HOME/identyclaw-agents-app/agents/agent-a
openclaw doctor
```
