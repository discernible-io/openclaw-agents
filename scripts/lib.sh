#!/usr/bin/env bash
set -euo pipefail

IDENTYCLAW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  local f="$IDENTYCLAW_ROOT/env.local"
  if [[ ! -f "$f" ]]; then
    f="$IDENTYCLAW_ROOT/env.example"
  fi
  if [[ -f "$f" ]]; then
    # Parse KEY=VALUE safely (supports quoted values with spaces).
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
      [[ "$line" == *"="* ]] || continue
      local key="${line%%=*}"
      local value="${line#*=}"
      key="${key%"${key##*[![:space:]]}"}"
      key="${key#"${key%%[![:space:]]*}"}"
      if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
      fi
      case "$key" in
        OPENCLAW_*|HIMALAYA_*|AGENT_*|PUBLISH_HOST|IDENTYCLAW_*) printf -v "$key" '%s' "$value" ;;
      esac
    done <"$f"
  fi
  OPENCLAW_BASE_IMAGE="${OPENCLAW_BASE_IMAGE:-ghcr.io/openclaw/openclaw:2026.5.27-slim}"
  OPENCLAW_BUNDLED_PLUGINS="${OPENCLAW_BUNDLED_PLUGINS:-@openclaw/discord}"
  OPENCLAW_LOCAL_IMAGE="${OPENCLAW_LOCAL_IMAGE:-localhost/openclaw-himalaya:local}"
  HIMALAYA_VERSION="${HIMALAYA_VERSION:-v1.2.0}"
  PUBLISH_HOST="${PUBLISH_HOST:-127.0.0.1}"
  AGENT_A_EMAIL="${AGENT_A_EMAIL:-agent-a@identyclaw.com}"
  AGENT_B_EMAIL="${AGENT_B_EMAIL:-agent-b@identyclaw.com}"
  AGENT_A_DISPLAY_NAME="${AGENT_A_DISPLAY_NAME:-Identyclaw Agent A}"
  AGENT_B_DISPLAY_NAME="${AGENT_B_DISPLAY_NAME:-Identyclaw Agent B}"
  AGENT_A_GATEWAY_PORT="${AGENT_A_GATEWAY_PORT:-18789}"
  AGENT_A_BRIDGE_PORT="${AGENT_A_BRIDGE_PORT:-18790}"
  AGENT_B_GATEWAY_PORT="${AGENT_B_GATEWAY_PORT:-18791}"
  AGENT_B_BRIDGE_PORT="${AGENT_B_BRIDGE_PORT:-18792}"
  AGENT_C_EMAIL="${AGENT_C_EMAIL:-agent-c@identyclaw.com}"
  AGENT_C_DISPLAY_NAME="${AGENT_C_DISPLAY_NAME:-Identyclaw Agent C}"
  AGENT_C_GATEWAY_PORT="${AGENT_C_GATEWAY_PORT:-18793}"
  AGENT_C_BRIDGE_PORT="${AGENT_C_BRIDGE_PORT:-18794}"
  # Gateway always listens on this port inside the container (see identyclaw.sh start_one).
  OPENCLAW_CONTAINER_GATEWAY_PORT="${OPENCLAW_CONTAINER_GATEWAY_PORT:-18789}"
}

detect_himalaya_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) echo "x86_64-linux" ;;
    aarch64|arm64) echo "aarch64-linux" ;;
    armv7l) echo "armv7l-linux" ;;
    i686|i386) echo "i686-linux" ;;
    *) echo "ERROR: unsupported CPU for Himalaya binary: $machine" >&2; exit 1 ;;
  esac
}

agent_home() {
  local id="$1"
  echo "${IDENTYCLAW_STATE_DIR:-$HOME}/.openclaw-${id}"
}

agent_container() {
  echo "openclaw-${1}"
}

agent_display_name() {
  load_env
  case "$1" in
    agent-a) echo "$AGENT_A_DISPLAY_NAME" ;;
    agent-b) echo "$AGENT_B_DISPLAY_NAME" ;;
    agent-c) echo "$AGENT_C_DISPLAY_NAME" ;;
    *) echo "$1" ;;
  esac
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(32))'
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

selinux_mount_suffix() {
  if [[ "$(uname -s)" == "Linux" ]] && command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce 2>/dev/null || true)"
    if [[ "$mode" == "Enforcing" || "$mode" == "Permissive" ]]; then
      echo ",Z"
      return
    fi
  fi
  echo ""
}

podman_runtime_args() {
  # ROOTLESS (default): maps host uid/gid into container
  if [[ "${IDENTYCLAW_ROOTLESS:-1}" == "1" ]]; then
    echo --userns=keep-id --user "$(id -u):$(id -g)"
  else
    # ROOTFUL: runs as image user (node). Ensure host dirs are readable.
    echo ""
  fi
}

write_himalaya_config() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  mkdir -p "$config_dir/.config/himalaya"
  cat >"$config_dir/.config/himalaya/config.toml" <<EOF
[accounts.default]
email = "${email}"
display-name = "${display_name}"
default = true

backend.type = "imap"
backend.host = "imap.migadu.com"
backend.port = 993
backend.encryption.type = "tls"
backend.login = "${email}"
backend.auth.type = "password"
backend.auth.cmd = "/home/node/.openclaw/secrets/imap.sh"

message.send.backend.type = "smtp"
message.send.backend.host = "smtp.migadu.com"
message.send.backend.port = 587
message.send.backend.encryption.type = "start-tls"
message.send.backend.login = "${email}"
message.send.backend.auth.type = "password"
message.send.backend.auth.cmd = "/home/node/.openclaw/secrets/smtp.sh"

[accounts.default.folder.alias]
inbox = "INBOX"
sent = "Sent"
drafts = "Drafts"
trash = "Trash"
EOF
  chmod 600 "$config_dir/.config/himalaya/config.toml"
}

write_himalaya_send_script() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  mkdir -p "$config_dir/workspace/scripts"
  cat >"$config_dir/workspace/scripts/himalaya-send.sh" <<EOF
#!/bin/sh
# Headless outbound mail via Himalaya (no \$EDITOR). Containers have no editor binary.
# Usage: sh scripts/himalaya-send.sh TO SUBJECT [BODY]
set -eu
TO="\${1:?usage: himalaya-send.sh TO SUBJECT [BODY]}"
SUBJECT="\${2:?usage: himalaya-send.sh TO SUBJECT [BODY]}"
BODY="\${3:-}"

himalaya message send <<MAIL
From: ${display_name} <${email}>
To: \${TO}
Subject: \${SUBJECT}

\${BODY}
MAIL
EOF
  chmod 755 "$config_dir/workspace/scripts/himalaya-send.sh"
}

write_agent_email_doc() {
  local email="$1"
  local display_name="$2"
  local config_dir="$3"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/EMAIL.md" <<EOF
# Email (Himalaya / Migadu)

- **Account:** \`${email}\` (${display_name})
- **Config:** \`/home/node/.config/himalaya/config.toml\`
- **IMAP/SMTP:** Migadu (\`imap.migadu.com:993\`, \`smtp.migadu.com:587\`)

## Read inbox

\`\`\`bash
himalaya envelope list --page-size 10
himalaya message read <ID>
\`\`\`

## Send (headless — required in this container)

There is **no \`\$EDITOR\`** in the gateway container, so \`himalaya message write\` always fails.
Use the helper or raw send:

\`\`\`bash
sh scripts/himalaya-send.sh recipient@example.com "Subject" "Body"
\`\`\`

Or:

\`\`\`bash
himalaya message send <<MAIL
From: ${display_name} <${email}>
To: recipient@example.com
Subject: Your subject

Your body
MAIL
\`\`\`

**Critical:** \`From:\` must be \`${email}\`. Migadu rejects other senders (553 *Sender address rejected*).
EOF
  chmod 644 "$config_dir/workspace/EMAIL.md"
}

agent_mailbox() {
  local id="$1"
  load_env
  case "$id" in
    agent-a) echo "${AGENT_A_EMAIL}|${AGENT_A_DISPLAY_NAME}" ;;
    agent-b) echo "${AGENT_B_EMAIL}|${AGENT_B_DISPLAY_NAME}" ;;
    agent-c) echo "${AGENT_C_EMAIL}|${AGENT_C_DISPLAY_NAME}" ;;
    *) echo "unknown agent: $id" >&2; return 1 ;;
  esac
}

ensure_mail_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local password=""
  load_env
  case "$id" in
    agent-a) password="${AGENT_A_PASSWORD:-}" ;;
    agent-b) password="${AGENT_B_PASSWORD:-}" ;;
    agent-c) password="${AGENT_C_PASSWORD:-}" ;;
  esac
  if [[ -n "$password" ]] && [[ ! -f "$config_dir/secrets/imap.pass" ]]; then
    write_secret_helpers "$config_dir" "$password"
    echo "    (${id}: Migadu password loaded from env.local → secrets/)" >&2
  fi
}

ensure_agent_email_tooling() {
  local id="$1"
  local config_dir="$2"
  local mailbox email display_name
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  write_himalaya_send_script "$email" "$display_name" "$config_dir"
  write_agent_email_doc "$email" "$display_name" "$config_dir"
}

ensure_discord_guild_channels() {
  local config_dir="$1"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict):
    raise SystemExit(0)

guild_id = "1509561171961708554"
channel_id = "1509561172725334058"
owner_id = "1438122032968634408"
changed = False

guilds = discord.setdefault("guilds", {})
guild = guilds.setdefault(guild_id, {})
if guild.get("requireMention") is not False:
    guild["requireMention"] = False
    changed = True
if guild.get("ignoreOtherMentions") is not True:
    guild["ignoreOtherMentions"] = True
    changed = True
users = guild.setdefault("users", [])
if owner_id not in users:
    users.append(owner_id)
    changed = True
channels = guild.setdefault("channels", {})
ch = channels.setdefault(channel_id, {})
if ch.get("enabled") is not True:
    ch["enabled"] = True
    changed = True
if ch.get("requireMention") is not False:
    ch["requireMention"] = False
    changed = True
if ch.get("ignoreOtherMentions") is not True:
    ch["ignoreOtherMentions"] = True
    changed = True

allow_from = discord.setdefault("allowFrom", [])
if owner_id not in allow_from:
    allow_from.append(owner_id)
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

ensure_discord_ready() {
  local id="$1"
  local config_dir="$2"
  local config="$config_dir/openclaw.json"
  local token_file="$config_dir/secrets/DISCORD_BOT_TOKEN"
  [[ -f "$config" ]] || return 0
  python3 - "$config" "$token_file" <<'PY'
import json, sys
from pathlib import Path

path, token_file = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict):
    raise SystemExit(0)

has_token = token_file.is_file() and token_file.read_text(encoding="utf-8").strip()
enabled = discord.get("enabled", False)
changed = False

if enabled and not has_token:
    discord["enabled"] = False
    changed = True
    print(f"WARNING: {path.parent.name}: Discord enabled but no token — disabled until ./identyclaw.sh set-discord-token {path.parent.name.replace('.openclaw-', '')}", file=sys.stderr)
elif not enabled and has_token:
    discord["enabled"] = True
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

ensure_agent_bootstrap() {
  local id="$1"
  local config_dir="$2"
  ensure_mail_secrets_from_env "$id" "$config_dir"
  ensure_agent_email_tooling "$id" "$config_dir"
  ensure_discord_guild_channels "$config_dir"
  ensure_discord_ready "$id" "$config_dir"
  if [[ ! -f "$config_dir/secrets/imap.pass" ]]; then
    echo "Note: ${id} has no Migadu password yet — run: ./identyclaw.sh set-password ${id}" >&2
  fi
}

write_secret_helpers() {
  local config_dir="$1"
  local password="$2"
  mkdir -p "$config_dir/secrets"
  printf '%s\n' "$password" >"$config_dir/secrets/imap.pass"
  cp "$config_dir/secrets/imap.pass" "$config_dir/secrets/smtp.pass"
  cat >"$config_dir/secrets/imap.sh" <<'EOF'
#!/bin/sh
cat /home/node/.openclaw/secrets/imap.pass
EOF
  cp "$config_dir/secrets/imap.sh" "$config_dir/secrets/smtp.sh"
  chmod 700 "$config_dir/secrets"
  chmod 700 "$config_dir/secrets"/*.sh
  chmod 600 "$config_dir/secrets"/*.pass
}

write_discord_token() {
  local config_dir="$1"
  local token="$2"
  [[ -n "$token" ]] || { echo "empty Discord bot token" >&2; return 1; }
  mkdir -p "$config_dir/secrets"
  printf '%s' "$token" >"$config_dir/secrets/DISCORD_BOT_TOKEN"
  chmod 600 "$config_dir/secrets/DISCORD_BOT_TOKEN"
  sync_discord_env "$config_dir"
  python3 - "$config_dir/openclaw.json" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.setdefault("channels", {}).setdefault("discord", {})
if not discord.get("enabled"):
    discord["enabled"] = True
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

# Gateway reads DISCORD_BOT_TOKEN from --env-file; keep .env in sync with secrets/.
sync_discord_env() {
  local config_dir="$1"
  local secret_file="$config_dir/secrets/DISCORD_BOT_TOKEN"
  local env_file="$config_dir/.env"
  [[ -f "$secret_file" ]] || return 0
  local token
  token="$(<"$secret_file")"
  [[ -n "$token" ]] || return 0
  python3 - "$env_file" "$token" <<'PY'
import sys, os
path, token = sys.argv[1], sys.argv[2]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith("DISCORD_BOT_TOKEN=")]
lines.append(f"DISCORD_BOT_TOKEN={token}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}

# Let @Juanelo / @Archimedes reach the other gateway when a bot message @mentions them.
# Keep rootless agents running after logout (linger) and across reboot (podman-restart).
ensure_agent_persistence() {
  local user linger
  user="$(whoami)"
  linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
  if [[ "$linger" != "yes" ]]; then
    echo "Note: agents may stop when you log out. Run once: ./identyclaw.sh enable-boot (enables linger; needs sudo)" >&2
    return 0
  fi
  if ! systemctl --user is-enabled podman-restart.service &>/dev/null; then
    echo "Enabling podman-restart.service (starts --restart always containers after reboot)..."
    systemctl --user enable --now podman-restart.service
  fi
}

ensure_discord_allow_bots_mentions() {
  local config_dir="$1"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict) or not discord.get("enabled"):
    raise SystemExit(0)
if discord.get("allowBots") == "mentions":
    raise SystemExit(0)
data.setdefault("channels", {}).setdefault("discord", {})["allowBots"] = "mentions"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}

ensure_internal_gateway_port() {
  local config_dir="$1"
  local host_gateway_port="$2"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  load_env
  python3 - "$config" "$host_gateway_port" "$OPENCLAW_CONTAINER_GATEWAY_PORT" <<'PY'
import json, sys
from pathlib import Path

path, host_port, internal_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = json.loads(Path(path).read_text(encoding="utf-8"))
gateway = data.setdefault("gateway", {})
changed = False
if gateway.get("port") != internal_port:
    gateway["port"] = internal_port
    changed = True
origins = gateway.setdefault("controlUi", {}).setdefault("allowedOrigins", [])
for origin in (
    f"http://127.0.0.1:{host_port}",
    f"http://localhost:{host_port}",
    f"http://127.0.0.1:{internal_port}",
    f"http://localhost:{internal_port}",
):
    if origin not in origins:
        origins.append(origin)
        changed = True
if changed:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    Path(path).chmod(0o600)
PY
}

write_openclaw_json() {
  local config_dir="$1"
  local gateway_port="$2"
  if [[ -f "$config_dir/openclaw.json" ]]; then
    return 0
  fi
  load_env
  cat >"$config_dir/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_CONTAINER_GATEWAY_PORT},
    "controlUi": {
      "allowedOrigins": [
        "http://127.0.0.1:${gateway_port}",
        "http://localhost:${gateway_port}"
      ]
    }
  },
  "skills": {
    "entries": {
      "himalaya": { "enabled": true }
    }
  },
  "tools": {
    "allow": [
      "exec",
      "read",
      "write",
      "edit",
      "message",
      "browser",
      "sessions_list",
      "sessions_history",
      "sessions_send"
    ]
  },
  "plugins": {
    "entries": {
      "browser": {
        "enabled": true
      },
      "discord": {
        "enabled": true
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "models": {
        "openrouter/x-ai/grok-4.3": {}
      },
      "model": {
        "primary": "openrouter/x-ai/grok-4.3"
      }
    }
  },
  "memory": {
    "backend": "qmd"
  }
}
EOF
  chmod 600 "$config_dir/openclaw.json"
}

ensure_agent_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  if [[ -f "$env_file" ]] && grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$env_file" 2>/dev/null; then
    return 0
  fi
  local token
  token="$(generate_token)"
  mkdir -p "$config_dir"
  if [[ -f "$env_file" ]]; then
    grep -v '^OPENCLAW_GATEWAY_TOKEN=' "$env_file" >"$env_file.tmp" || true
    mv "$env_file.tmp" "$env_file"
  fi
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$token" >>"$env_file"
  chmod 600 "$env_file"
}

ensure_openclaw_cli_link() {
  local container="$1"
  podman exec -u 0 "$container" ln -sf /app/openclaw.mjs /openclaw.mjs 2>/dev/null || true
}

validate_openrouter_api_key() {
  local key="$1"
  [[ "$key" == sk-or-* ]] || {
    echo "OpenRouter API keys start with sk-or- (got something else — check you did not paste a shell command)." >&2
    return 1
  }
}

write_openrouter_api_key() {
  local config_dir="$1"
  local key="$2"
  local agent_dir="$config_dir/agents/main/agent"
  validate_openrouter_api_key "$key"
  mkdir -p "$agent_dir"
  python3 - "$agent_dir/auth-profiles.json" "$key" <<'PY'
import json, sys, os
path, key = sys.argv[1], sys.argv[2]
data = {
    "version": 1,
    "profiles": {
        "openrouter:default": {
            "type": "api_key",
            "provider": "openrouter",
            "key": key,
        }
    },
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
  printf '{"version":1,"usageStats":{}}\n' >"$agent_dir/auth-state.json"
  chmod 600 "$agent_dir/auth-state.json"
}

mirror_agent_config() {
  local from_id="$1"
  local to_id="$2"
  local from_dir to_dir gw token
  from_dir="$(agent_home "$from_id")"
  to_dir="$(agent_home "$to_id")"
  [[ -f "$from_dir/openclaw.json" ]] || { echo "Missing source config: $from_dir/openclaw.json" >&2; exit 1; }
  [[ -d "$to_dir" ]] || { echo "Missing target dir: $to_dir (run init)" >&2; exit 1; }
  read -r gw _ < <(agent_ports "$to_id")
  token="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$to_dir/.env" | cut -d= -f2-)"
  [[ -n "$token" ]] || { echo "Missing OPENCLAW_GATEWAY_TOKEN in $to_dir/.env" >&2; exit 1; }

  if [[ -f "$from_dir/agents/main/agent/auth-profiles.json" ]]; then
    mkdir -p "$to_dir/agents/main/agent"
    cp "$from_dir/agents/main/agent/auth-profiles.json" "$to_dir/agents/main/agent/auth-profiles.json"
    chmod 600 "$to_dir/agents/main/agent/auth-profiles.json"
    printf '{"version":1,"usageStats":{}}\n' >"$to_dir/agents/main/agent/auth-state.json"
    chmod 600 "$to_dir/agents/main/agent/auth-state.json"
  fi

  python3 - "$from_dir/openclaw.json" "$to_dir/openclaw.json" "$gw" "$token" <<'PY'
import json, sys
from pathlib import Path

src_path, dst_path, host_gw_port, token = sys.argv[1:5]
host_gw_port = int(host_gw_port)
internal_gw_port = 18789
data = json.loads(Path(src_path).read_text(encoding="utf-8"))

gateway = data.setdefault("gateway", {})
gateway["port"] = internal_gw_port
gateway.setdefault("auth", {})["mode"] = gateway.get("auth", {}).get("mode", "token")
gateway["auth"]["token"] = token
gateway["bind"] = gateway.get("bind", "loopback")
gateway.setdefault("controlUi", {})["allowedOrigins"] = [
    f"http://127.0.0.1:{host_gw_port}",
    f"http://localhost:{host_gw_port}",
    f"http://127.0.0.1:{internal_gw_port}",
    f"http://localhost:{internal_gw_port}",
]

# Migrate auth profiles from anthropic to openrouter
auth = data.get("auth", {})
profiles = auth.get("profiles", {})
if "anthropic:default" in profiles:
    profiles["openrouter:default"] = {"provider": "openrouter", "mode": "api_key"}
    del profiles["anthropic:default"]
    auth["profiles"] = profiles
    data["auth"] = auth

# Migrate plugins
plugins = data.get("plugins", {}).get("entries", {})
if "anthropic" in plugins:
    plugins["openrouter"] = plugins.pop("anthropic")
    data["plugins"]["entries"] = plugins

# Update model to use openrouter prefix
agents = data.get("agents", {})
defaults = agents.get("defaults", {})
model = defaults.get("model", {})
primary = model.get("primary", "")
if primary.startswith("anthropic/"):
    model["primary"] = "openrouter/" + primary
    defaults["model"] = model
    agents["defaults"] = defaults
    data["agents"] = agents

discord = data.get("channels", {}).get("discord")
if isinstance(discord, dict) and discord.get("enabled"):
    discord["allowBots"] = "mentions"

Path(dst_path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
Path(dst_path).chmod(0o600)
PY

  echo "Mirrored ${from_id} → ${to_id} (gateway port ${gw}, auth + openclaw.json)"
}
