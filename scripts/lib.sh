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
        "openrouter/x-ai/grok-4.3": {},
        "openrouter/qwen/qwen3.6-max-preview": {},
        "openrouter/z-ai/glm-5.1": {},
        "openrouter/moonshotai/kimi-k2.6": {}
      },
      "model": {
        "primary": "openrouter/x-ai/grok-4.3",
        "fallbacks": [
          "openrouter/qwen/qwen3.6-max-preview",
          "openrouter/z-ai/glm-5.1",
          "openrouter/moonshotai/kimi-k2.6"
        ]
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

Path(dst_path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
Path(dst_path).chmod(0o600)
PY

  echo "Mirrored ${from_id} → ${to_id} (gateway port ${gw}, auth + openclaw.json)"
}
