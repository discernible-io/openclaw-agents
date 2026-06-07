# Identyclaw OpenClaw (Podman)

Three isolated OpenClaw gateways with Himalaya + Migadu (`identyclaw.com`).

## Prerequisites

- Podman (rootless recommended). On AlmaLinux / RHEL / Fedora:

  ```bash
  sudo dnf install -y podman
  ```

- Optional: `openclaw` CLI on the host for advanced management
- Migadu mailboxes: `agent-a@identyclaw.com`, `agent-b@identyclaw.com` (or edit `env.local`)

Mailbox passwords are **not** required for `init`, `build-image`, or `start` — you can add them later (see [Set email passwords later](#set-email-passwords-later)).

## Quick start (rootless — recommended)

Run as your normal user (not `root`):

```bash
cd ~/identyclaw-openclaw
cp env.example env.local
chmod 600 env.local
# Edit env.local: emails, display names, ports (passwords optional here)

chmod +x identyclaw.sh
./identyclaw.sh init
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

- Agent A UI: http://127.0.0.1:18789/ — token: `./identyclaw.sh token agent-a`
- Agent B UI: http://127.0.0.1:18791/ — token: `./identyclaw.sh token agent-b`

See [Accessing agents (CLI and browser)](#accessing-agents-cli-and-browser) for terminal chat and remote laptop access.

## Accessing agents (CLI and browser)

By default gateways bind to **`127.0.0.1`** only (`PUBLISH_HOST=127.0.0.1` in `env.local`). That means they are reachable on the **server**, not directly from a remote laptop, unless you use an SSH tunnel or change the publish bind (below).

### Chat via CLI (no browser)

Interactive terminal chat on the **server** (SSH session as your normal user). No loopback HTTP from your laptop required.

**Interactive chat** (easiest):

```bash
cd ~/identyclaw-openclaw
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
cd ~/identyclaw-openclaw
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
cd ~/identyclaw-openclaw
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
cd ~/identyclaw-openclaw
./identyclaw.sh chat agent-a
```

### Remote browser — public IP (optional)

Only if you intentionally want the Control UI on the internet. Prefer HTTPS via a reverse proxy in production; raw HTTP + token is risky.

**1. Publish on all interfaces** — in `env.local`:

```bash
PUBLISH_HOST=0.0.0.0
```

**2. Allow your origin** — in `~/.openclaw-agent-a/openclaw.json` (and agent B on 18791):

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
cd ~/identyclaw-openclaw
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
# Set passwords and start as root; state under /root/.openclaw-agent-*
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
cd ~/identyclaw-openclaw
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
cd ~/identyclaw-openclaw
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

Each agent has isolated state under `~/.openclaw-agent-a` and `~/.openclaw-agent-b`. Host ports come from `env.local`; OpenClaw settings live in each agent’s `openclaw.json`.

**Never commit or paste gateway tokens or API keys.** Use `./identyclaw.sh token agent-a` when you need the Control UI token.

### Agent A (configured)

Onboarded 2026-05-23. Customer-support oriented setup with email + OpenRouter + DuckDuckGo (Spain).

| Setting | Value |
|---------|--------|
| State dir | `~/.openclaw-agent-a` |
| Container | `openclaw-agent-a` |
| Mailbox | `agent-a@identyclaw.com` (Migadu) |
| Gateway ports (host) | **18789** (UI/API), **18790** (bridge) |
| Control UI | http://127.0.0.1:18789/ |
| Token | `./identyclaw.sh token agent-a` |
| Publish bind | `127.0.0.1` (`PUBLISH_HOST` in `env.local`) |
| Gateway bind | loopback (localhost only) |
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
    "bind": "loopback",
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

Webhooks (if added later) share the gateway port — no extra port. Use agent A’s host port **18789** and a dedicated `hooks.token` (not the Control UI token). See [Troubleshooting](#webhooks-and-port-conflicts-two-agents).

**Fix OpenRouter auth** (if onboard saved a shell command instead of `sk-or-...`):

```bash
./identyclaw.sh set-api-key agent-a
./identyclaw.sh restart agent-a
```

### Agent B

Mirrors agent A’s setup (OpenRouter, DuckDuckGo `es-es`, himalaya, session-memory) on ports **18791/18792**.

| Setting | Value |
|---------|--------|
| State dir | `~/.openclaw-agent-b` |
| Container | `openclaw-agent-b` |
| Mailbox | `agent-b@identyclaw.com` (Migadu) |
| Gateway ports (host) | **18791** (UI/API), **18792** (bridge) |
| Control UI | http://127.0.0.1:18791/ |
| Token | `./identyclaw.sh token agent-b` |

**Fast setup (copy from agent A — no interactive onboard):**

```bash
cd ~/identyclaw-openclaw
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
| State dir | `~/.openclaw-agent-c` |
| Container | `openclaw-agent-c` |
| Mailbox | `agent-c@identyclaw.com` (Migadu — edit `env.local`) |
| Gateway ports (host) | **18793** (UI/API), **18794** (bridge) |
| Control UI | http://127.0.0.1:18793/ |
| Token | `./identyclaw.sh token agent-c` |

**Fast setup (copy from agent A):**

```bash
cd ~/identyclaw-openclaw
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

- Wrong or placeholder password in `~/.openclaw-agent-*/secrets/imap.pass`
- Mailbox not created in Migadu yet
- IMAP login must match `AGENT_*_EMAIL` in `env.local`

Fix: `./identyclaw.sh set-password agent-a` then `./identyclaw.sh restart all`.

### SMTP send: `535` or `cannot connect to smtp server using tls`

Migadu’s web UI lists **SMTP port 465 + TLS**. Himalaya in the OpenClaw image must use **`smtp.migadu.com:587`** with **`start-tls`** (see `scripts/lib.sh` → `write_himalaya_config`). Port 465 often hangs or fails auth even when IMAP on 993 works.

Also ensure:

- `message.send.backend.login` and `From:` match the mailbox (e.g. `juanelo@agenthood.me`)
- Password is in `~/.openclaw-agent-a/secrets/` via `./identyclaw.sh set-password agent-a` (do not paste passwords into `config.toml`)

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

If auth still fails after a real key is saved, check `~/.openclaw-agent-a/agents/main/agent/auth-profiles.json` — the `key` field must start with `sk-or-`, not a command like `cd ~/...`.

### Onboarding: systemd / gateway not detected

During `./identyclaw.sh onboard`, warnings about **systemd unavailable** or **Gateway ECONNREFUSED** are normal. Onboarding runs in a temporary container; the real gateway is the Podman container from `./identyclaw.sh start`. Do **not** install the OpenClaw systemd daemon on the host.

After onboarding:

```bash
./identyclaw.sh restart agent-a   # picks up config; applies --restart always
```

### Webhooks and port conflicts (two agents)

Each agent’s webhooks are HTTP paths on **that agent’s gateway port** — they do not need separate ports.

| Agent | Webhook base (example) |
|-------|-------------------------|
| agent-a | `http://127.0.0.1:18789/hooks/...` |
| agent-b | `http://127.0.0.1:18791/hooks/...` |

Keep `AGENT_*_GATEWAY_PORT` unique in `env.local`. Use a **separate `hooks.token` per agent** (not the Control UI token). External services (Telegram, Zapier, etc.) must call the correct port or subdomain.

### Run as `dedalo46`, not `root`

`init` / `start` / `onboard` expect rootless mode as your normal user. State lives under `~/.openclaw-agent-a` and `~/.openclaw-agent-b`. Use root only for `dnf install podman` or optional rootful mode above.

## Commands

| Command | Description |
|---------|-------------|
| `./identyclaw.sh build-image` | Pull GHCR OpenClaw 2026.5.27+ + Himalaya + Discord plugin layer |
| `./identyclaw.sh init` | Create `~/.openclaw-agent-a`, `~/.openclaw-agent-b`, and `~/.openclaw-agent-c` |
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

## State layout

```
~/.openclaw-agent-a/
  openclaw.json
  .env                    # OPENCLAW_GATEWAY_TOKEN
  workspace/
  .config/himalaya/config.toml
  secrets/imap.pass       # never commit
  secrets/imap.sh         # auth helper for Himalaya

~/.openclaw-agent-b/      # same structure

~/.openclaw-agent-c/      # same structure
```

## Host CLI (optional)

```bash
export OPENCLAW_CONTAINER=openclaw-agent-a
export OPENCLAW_CONFIG_DIR=$HOME/.openclaw-agent-a
openclaw doctor
```
