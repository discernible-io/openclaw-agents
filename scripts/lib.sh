#!/usr/bin/env bash
set -euo pipefail

IDENTYCLAW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Runtime config and agent state live under IDENTYCLAW_APP_DIR (never in the git checkout).
# Default: sibling ../identyclaw-agents-app next to the repo clone (peer-coordinated layout).
identyclaw_app_dir() {
  if [[ -n "${IDENTYCLAW_APP_DIR:-}" ]]; then
    printf '%s' "$IDENTYCLAW_APP_DIR"
    return 0
  fi
  printf '%s' "$(cd "${IDENTYCLAW_ROOT}/.." && pwd)/identyclaw-agents-app"
}

identyclaw_env_file() {
  echo "$(identyclaw_app_dir)/env.local"
}

# Mirrors .github/workflows/deploy.yml tier mapping:
# refs/heads/main -> main; any other branch (e.g. development) -> development.
resolve_deploy_tier() {
  local repo_root="${1:-${IDENTYCLAW_ROOT}}"
  local image_ref="${2:-${OPENCLAW_IMAGE:-}}"

  if [[ -n "${TARGET:-}" ]]; then
    printf '%s' "$TARGET"
    return 0
  fi
  if [[ -n "${DEPLOY_TIER:-}" ]]; then
    printf '%s' "$DEPLOY_TIER"
    return 0
  fi
  if [[ -n "$image_ref" ]]; then
    if [[ "$image_ref" =~ :[^/]+-main$ ]]; then
      printf 'main'
      return 0
    fi
    if [[ "$image_ref" =~ :[^/]+-development$ ]]; then
      printf 'development'
      return 0
    fi
  fi
  if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local branch
    branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$branch" == "main" ]]; then
      printf 'main'
    else
      printf 'development'
    fi
    return 0
  fi
  printf 'development'
}

deploy_tier_app_port() {
  case "$1" in
    development) printf '4443' ;;
    main) printf '9443' ;;
    *) return 1 ;;
  esac
}

deploy_tier_health_domain() {
  local id host
  load_env
  for id in $AGENT_IDS; do
    host="$(agent_public_host "$id")"
    [[ -n "$host" ]] && { printf '%s' "$host"; return 0; }
  done
  case "$1" in
    development) printf 'agent-a.dev.identyclaw.com' ;;
    main) printf 'agent-a.identyclaw.com' ;;
    *) return 1 ;;
  esac
}

# Post-deploy health probe: first AGENT_IDS host + ingress port from env.local.
deploy_health_ingress() {
  local id host port
  load_env
  for id in ${AGENT_IDS:-agent-a}; do
    host="$(agent_public_host "$id")"
    port="$(agent_ingress_port "$id")"
    if [[ -n "$host" && -n "$port" ]]; then
      printf '%s %s' "$host" "$port"
      return 0
    fi
  done
  printf '%s %s' "$(deploy_tier_health_domain development)" "$(deploy_tier_app_port development)"
}

deploy_tier_nginx_build_env() {
  case "${1:-development}" in
    development) printf 'development' ;;
    main) printf 'main' ;;
    *) return 1 ;;
  esac
}

ensure_app_layout() {
  local app env_file
  app="$(identyclaw_app_dir)"
  env_file="${app}/env.local"
  mkdir -p "${app}"/{certs,logs/nginx,agents,exports}
  chmod 711 "${app}/certs" 2>/dev/null || true
  if [[ ! -f "$env_file" ]]; then
    cp "${IDENTYCLAW_ROOT}/env.example" "$env_file"
    chmod 600 "$env_file"
    echo "Created ${env_file} from env.example"
  fi
}

# Bootstrap TLS for nginx when no CA-issued certs are installed.
# RODiT JWT handles mutual auth on A2A/webhooks; self-signed PEMs encrypt transport only.
ensure_tls_certs() {
  local force="${1:-}"
  local cert_dir extra_sans args=()
  ensure_app_layout
  load_env
  cert_dir="$(identyclaw_app_dir)/certs"
  extra_sans=""
  local h id
  for id in ${AGENT_IDS:-agent-a}; do
    h="$(agent_public_host "$id")"
    [[ -n "$h" ]] || continue
    [[ -n "$extra_sans" ]] && extra_sans+=","
    extra_sans+="DNS:${h}"
  done
  if [[ -n "${AGENT_B_INGRESS_ALT_HOST:-}" ]]; then
    extra_sans="${extra_sans},DNS:${AGENT_B_INGRESS_ALT_HOST}"
  fi
  case "$force" in
    --force|1|true) args+=(--force) ;;
  esac
  local tls_cn="${AGENT_A_PUBLIC_HOST}"
  for id in ${AGENT_IDS:-}; do
    h="$(agent_public_host "$id")"
    [[ -n "$h" ]] && { tls_cn="$h"; break; }
  done
  TLS_CN="${tls_cn}" EXTRA_SANS="$extra_sans" \
    bash "${IDENTYCLAW_ROOT}/scripts/generate-self-signed-certs.sh" "$cert_dir" "${args[@]}"
}

load_env() {
  local f
  IDENTYCLAW_APP_DIR="${IDENTYCLAW_APP_DIR:-$(identyclaw_app_dir)}"
  f="${IDENTYCLAW_APP_DIR}/env.local"
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
        OPENCLAW_*|HIMALAYA_*|AGENT_*|PUBLISH_HOST|IDENTYCLAW_*|A2A_*|DEPLOY_*) printf -v "$key" '%s' "$value" ;;
      esac
    done <"$f"
  fi
  OPENCLAW_BASE_IMAGE="${OPENCLAW_BASE_IMAGE:-ghcr.io/openclaw/openclaw:2026.6.10-slim}"
  OPENCLAW_GATEWAY_VERSION="${OPENCLAW_GATEWAY_VERSION:-$(openclaw_gateway_version_from_image "${OPENCLAW_BASE_IMAGE}")}"
  OPENCLAW_BUNDLED_PLUGINS="${OPENCLAW_BUNDLED_PLUGINS:-@openclaw/discord@${OPENCLAW_GATEWAY_VERSION}}"
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
  AGENT_D_EMAIL="${AGENT_D_EMAIL:-agent-d@identyclaw.com}"
  AGENT_D_DISPLAY_NAME="${AGENT_D_DISPLAY_NAME:-Identyclaw Agent D}"
  AGENT_D_GATEWAY_PORT="${AGENT_D_GATEWAY_PORT:-18795}"
  AGENT_D_BRIDGE_PORT="${AGENT_D_BRIDGE_PORT:-18796}"
  AGENT_F_EMAIL="${AGENT_F_EMAIL:-agent-f@identyclaw.com}"
  AGENT_F_DISPLAY_NAME="${AGENT_F_DISPLAY_NAME:-Identyclaw Agent F}"
  AGENT_F_GATEWAY_PORT="${AGENT_F_GATEWAY_PORT:-18799}"
  AGENT_F_BRIDGE_PORT="${AGENT_F_BRIDGE_PORT:-18800}"
  # Gateway always listens on this port inside the container (see identyclaw.sh start_one).
  OPENCLAW_CONTAINER_GATEWAY_PORT="${OPENCLAW_CONTAINER_GATEWAY_PORT:-18789}"
  # OpenRouter model chain: two free models first, Grok as paid fallback (override in env.local).
  OPENCLAW_MODEL_PRIMARY="${OPENCLAW_MODEL_PRIMARY:-openrouter/nvidia/nemotron-3-ultra-550b-a55b:free}"
  OPENCLAW_MODEL_FALLBACK_1="${OPENCLAW_MODEL_FALLBACK_1:-openrouter/qwen/qwen3-coder:free}"
  OPENCLAW_MODEL_FALLBACK_2="${OPENCLAW_MODEL_FALLBACK_2:-openrouter/x-ai/grok-4.3}"
  A2A_PEER_AGENTS="${A2A_PEER_AGENTS:-}"
  # Dev/self-signed peer TLS: rodit-auth-be uses Node fetch (not undici tlsSkipVerify alone).
  # Set A2A_TLS_SKIP_VERIFY=0 on main tier with CA-signed peer ingress.
  A2A_TLS_SKIP_VERIFY="${A2A_TLS_SKIP_VERIFY:-1}"
  IDENTYCLAW_CLAWHUB_A2A_PLUGIN="${IDENTYCLAW_CLAWHUB_A2A_PLUGIN:-clawhub:@identyclaw/openclaw-a2a-plugin@0.4.0}"
  IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN="${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN:-clawhub:@identyclaw/openclaw-identyclaw-webhooks-plugin@0.1.1}"
  IDENTYCLAW_NETWORK="${IDENTYCLAW_NETWORK:-identyclaw-net}"
  IDENTYCLAW_API_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}"
  IDENTYCLAW_NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}"
  # https://clawhub.ai/identyclaw/identyclaw
  IDENTYCLAW_CLAWHUB_PLUGIN="${IDENTYCLAW_CLAWHUB_PLUGIN:-clawhub:@identyclaw/openclaw-identyclaw-plugin@1.5.1}"
  IDENTYCLAW_CLAWHUB_SKILL="${IDENTYCLAW_CLAWHUB_SKILL:-identyclaw}"
  IDENTYCLAW_CLAWHUB_SKILL_VERSION="${IDENTYCLAW_CLAWHUB_SKILL_VERSION:-1.4.0}"
  IDENTYCLAW_CLAWHUB_TWITTER_SKILL="${IDENTYCLAW_CLAWHUB_TWITTER_SKILL:-bird-twitter}"
  IDENTYCLAW_CLAWHUB_LINKEDIN_SKILL="${IDENTYCLAW_CLAWHUB_LINKEDIN_SKILL:-linkedin-social}"
  IDENTYCLAW_CLAWHUB_CLAWLINK_PLUGIN="${IDENTYCLAW_CLAWHUB_CLAWLINK_PLUGIN:-clawhub:clawlink-plugin}"
  IDENTYCLAW_DEPLOY_MODE="${IDENTYCLAW_DEPLOY_MODE:-standalone}"
  IDENTYCLAW_INGRESS_PORT="${IDENTYCLAW_INGRESS_PORT:-9443}"
  AGENT_A_PUBLIC_HOST="${AGENT_A_PUBLIC_HOST:-agent-a.identyclaw.com}"
  AGENT_B_PUBLIC_HOST="${AGENT_B_PUBLIC_HOST:-agent-b.identyclaw.com}"
  AGENT_D_PUBLIC_HOST="${AGENT_D_PUBLIC_HOST:-agent-d.identyclaw.com}"
  AGENT_F_PUBLIC_HOST="${AGENT_F_PUBLIC_HOST:-agent-f.identyclaw.com}"
  IDENTYCLAW_APP_DIR="${IDENTYCLAW_APP_DIR:-$(identyclaw_app_dir)}"
  IDENTYCLAW_AGENT_STATE_ROOT="${IDENTYCLAW_AGENT_STATE_ROOT:-${IDENTYCLAW_APP_DIR}/agents}"
  AGENT_IDS="${AGENT_IDS:-agent-a agent-b}"
}

# Map deployment slug agent-{letter} → env prefix AGENT_{LETTER} (e.g. agent-d → AGENT_D).
agent_env_prefix() {
  local id="$1"
  if [[ "$id" =~ ^agent-([a-z])$ ]]; then
    printf 'AGENT_%s' "$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
    return 0
  fi
  return 1
}

is_valid_agent_id() {
  [[ "$1" =~ ^agent-[a-z]$ ]]
}

agent_env_value() {
  local id="$1" field="$2" default="${3:-}"
  local prefix combined
  prefix="$(agent_env_prefix "$id")" || { echo "$default"; return 1; }
  combined="${prefix}_${field}"
  echo "${!combined:-$default}"
}

agent_letter_ord() {
  local id="$1"
  if [[ "$id" =~ ^agent-([a-z])$ ]]; then
    printf '%d' "'${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

a2a_plugin_id() {
  echo "identyclaw-a2a"
}

a2a_tls_skip_verify_enabled() {
  load_env
  case "${A2A_TLS_SKIP_VERIFY:-1}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    *)
      echo "Invalid A2A_TLS_SKIP_VERIFY=${A2A_TLS_SKIP_VERIFY} (use 1 or 0)" >&2
      return 1
      ;;
  esac
}

sync_a2a_tls_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  local key="NODE_TLS_REJECT_UNAUTHORIZED"
  local value="0"
  [[ -f "$env_file" ]] || return 0
  if a2a_tls_skip_verify_enabled; then
    python3 - "$env_file" "$key" "$value" <<'PY'
import os, sys
from pathlib import Path

env_file, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
prefix = f"{key}="
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(prefix)]
lines.append(f"{key}={value}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
  else
    python3 - "$env_file" "$key" <<'PY'
import os, sys
from pathlib import Path

env_file, key = Path(sys.argv[1]), sys.argv[2]
prefix = f"{key}="
if not env_file.is_file():
    raise SystemExit(0)
lines = [ln for ln in env_file.read_text(encoding="utf-8").splitlines(keepends=True) if not ln.startswith(prefix)]
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
  fi
}

# Extra podman -e flags for gateway containers (rodit-auth-be fetch to self-signed peer TLS).
agent_gateway_podman_tls_env_args() {
  a2a_tls_skip_verify_enabled || return 0
  printf '%s\n' '-e' 'NODE_TLS_REJECT_UNAUTHORIZED=0'
}

agent_a2a_ext_dir() {
  echo "$1/extensions/$(a2a_plugin_id)"
}

agent_a2a_ext_dir_container() {
  echo "/home/node/.openclaw/extensions/$(a2a_plugin_id)"
}

clawhub_plugin_pinned_version() {
  local spec="$1"
  [[ "$spec" == *@* ]] || return 0
  echo "${spec##*@}"
}

a2a_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    pkg="$(agent_a2a_ext_dir_container)/package.json"
    pkg_json="$(podman exec "$container" cat "$pkg" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  pkg="$(agent_a2a_ext_dir "$config_dir")/package.json"
  [[ -f "$pkg" ]] || return 0
  python3 - "$pkg" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8")).get("version", ""))
PY
}

a2a_ext_ready() {
  local config_dir="$1"
  local container="${2:-}"
  local ext_dir
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" test \
      -f "$(agent_a2a_ext_dir_container)/openclaw.plugin.json" \
      -a -f "$(agent_a2a_ext_dir_container)/dist/index.js"
    return $?
  fi
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/openclaw.plugin.json" && -f "$ext_dir/dist/index.js" ]]
}

webhooks_plugin_id() {
  echo "identyclaw-webhooks"
}

agent_webhooks_ext_dir() {
  echo "$1/extensions/$(webhooks_plugin_id)"
}

agent_webhooks_ext_dir_container() {
  echo "/home/node/.openclaw/extensions/$(webhooks_plugin_id)"
}

webhooks_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    pkg="$(agent_webhooks_ext_dir_container)/package.json"
    pkg_json="$(podman exec "$container" cat "$pkg" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  pkg="$(agent_webhooks_ext_dir "$config_dir")/package.json"
  [[ -f "$pkg" ]] || return 0
  python3 - "$pkg" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8")).get("version", ""))
PY
}

webhooks_ext_ready() {
  local config_dir="$1"
  local container="${2:-}"
  local ext_dir
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" test \
      -f "$(agent_webhooks_ext_dir_container)/openclaw.plugin.json" \
      -a -f "$(agent_webhooks_ext_dir_container)/dist/index.js"
    return $?
  fi
  ext_dir="$(agent_webhooks_ext_dir "$config_dir")"
  [[ -f "$ext_dir/openclaw.plugin.json" && -f "$ext_dir/dist/index.js" ]]
}

migrate_legacy_a2a_extension() {
  local config_dir="$1"
  local container="${2:-}"
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" rm -rf \
      /home/node/.openclaw/extensions/a2a \
      /home/node/.openclaw/.a2a-plugin-build 2>/dev/null || true
    return 0
  fi
  rm -rf "$config_dir/extensions/a2a" "$config_dir/.a2a-plugin-build" 2>/dev/null || true
}

# openclaw.json lives on the host under -app but may only be writable inside the running container.
agent_config_use_container() {
  local config_dir="$1"
  local container="${2:-}"
  [[ -w "$config_dir/openclaw.json" ]] && return 1
  [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"
}

agent_openclaw_json_path() {
  local config_dir="$1"
  local container="${2:-}"
  if agent_config_use_container "$config_dir" "$container"; then
    echo "/home/node/.openclaw/openclaw.json"
  else
    echo "$config_dir/openclaw.json"
  fi
}

agent_openclaw_json_exists() {
  local config_dir="$1"
  local container="${2:-}"
  [[ -f "$config_dir/openclaw.json" ]] && return 0
  if agent_config_use_container "$config_dir" "$container"; then
    podman exec "$container" test -f /home/node/.openclaw/openclaw.json
    return $?
  fi
  return 1
}

agent_near_cred_path_for_config_sync() {
  local config_dir="$1"
  local container="${2:-}"
  local cred=""
  cred="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f -readable 2>/dev/null | head -1)"
  [[ -n "$cred" ]] && { echo "$cred"; return 0; }
  if agent_config_use_container "$config_dir" "$container"; then
    podman exec "$container" sh -c \
      'find /home/node/.openclaw/secrets/near-credentials -maxdepth 1 -name "*.json" -type f 2>/dev/null | head -1' \
      2>/dev/null || true
  fi
}

# Run python against the bind-mounted openclaw.json (host path or in-container path).
_agent_openclaw_json_python() {
  local config_dir="$1"
  local container="$2"
  shift 2
  local config_path
  config_path="$(agent_openclaw_json_path "$config_dir" "$container")"
  if [[ -w "$config_dir/openclaw.json" ]]; then
    python3 - "$config_path" "$@"
  elif agent_config_use_container "$config_dir" "$container"; then
    podman exec -i "$container" python3 - "$config_path" "$@"
  else
    echo "    (cannot update openclaw.json — not writable and container ${container:-<none>} unavailable)" >&2
    return 1
  fi
}

sync_agent_plugin_configs() {
  local id="$1"
  local config_dir="$2"
  local container
  container="$(agent_container "$id")"
  ensure_identyclaw_config "$config_dir" "$container" || return 1
  if agent_has_near_credentials "$config_dir"; then
    ensure_a2a_config "$id" "$config_dir" "$container" || return 1
    ensure_webhooks_plugin_config "$config_dir" "$container" || return 1
  fi
}

openclaw_gateway_version_from_image() {
  local image_ref="${1:-}"
  local tag="${image_ref##*:}"
  tag="${tag%%-*}"
  echo "${tag:-2026.5.27}"
}

# Pin bare @openclaw/discord to the gateway version (prevents channel provider crashes).
resolve_openclaw_bundled_plugins() {
  load_env
  local gw spec resolved=()
  gw="${OPENCLAW_GATEWAY_VERSION:-$(openclaw_gateway_version_from_image "${OPENCLAW_BASE_IMAGE}")}"
  for spec in ${OPENCLAW_BUNDLED_PLUGINS}; do
    if [[ "$spec" == @openclaw/discord ]]; then
      resolved+=("@openclaw/discord@${gw}")
    else
      resolved+=("$spec")
    fi
  done
  echo "${resolved[@]}"
}

# Discord channel plugin must match gateway core (e.g. parseStrictPositiveInteger export drift).
ensure_discord_plugin_compat() {
  local id="$1"
  local container
  load_env
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0

  if podman exec "$container" node -e "
const fs = require('fs');
const path = require('path');
const gw = require('/app/package.json').version;
function discordVersion() {
  const legacy = '/home/node/.openclaw/npm/node_modules/@openclaw/discord/package.json';
  if (fs.existsSync(legacy)) return require(legacy).version;
  const projects = '/home/node/.openclaw/npm/projects';
  if (!fs.existsSync(projects)) return null;
  for (const d of fs.readdirSync(projects)) {
    const pkg = path.join(projects, d, 'node_modules/@openclaw/discord/package.json');
    if (fs.existsSync(pkg)) return require(pkg).version;
  }
  return null;
}
process.exit(discordVersion() === gw ? 0 : 1);
" 2>/dev/null; then
    return 0
  fi

  echo "    (${id}: syncing @openclaw/discord to gateway version…)" >&2
  podman exec "$container" bash -ce '
    set -euo pipefail
    gw=$(node -e "process.stdout.write(require(\"/app/package.json\").version)")
    rm -rf /home/node/.openclaw/npm/node_modules/@openclaw/discord
    rm -rf /home/node/.openclaw/npm/projects/openclaw-discord-*
    OPENCLAW_STATE_DIR=/home/node/.openclaw node /app/openclaw.mjs plugins install "@openclaw/discord@${gw}" --pin
  ' >&2
  return 1
}

restart_agent_gateway_if_running() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  echo "    (${id}: restarting gateway to load Discord plugin…)" >&2
  podman restart "$container" >/dev/null
}

ensure_discord_plugin_compat_and_restart() {
  local id="$1"
  ensure_discord_plugin_compat "$id" || restart_agent_gateway_if_running "$id"
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
  load_env
  echo "${IDENTYCLAW_AGENT_STATE_ROOT}/${id}"
}

# Host path: per-agent NEAR Passport JSON (canonical layout for peer coordination).
agent_near_credentials_dir() {
  echo "$(agent_home "$1")/secrets/near-credentials"
}

agent_near_credentials_host_path() {
  local id="$1"
  find "$(agent_near_credentials_dir "$id")" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true
}

agent_container() {
  echo "openclaw-${1}"
}

# True when id is listed in AGENT_IDS (runs on this host).
agent_is_local() {
  local id="$1" local_id
  load_env
  for local_id in $AGENT_IDS; do
    [[ "$local_id" == "$id" ]] && return 0
  done
  return 1
}

agent_container_running() {
  local id="$1" container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"
}

# First agent in AGENT_IDS — local origin/destination for constitution suites.
resolve_local_agent_id() {
  local id
  load_env
  for id in $AGENT_IDS; do
    [[ -n "$id" ]] && { echo "$id"; return 0; }
  done
  echo "agent-a"
}

# First peer Passport token_id from A2A_PEER_AGENTS (not the local agent's own token_id).
# Override: IDENTYCLAW_PEER_TOKEN_ID=<token_id> in env.local.
resolve_peer_token_id() {
  local local_deploy_id="${1:-$(resolve_local_agent_id)}"
  local self_token_id p
  load_env
  if [[ -n "${IDENTYCLAW_PEER_TOKEN_ID:-}" ]]; then
    is_passport_token_id "$IDENTYCLAW_PEER_TOKEN_ID" || {
      echo "IDENTYCLAW_PEER_TOKEN_ID must be a Passport token_id (12 characters)" >&2
      return 1
    }
    echo "$IDENTYCLAW_PEER_TOKEN_ID"
    return 0
  fi
  self_token_id="$(agent_token_id "$local_deploy_id")"
  for p in $A2A_PEER_AGENTS; do
    is_passport_token_id "$p" || continue
    [[ -n "$self_token_id" && "$p" == "$self_token_id" ]] && continue
    echo "$p"
    return 0
  done
  return 1
}

# curl --resolve for local HTTPS ingress (loopback health / A2A probes from host).
agent_ingress_curl_resolve_args() {
  local id="$1" host port url
  load_env
  host="$(agent_public_host "$id")"
  port="$(agent_ingress_port "$id")"
  url="$(agent_a2a_endpoint_url "$id")"
  if agent_is_local "$id" && [[ -n "$host" && -n "$port" && "$url" == https://* ]]; then
    printf '%s\n' --resolve "${host}:${port}:127.0.0.1"
  fi
}

agent_a2a_public_base_url() {
  local id="$1"
  local explicit="" config_dir passport_url
  load_env
  explicit="$(agent_env_value "$id" A2A_PUBLIC_BASE_URL "")"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  if rodit_self_configure_enabled; then
    config_dir="$(agent_home "$id")"
    if agent_has_near_credentials "$config_dir"; then
      passport_url="$(rodit_passport_webhook_url "$config_dir" 2>/dev/null || true)"
      if [[ -n "$passport_url" ]]; then
        echo "    (${id}: public base from Passport metadata.webhook_url)" >&2
        echo "$passport_url"
        return 0
      fi
    fi
  fi
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    agent_public_base_url "$id"
  fi
}

agent_a2a_audience() {
  local id="$1"
  local config_dir="${2:-}"
  local container="${3:-}"
  load_env
  local probed=""
  if [[ -n "$config_dir" ]]; then
    probed="$(probe_rodit_own_owner_id "$config_dir" 2>/dev/null || true)"
  fi
  if [[ -z "$probed" && -n "$container" ]]; then
    probed="$(probe_rodit_own_owner_id_in_container "$container" 2>/dev/null || true)"
  fi
  if [[ -n "$probed" ]]; then
    echo "$probed"
    return 0
  fi
  local explicit=""
  explicit="$(agent_env_value "$id" P2P_AUDIENCE "")"
  [[ -z "$explicit" ]] && explicit="$(agent_env_value "$id" A2P_AUDIENCE "")"
  [[ -z "$explicit" ]] && explicit="$(agent_env_value "$id" A2A_AUDIENCE "")"
  is_valid_agent_id "$id" || { echo ""; return 0; }
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  if [[ -n "${IDENTYCLAW_P2P_AUDIENCE:-${IDENTYCLAW_A2P_AUDIENCE:-${IDENTYCLAW_A2A_JWT_AUDIENCE:-}}}" ]]; then
    echo "${IDENTYCLAW_P2P_AUDIENCE:-${IDENTYCLAW_A2P_AUDIENCE:-${IDENTYCLAW_A2A_JWT_AUDIENCE:-}}}"
    return 0
  fi
  echo "    (${id}: inbound JWT audience unknown — ensure NEAR creds for owner_id probe or set AGENT_*_P2P_AUDIENCE)" >&2
  echo ""
}

probe_rodit_own_owner_id_in_container() {
  local container="$1"
  local cred ext_dir probed
  [[ -n "$container" ]] || return 1
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman cp "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-owner-id.mjs" "$container:/tmp/probe-rodit-own-owner-id.mjs" >/dev/null 2>&1 || return 1
  probed="$(
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
      node /tmp/probe-rodit-own-owner-id.mjs "$ext_dir" "$cred" 2>/dev/null || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" && ${#probed} -le 256 && "$probed" != *"{"* ]] || return 1
  echo "    (${container}: P2P inbound audience from own_rodit.owner_id=${probed:0:16}…)" >&2
  echo "$probed"
}

probe_rodit_own_token_id_in_container() {
  local container="$1"
  local cred ext_dir probed
  [[ -n "$container" ]] || return 1
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman cp "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-token-id.mjs" "$container:/tmp/probe-rodit-own-token-id.mjs" >/dev/null 2>&1 || return 1
  probed="$(
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
      node /tmp/probe-rodit-own-token-id.mjs "$ext_dir" "$cred" 2>/dev/null || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  is_passport_token_id "$probed" || return 1
  echo "$probed"
}

# Legacy: mediated login_server JWT aud (pre–P2P-only plugin). Used by test scripts only.
probe_rodit_inbound_audience() {
  local config_dir="$1"
  local cred_file ext_dir cache cache_key cached_key cached_aud probed cred_stat
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$cred_file" && -f "$cred_file" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/node_modules/@rodit/rodit-auth-be/package.json" ]] || return 1

  load_env
  sync_quiet_plugin_env "$config_dir"

  cache="$config_dir/.rodit-jwt-audience"
  cred_stat="$(stat -c '%Y %s' "$cred_file" 2>/dev/null || stat -f '%m %z' "$cred_file" 2>/dev/null || true)"
  if [[ -n "$cred_stat" && -f "$cache" ]]; then
    read -r cached_key cached_aud <"$cache" || true
    if [[ "$cached_key" == "$cred_stat" && -n "$cached_aud" ]]; then
      echo "$cached_aud"
      return 0
    fi
  fi

  command -v node >/dev/null 2>&1 || return 1
  probed="$(
    NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      IDENTYCLAW_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}" \
      node "${IDENTYCLAW_ROOT}/scripts/probe-rodit-jwt-audience.mjs" "$ext_dir" "$cred_file" 2>/dev/null \
      || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" ]] || return 1
  if [[ "$probed" == *"{"* ]] || [[ "$probed" == *"}"* ]] || [[ ${#probed} -gt 256 ]]; then
    return 1
  fi

  if [[ -n "$cred_stat" ]]; then
    printf '%s %s\n' "$cred_stat" "$probed" >"$cache"
    chmod 600 "$cache" 2>/dev/null || true
  fi
  echo "    (${config_dir##*/}: inbound JWT audience from login_server aud=${probed:0:16}…)" >&2
  echo "$probed"
}

# Own passport owner_id — inbound P2P JWT audience (Phase 9).
probe_rodit_own_owner_id() {
  local config_dir="$1"
  local cred_file ext_dir cache cache_key cached_key cached_id probed cred_stat
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$cred_file" && -f "$cred_file" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/node_modules/@rodit/rodit-auth-be/package.json" ]] || return 1

  load_env
  sync_quiet_plugin_env "$config_dir"

  cache="$config_dir/.rodit-own-owner-id"
  cred_stat="$(stat -c '%Y %s' "$cred_file" 2>/dev/null || stat -f '%m %z' "$cred_file" 2>/dev/null || true)"
  if [[ -n "$cred_stat" && -f "$cache" ]]; then
    read -r cached_key cached_id <"$cache" || true
    if [[ "$cached_key" == "$cred_stat" && -n "$cached_id" ]]; then
      echo "$cached_id"
      return 0
    fi
  fi

  command -v node >/dev/null 2>&1 || return 1
  probed="$(
    NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      IDENTYCLAW_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}" \
      node "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-owner-id.mjs" "$ext_dir" "$cred_file" 2>/dev/null \
      || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" ]] || return 1
  if [[ "$probed" == *"{"* ]] || [[ "$probed" == *"}"* ]] || [[ ${#probed} -gt 256 ]]; then
    return 1
  fi

  if [[ -n "$cred_stat" ]]; then
    printf '%s %s\n' "$cred_stat" "$probed" >"$cache"
    chmod 600 "$cache" 2>/dev/null || true
  fi
  echo "    (${config_dir##*/}: P2P inbound audience from own_rodit.owner_id=${probed:0:16}…)" >&2
  echo "$probed"
}

# True when ref is a Passport token_id (12-char), not a deployment slug like agent-a.
is_passport_token_id() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || return 1
  [[ "$ref" == agent-* ]] && return 1
  [[ "$ref" =~ ^[A-Za-z][A-Za-z0-9]{11}$ ]]
}

# Own passport token_id — canonical A2A peer identity (12-char Passport ID).
probe_rodit_own_token_id() {
  local config_dir="$1"
  local cred_file ext_dir cache cred_stat probed cached_key cached_id
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$cred_file" && -f "$cred_file" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/node_modules/@rodit/rodit-auth-be/package.json" ]] || return 1

  load_env
  sync_quiet_plugin_env "$config_dir"

  cache="$config_dir/.rodit-own-token-id"
  cred_stat="$(stat -c '%Y %s' "$cred_file" 2>/dev/null || stat -f '%m %z' "$cred_file" 2>/dev/null || true)"
  if [[ -n "$cred_stat" && -f "$cache" ]]; then
    read -r cached_key cached_id <"$cache" || true
    if [[ "$cached_key" == "$cred_stat" && -n "$cached_id" ]]; then
      echo "$cached_id"
      return 0
    fi
  fi

  command -v node >/dev/null 2>&1 || return 1
  probed="$(
    NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      IDENTYCLAW_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}" \
      node "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-token-id.mjs" "$ext_dir" "$cred_file" 2>/dev/null \
      || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" ]] || return 1
  is_passport_token_id "$probed" || return 1

  if [[ -n "$cred_stat" ]]; then
    printf '%s %s\n' "$cred_stat" "$probed" >"$cache"
    chmod 600 "$cache" 2>/dev/null || true
  fi
  echo "    (${config_dir##*/}: Passport token_id=${probed})" >&2
  echo "$probed"
}

# Resolve Passport token_id for a local deployment slug (AGENT_IDS only — not for A2A_PEER_AGENTS).
probe_rodit_own_token_id_in_container() {
  local container="$1"
  local cred ext_dir probed
  [[ -n "$container" ]] || return 1
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman cp "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-token-id.mjs" "$container:/tmp/probe-rodit-own-token-id.mjs" >/dev/null 2>&1 || return 1
  probed="$(
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
      -e NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      -e IDENTYCLAW_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}" \
      "$container" node /tmp/probe-rodit-own-token-id.mjs "$ext_dir" "$cred" 2>/dev/null || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  is_passport_token_id "$probed" || return 1
  echo "    (${container}: Passport token_id=${probed})" >&2
  echo "$probed"
}

agent_token_id() {
  local deploy_id="$1"
  local config_dir probed container
  config_dir="$(agent_home "$deploy_id")"
  probed="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  [[ -n "$probed" ]] && { echo "$probed"; return 0; }
  container="$(agent_container "$deploy_id" 2>/dev/null || true)"
  probe_rodit_own_token_id_in_container "$container" 2>/dev/null || true
}

# Map token_id → local deployment slug when this host runs that Passport (AGENT_IDS / agents/).
find_deploy_id_for_token_id() {
  local token_id="$1" id config_dir probed app_dir entry
  [[ -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  load_env
  for id in $AGENT_IDS; do
    [[ "$id" == agent-* ]] || continue
    config_dir="$(agent_home "$id")"
    agent_has_near_credentials "$config_dir" || continue
    probed="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
    [[ "$probed" == "$token_id" ]] && { echo "$id"; return 0; }
  done
  app_dir="$(identyclaw_app_dir)/agents"
  if [[ -d "$app_dir" ]]; then
    for entry in "$app_dir"/*/; do
      [[ -d "$entry" ]] || continue
      id="$(basename "$entry")"
      [[ "$id" == agent-* ]] || continue
      agent_has_near_credentials "$entry" || continue
      probed="$(probe_rodit_own_token_id "$entry" 2>/dev/null || true)"
      [[ "$probed" == "$token_id" ]] && { echo "$id"; return 0; }
    done
  fi
  return 1
}

# Public HTTPS base for a peer token_id (A2A_PEER_URLS in env.local).
a2a_peer_public_base_url() {
  local token_id="$1"
  [[ -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  load_env
  local url_json="${A2A_PEER_URLS:-}"
  [[ -n "$url_json" ]] || return 1
  A2A_PEER_TOKEN_ID="$token_id" A2A_PEER_URLS_JSON="$url_json" python3 - <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["A2A_PEER_URLS_JSON"])
    url = str(data.get(os.environ["A2A_PEER_TOKEN_ID"], "")).strip().rstrip("/")
    if url:
        print(url)
except Exception:
    sys.exit(1)
PY
}

a2a_peer_agent_card_url() {
  local token_id="$1"
  local public_base
  public_base="$(a2a_peer_public_base_url "$token_id")"
  [[ -n "$public_base" ]] || return 1
  echo "${public_base%/}/.well-known/agent-card.json"
}

a2a_peer_a2a_endpoint_url() {
  local token_id="$1"
  local public_base
  public_base="$(a2a_peer_public_base_url "$token_id")"
  [[ -n "$public_base" ]] || return 1
  echo "${public_base%/}/a2a"
}

# Passport token_ids listed in A2A_PEER_AGENTS (invalid entries omitted with warning).
a2a_configured_peer_token_ids() {
  local ref out="" invalid=0
  load_env
  for ref in $A2A_PEER_AGENTS; do
    if ! is_passport_token_id "$ref"; then
      echo "    (A2A_PEER_AGENTS: ignore invalid peer ref \"${ref}\" — must be Passport token_id)" >&2
      invalid=1
      continue
    fi
    if [[ -z "$out" ]]; then
      out="$ref"
    else
      out="$out $ref"
    fi
  done
  [[ "$invalid" -eq 0 ]] || true
  echo "$out"
}

warn_invalid_a2a_peer_agents() {
  local ref
  load_env
  for ref in $A2A_PEER_AGENTS; do
    is_passport_token_id "$ref" && continue
    echo "    (A2A_PEER_AGENTS: \"${ref}\" is not a Passport token_id — ignored; set A2A_PEER_URLS for each peer)" >&2
  done
}

sync_rodit_token_id_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  local token_id
  token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  [[ -n "$token_id" ]] || return 0
  python3 - "$env_file" "$token_id" <<'PY'
import os, sys
from pathlib import Path

env_file = Path(sys.argv[1])
token_id = sys.argv[2]
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith("IDENTYCLAW_TOKEN_ID=")]
lines.append(f"IDENTYCLAW_TOKEN_ID={token_id}\n")
env_file.parent.mkdir(parents=True, exist_ok=True)
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}

# Parse gateway logs + openclaw.json outbound.agents for Passport token_id peers.
harvest_a2a_peers_json_from_agent() {
  local id="$1"
  local container dir config_dir logs agents_json registry_json self_token_id
  load_env
  container="$(agent_container "$id")"
  dir="$(agent_home "$id")"
  config_dir="$dir"
  self_token_id="$(agent_token_id "$id" 2>/dev/null || true)"
  logs=""
  agents_json="{}"
  registry_json="{}"
  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    logs="$(podman logs "$container" 2>&1 || true)"
    agents_json="$(podman exec "$container" python3 - <<'PY' 2>/dev/null || echo '{}'
import json
from pathlib import Path
from urllib.parse import urlparse

path = Path("/home/node/.openclaw/openclaw.json")
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
agents = (
    data.get("plugins", {})
    .get("entries", {})
    .get("identyclaw-a2a", {})
    .get("config", {})
    .get("outbound", {})
    .get("agents", {})
)
out = {}

def peer_entry_base(peer):
    if isinstance(peer, dict):
        text = str(peer.get("url") or peer.get("loginBaseUrl") or "").strip()
    else:
        text = str(peer or "").strip()
    if not text:
        return ""
    if text.endswith("/.well-known/agent-card.json"):
        return text[: -len("/.well-known/agent-card.json")].rstrip("/")
    parsed = urlparse(text if "://" in text else f"https://{text}")
    if parsed.netloc:
        return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")
    return text.rstrip("/")

for token_id, peer in (agents or {}).items():
    base = peer_entry_base(peer)
    if base:
        out[str(token_id)] = base
print(json.dumps(out))
PY
)"
    registry_json="$(podman exec "$container" python3 - <<'PY' 2>/dev/null || echo '{}'
import json
from pathlib import Path

path = Path("/home/node/.openclaw/a2a/outbound/peers.json")
if not path.is_file():
    print("{}")
    raise SystemExit(0)
print(path.read_text(encoding="utf-8"))
PY
)"
  elif [[ -r "$config_dir/openclaw.json" ]]; then
    agents_json="$(python3 - "$config_dir/openclaw.json" <<'PY' 2>/dev/null || echo '{}'
import json, sys
from pathlib import Path
from urllib.parse import urlparse

path = Path(sys.argv[1])
if not path.is_file():
    print("{}")
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
agents = (
    data.get("plugins", {})
    .get("entries", {})
    .get("identyclaw-a2a", {})
    .get("config", {})
    .get("outbound", {})
    .get("agents", {})
)
out = {}

def peer_entry_base(peer):
    if isinstance(peer, dict):
        text = str(peer.get("url") or peer.get("loginBaseUrl") or "").strip()
    else:
        text = str(peer or "").strip()
    if not text:
        return ""
    if text.endswith("/.well-known/agent-card.json"):
        return text[: -len("/.well-known/agent-card.json")].rstrip("/")
    parsed = urlparse(text if "://" in text else f"https://{text}")
    if parsed.netloc:
        return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")
    return text.rstrip("/")

for token_id, peer in (agents or {}).items():
    base = peer_entry_base(peer)
    if base:
        out[str(token_id)] = base
print(json.dumps(out))
PY
)"
    if [[ -f "$config_dir/a2a/outbound/peers.json" ]]; then
      registry_json="$(<"$config_dir/a2a/outbound/peers.json")"
    fi
  fi
  A2A_PEER_LOGS="$logs" A2A_PEER_AGENTS_JSON="$agents_json" A2A_PEER_REGISTRY_JSON="$registry_json" A2A_PEER_SELF_TOKEN_ID="${self_token_id:-}" python3 - <<'PY'
import json, os, re

peers = {}
try:
    peers.update(json.loads(os.environ.get("A2A_PEER_AGENTS_JSON", "{}") or "{}"))
except Exception:
    pass

logs = os.environ.get("A2A_PEER_LOGS", "")
patterns = [
    re.compile(
        r"\[a2a\] Registered outbound peer ([A-Za-z][A-Za-z0-9]{11}) from identity contactUri \((https?://[^)]+)\)"
    ),
    re.compile(
        r"\[a2a\] Registered dynamic outbound peer ([A-Za-z][A-Za-z0-9]{11}) from inbound JWT"
        r"(?: \(baseUrl=(https?://[^)]+)\))?"
    ),
    re.compile(
        r"\[a2a\] Inbound P2P login accepted token_id=([A-Za-z][A-Za-z0-9]{11})"
        r"(?: baseUrl=(https?://\S+))?"
    ),
]
for line in logs.splitlines():
    for pat in patterns:
        match = pat.search(line)
        if not match:
            continue
        token_id = match.group(1)
        base_url = ""
        if match.lastindex and match.lastindex >= 2 and match.group(2):
            card_or_base = match.group(2).strip().rstrip("/")
            if "/.well-known/agent-card.json" in card_or_base:
                base_url = card_or_base.split("/.well-known/agent-card.json")[0].rstrip("/")
            else:
                base_url = card_or_base
        if base_url:
            peers[token_id] = base_url
        elif token_id not in peers:
            peers[token_id] = ""

try:
    registry = json.loads(os.environ.get("A2A_PEER_REGISTRY_JSON", "{}") or "{}")
    for token_id, entry in registry.items():
        if token_id in peers and peers[token_id]:
            continue
        card_url = ""
        if isinstance(entry, dict):
            card_url = str(entry.get("url") or "").strip()
        else:
            card_url = str(entry or "").strip()
        if not card_url:
            continue
        if card_url.endswith("/.well-known/agent-card.json"):
            base = card_url[: -len("/.well-known/agent-card.json")].rstrip("/")
        else:
            base = card_url.rstrip("/")
        if base:
            peers[token_id] = base
except Exception:
    pass

self_token_id = os.environ.get("A2A_PEER_SELF_TOKEN_ID", "").strip()
if self_token_id:
    peers.pop(self_token_id, None)
peers = {k: v for k, v in peers.items() if k}
print(json.dumps(peers, sort_keys=True))
PY
}

# Merge harvested peers into env.local (A2A_PEER_AGENTS + A2A_PEER_URLS).
upsert_a2a_peers_in_env_local() {
  local peers_json="${1:-{}}"
  local env_file
  env_file="$(identyclaw_env_file)"
  [[ -n "$peers_json" && "$peers_json" != "{}" ]] || return 1
  python3 - "$env_file" "$peers_json" <<'PY'
import json, os, sys
from pathlib import Path

env_file = Path(sys.argv[1])
try:
    harvested = json.loads(sys.argv[2])
except Exception:
    raise SystemExit(1)
if not isinstance(harvested, dict) or not harvested:
    raise SystemExit(1)

lines = []
if env_file.is_file():
  lines = env_file.read_text(encoding="utf-8").splitlines(keepends=True)

agents = []
urls = {}
for line in lines:
    stripped = line.strip()
    if stripped.startswith("A2A_PEER_AGENTS="):
        value = stripped.split("=", 1)[1].strip()
        agents = [p for p in value.split() if p]
        continue
    if stripped.startswith("A2A_PEER_URLS="):
        raw = stripped.split("=", 1)[1].strip()
        if raw:
            try:
                urls = json.loads(raw)
            except Exception:
                urls = {}
        continue

valid = {}
for token_id, base_url in harvested.items():
    token_id = str(token_id).strip()
    if not token_id or not __import__("re").match(r"^[A-Za-z][A-Za-z0-9]{11}$", token_id):
        continue
    base_url = str(base_url or "").strip().rstrip("/")
    if base_url:
        valid[token_id] = base_url

if not valid:
    raise SystemExit(1)

for token_id in agents:
    if token_id in valid:
        continue
    if __import__("re").match(r"^[A-Za-z][A-Za-z0-9]{11}$", token_id):
        valid.setdefault(token_id, urls.get(token_id, ""))

agents_out = []
seen = set()
for token_id in list(agents) + sorted(valid):
    if token_id in seen:
        continue
    if token_id not in valid:
        continue
    seen.add(token_id)
    agents_out.append(token_id)

for token_id, base_url in valid.items():
    if base_url:
        urls[token_id] = base_url

def render(key, value):
    if key == "A2A_PEER_URLS":
        return f'A2A_PEER_URLS={json.dumps(urls, separators=(",", ":"))}\n'
    if key == "A2A_PEER_AGENTS":
        return f'A2A_PEER_AGENTS={" ".join(agents_out)}\n'
    return None

out = []
replaced_agents = False
replaced_urls = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("A2A_PEER_AGENTS="):
        out.append(render("A2A_PEER_AGENTS", None))
        replaced_agents = True
        continue
    if stripped.startswith("A2A_PEER_URLS="):
        out.append(render("A2A_PEER_URLS", None))
        replaced_urls = True
        continue
    out.append(line)

if not replaced_agents:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(render("A2A_PEER_AGENTS", None))
if not replaced_urls:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(render("A2A_PEER_URLS", None))

env_file.parent.mkdir(parents=True, exist_ok=True)
env_file.write_text("".join(out), encoding="utf-8")
os.chmod(env_file, 0o600)
print(json.dumps({"agents": agents_out, "urls": urls}, indent=2))
PY
}

# Harvest inbound P2P peer logins and persist to env.local.
sync_a2a_peers_from_logs() {
  local id="${1:-}"
  local peers_json updated=0
  load_env
  if [[ -z "$id" ]]; then
    for id in $AGENT_IDS; do
      sync_a2a_peers_from_logs "$id" && updated=1 || true
    done
    [[ "$updated" -eq 1 ]]
    return $?
  fi
  peers_json="$(harvest_a2a_peers_json_from_agent "$id")"
  [[ -n "$peers_json" && "$peers_json" != "{}" ]] || {
    echo "    (${id}: no inbound P2P peers found in logs or openclaw.json)" >&2
    return 1
  }
  echo "    (${id}: harvesting A2A peers from inbound P2P login logs)" >&2
  upsert_a2a_peers_in_env_local "$peers_json"
}

rodit_self_configure_enabled() {
  load_env
  [[ "${IDENTYCLAW_RODIT_SELF_CONFIGURE:-1}" != "0" ]]
}

# Open A2A to any IdentyClaw Passport holder via P2P login (inbound promiscuous + dynamic outbound peers).
a2a_open_p2p_enabled() {
  load_env
  [[ "${IDENTYCLAW_A2A_OPEN_P2P:-0}" != "0" ]]
}

a2a_dynamic_peers_from_jwt_enabled() {
  load_env
  if a2a_open_p2p_enabled; then
    return 0
  fi
  [[ "${IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT:-0}" != "0" ]]
}

# Passport metadata via RoditClient.getConfigOwnRodit() — webhook_url, api_base, owner_id, host, port.
probe_rodit_passport_urls_json() {
  local config_dir="$1"
  local cred_file ext_dir cache cred_stat probed cached_key cached_json
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$cred_file" && -f "$cred_file" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/node_modules/@rodit/rodit-auth-be/package.json" ]] || return 1

  load_env
  sync_quiet_plugin_env "$config_dir"

  cache="$config_dir/.rodit-passport-urls.json"
  cred_stat="$(stat -c '%Y %s' "$cred_file" 2>/dev/null || stat -f '%m %z' "$cred_file" 2>/dev/null || true)"
  if [[ -n "$cred_stat" && -f "$cache" ]]; then
    read -r cached_key cached_json <"$cache" || true
    if [[ "$cached_key" == "$cred_stat" && -n "$cached_json" ]]; then
      echo "$cached_json"
      return 0
    fi
  fi

  command -v node >/dev/null 2>&1 || return 1
  probed="$(
    NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      IDENTYCLAW_BASE_URL="${IDENTYCLAW_API_BASE_URL:-https://api.identyclaw.com}" \
      node "${IDENTYCLAW_ROOT}/scripts/probe-rodit-passport-urls.mjs" "$ext_dir" "$cred_file" 2>/dev/null \
      || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" && "$probed" == "{"* ]] || return 1

  if [[ -n "$cred_stat" ]]; then
    printf '%s %s\n' "$cred_stat" "$probed" >"$cache"
    chmod 600 "$cache" 2>/dev/null || true
  fi
  echo "$probed"
}

rodit_passport_json_field() {
  local config_dir="$1"
  local field="$2"
  local json value
  json="$(probe_rodit_passport_urls_json "$config_dir" 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  value="$(RODIT_JSON="$json" RODIT_FIELD="$field" python3 - <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["RODIT_JSON"])
    value = data.get(os.environ["RODIT_FIELD"], "")
    if value is None:
        sys.exit(1)
    text = str(value).strip()
    if not text:
        sys.exit(1)
    print(text)
except Exception:
    sys.exit(1)
PY
)" || return 1
  echo "$value"
}

rodit_passport_webhook_url() {
  rodit_passport_json_field "$1" "webhook_url"
}

rodit_passport_webhook_host() {
  rodit_passport_json_field "$1" "host"
}

rodit_passport_webhook_port() {
  rodit_passport_json_field "$1" "port"
}

a2a_warn_legacy_auth_mode_env() {
  load_env
  local id="$1" explicit_in explicit_out inbound outbound
  is_valid_agent_id "$id" || return 0
  explicit_in="$(agent_env_value "$id" A2A_INBOUND_AUTH_MODE "")"
  explicit_out="$(agent_env_value "$id" A2A_OUTBOUND_AUTH_MODE "")"
  inbound="${explicit_in:-${IDENTYCLAW_A2A_INBOUND_AUTH_MODE:-}}"
  outbound="${explicit_out:-${IDENTYCLAW_A2A_OUTBOUND_AUTH_MODE:-}}"
  for val in "$inbound" "$outbound"; do
    [[ -z "$val" ]] && continue
    case "$val" in
      mediated|dual|auto|p2p)
        echo "    (${id}: A2A auth mode \"${val}\" is ignored — identyclaw-a2a plugin uses P2P only; unset IDENTYCLAW_A2A_*_AUTH_MODE)" >&2
        ;;
    esac
  done
}

agent_agent_card_url() {
  local id="$1"
  local public_base
  load_env
  public_base="$(agent_a2a_public_base_url "$id")"
  if [[ -n "$public_base" ]]; then
    echo "${public_base%/}/.well-known/agent-card.json"
    return 0
  fi
  echo "http://$(agent_container "$id"):$(agent_internal_gateway_port "$id")/.well-known/agent-card.json"
}

# In-container path for RODiT file credentials (agent state mounted at /home/node/.openclaw).
near_credentials_container_path() {
  local account_id="$1"
  echo "/home/node/.openclaw/secrets/near-credentials/${account_id}.json"
}

# Peer NEAR creds for cross-host P2P webhook tests (private key signs, remote agent verifies).
# Accepts Passport token_id — resolves to a local agents/<deploy-id>/ dir when present.
peer_near_credentials_path() {
  local peer_ref="$1"
  local deploy_id cred legacy_dir
  load_env
  if is_passport_token_id "$peer_ref"; then
    deploy_id="$(find_deploy_id_for_token_id "$peer_ref" 2>/dev/null || true)"
    [[ -n "$deploy_id" ]] && peer_ref="$deploy_id"
  fi
  cred="$(agent_near_credentials_host_path "$peer_ref")"
  if [[ -n "$cred" ]]; then
    printf '%s' "$cred"
    return 0
  fi
  # Legacy layout (pre agents/-only migration).
  legacy_dir="$(identyclaw_app_dir)/secrets/peer-credentials/${peer_ref}"
  cred="$(find "$legacy_dir" -maxdepth 1 -name '*.json' -type f -readable 2>/dev/null | head -1 || true)"
  [[ -n "$cred" ]] && printf '%s' "$cred"
  return 0
}

agent_near_credentials_in_container() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  podman exec "$container" find /home/node/.openclaw/secrets/near-credentials -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true
}

# Resolve NEAR passport JSON for an agent (canonical: agents/<id>/secrets/near-credentials/).
resolve_near_credentials_file() {
  local config_dir="$1"
  local agent_cred_dir candidate legacy_dir legacy_app_secrets
  load_env
  agent_cred_dir="$config_dir/secrets/near-credentials"
  mkdir -p "$agent_cred_dir" 2>/dev/null || true

  for candidate in "$agent_cred_dir"/*.json; do
    [[ -f "$candidate" ]] || continue
    echo "$candidate"
    return 0
  done

  # Legacy: app-level secrets/<account>.json or secrets/peer-credentials/<agent-id>/
  legacy_app_secrets="$(identyclaw_app_dir)/secrets"
  for candidate in "$legacy_app_secrets"/*.json; do
    [[ -f "$candidate" ]] || continue
    echo "$candidate"
    return 0
  done
  legacy_dir="$legacy_app_secrets/peer-credentials/$(basename "$config_dir")"
  candidate="$(find "$legacy_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true)"
  [[ -n "$candidate" ]] || return 1
  echo "$candidate"
  return 0
}

# Copy resolved creds into agents/<id>/secrets/near-credentials/ (one-way migration from legacy layouts).
ensure_near_credentials_in_agent() {
  local config_dir="$1"
  local cred_file agent_cred_dir account_id dest
  cred_file="$(resolve_near_credentials_file "$config_dir")" || return 1
  agent_cred_dir="$config_dir/secrets/near-credentials"
  account_id="$(python3 - "$cred_file" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("implicit_account_id") or data.get("account_id") or Path(sys.argv[1]).stem)
PY
)"
  dest="$agent_cred_dir/${account_id}.json"
  mkdir -p "$agent_cred_dir"
  chmod 700 "$config_dir/secrets" "$agent_cred_dir" 2>/dev/null || true
  if [[ "$cred_file" != "$dest" ]]; then
    cp -a "$cred_file" "$dest"
    chmod 600 "$dest"
    echo "    ($(basename "$config_dir"): migrated NEAR creds → secrets/near-credentials/${account_id}.json)" >&2
  fi
}

agent_has_near_credentials() {
  local config_dir="$1"
  resolve_near_credentials_file "$config_dir" >/dev/null 2>&1
}

# Legacy layouts used secrets/near/*.json — bootstrap expects secrets/near-credentials/.
ensure_near_credentials_layout() {
  local config_dir="$1"
  local cred_dir="$config_dir/secrets/near-credentials"
  local legacy_dir="$config_dir/secrets/near"
  agent_has_near_credentials "$config_dir" && return 0
  [[ -d "$legacy_dir" ]] || return 0
  local legacy_json
  legacy_json="$(find "$legacy_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$legacy_json" ]] || return 0
  mkdir -p "$cred_dir"
  cp -a "$legacy_dir"/*.json "$cred_dir/" 2>/dev/null || cp "$legacy_json" "$cred_dir/"
  chmod 700 "$cred_dir"
  find "$cred_dir" -maxdepth 1 -name '*.json' -type f -exec chmod 600 {} +
  echo "    ($(basename "$config_dir" | sed 's/^\.openclaw-//'): migrated secrets/near → secrets/near-credentials/)" >&2
}

ensure_identyclaw_network() {
  command -v podman >/dev/null 2>&1 || return 0
  load_env
  if ! podman network exists "$IDENTYCLAW_NETWORK" 2>/dev/null; then
    echo "    (creating Podman network ${IDENTYCLAW_NETWORK})" >&2
    podman network create "$IDENTYCLAW_NETWORK" >/dev/null
  fi
}

agent_display_name() {
  load_env
  is_valid_agent_id "$1" || { echo "$1"; return 0; }
  agent_env_value "$1" DISPLAY_NAME "$1"
}

agent_ports() {
  local id="$1" gw br
  load_env
  is_valid_agent_id "$id" || { echo "unknown agent: $id" >&2; exit 1; }
  gw="$(agent_env_value "$id" GATEWAY_PORT "")"
  br="$(agent_env_value "$id" BRIDGE_PORT "")"
  [[ -n "$gw" && -n "$br" ]] || { echo "unknown agent: $id (set AGENT_*_GATEWAY_PORT / BRIDGE_PORT in env.local)" >&2; exit 1; }
  echo "$gw $br"
}

agent_internal_gateway_port() {
  local id="$1" ord_a ord_l
  load_env
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    is_valid_agent_id "$id" || { echo "unknown agent: $id" >&2; exit 1; }
    ord_a=$(printf '%d' "'a")
    ord_l="$(agent_letter_ord "$id")" || { echo "unknown agent: $id" >&2; exit 1; }
    echo $(( 18789 + (ord_l - ord_a) * 2 ))
  else
    echo "${OPENCLAW_CONTAINER_GATEWAY_PORT:-18789}"
  fi
}

# Pod agents chown state to the container uid; read the live gateway token from openclaw.json.
agent_gateway_token() {
  local id="$1"
  local config_dir config container
  config_dir="$(agent_home "$id")"
  config="${config_dir}/openclaw.json"
  if [[ -r "$config" ]]; then
    python3 - "$config" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)
print(cfg.get("gateway", {}).get("auth", {}).get("token", ""))
PY
    return 0
  fi
  container="$(agent_container "$id")"
  if command -v podman >/dev/null 2>&1 && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" python3 -c "
import json
with open('/home/node/.openclaw/openclaw.json', encoding='utf-8') as f:
    cfg = json.load(f)
print(cfg.get('gateway', {}).get('auth', {}).get('token', ''))
"
    return 0
  fi
  if [[ -r "${config_dir}/.env" ]]; then
    grep '^OPENCLAW_GATEWAY_TOKEN=' "${config_dir}/.env" | cut -d= -f2-
  fi
}

agent_public_host() {
  local id="$1"
  local host="" config_dir passport_host
  load_env
  is_valid_agent_id "$id" && host="$(agent_env_value "$id" PUBLIC_HOST "")"
  if ! is_valid_agent_id "$id"; then
    echo ""
    return 0
  fi
  if [[ -n "$host" ]]; then
    echo "$host"
    return 0
  fi
  if rodit_self_configure_enabled; then
    config_dir="$(agent_home "$id")"
    if agent_has_near_credentials "$config_dir"; then
      passport_host="$(rodit_passport_webhook_host "$config_dir" 2>/dev/null || true)"
      if [[ -n "$passport_host" ]]; then
        echo "$passport_host"
        return 0
      fi
    fi
  fi
  echo ""
}

agent_ingress_port() {
  local id="$1"
  load_env
  local explicit="" config_dir passport_port
  if ! is_valid_agent_id "$id"; then
    echo "${IDENTYCLAW_INGRESS_PORT}"
    return 0
  fi
  explicit="$(agent_env_value "$id" INGRESS_PORT "")"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  if rodit_self_configure_enabled; then
    config_dir="$(agent_home "$id")"
    if agent_has_near_credentials "$config_dir"; then
      passport_port="$(rodit_passport_webhook_port "$config_dir" 2>/dev/null || true)"
      if [[ -n "$passport_port" ]]; then
        echo "$passport_port"
        return 0
      fi
    fi
  fi
  echo "${IDENTYCLAW_INGRESS_PORT}"
}

agent_public_base_url() {
  local id="$1"
  local host port
  load_env
  host="$(agent_public_host "$id")"
  [[ -n "$host" ]] || return 0
  port="$(agent_ingress_port "$id")"
  echo "https://${host}:${port}"
}

# HTTPS ingress base for A2A + OpenClaw webhooks (pod mode). Same as agent_public_base_url.
agent_ingress_base_url() {
  agent_public_base_url "$1"
}

# Pod agents resolve their public ingress host to loopback so self-tests hit nginx in-pod
# (container DNS may differ from the host; e.g. agent-b.dev.identyclaw.com:7443).
pod_agent_ingress_host_args() {
  local id="$1" host
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  host="$(agent_public_host "$id")"
  [[ -n "$host" ]] && printf '%s\n' "--add-host=${host}:127.0.0.1"
}

# HTTPS ingress from inside the agent container (pod nginx listens on deploy-tier app port, e.g. 4443).
agent_container_ingress_base_url() {
  local id="$1"
  load_env
  local host tier port
  host="$(agent_public_host "$id")"
  [[ -n "$host" ]] || return 0
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    port="$(agent_ingress_port "$id")"
    echo "https://${host}:${port}"
    return 0
  fi
  agent_ingress_base_url "$id"
}

# Operator-facing Control UI / API base URL (HTTPS ingress in pod mode, loopback in standalone).
agent_ui_base_url() {
  local id="$1"
  load_env
  local ingress
  ingress="$(agent_ingress_base_url "$id")"
  if [[ -n "$ingress" ]]; then
    echo "$ingress"
    return 0
  fi
  local gw
  read -r gw _ < <(agent_ports "$id")
  echo "http://${PUBLISH_HOST}:${gw}"
}

agent_webhook_url() {
  local id="$1"
  local path="${2:-hooks/wake}"
  path="${path#/}"
  local base
  base="$(agent_ingress_base_url "$id")"
  if [[ -n "$base" ]]; then
    echo "${base}/${path}"
    return 0
  fi
  load_env
  local gw
  read -r gw _ < <(agent_ports "$id")
  echo "http://${PUBLISH_HOST}:${gw}/${path}"
}

agent_a2a_endpoint_url() {
  local id="$1"
  local base
  base="$(agent_a2a_public_base_url "$id")"
  if [[ -n "$base" ]]; then
    echo "${base}/a2a"
    return 0
  fi
  load_env
  local gw
  read -r gw _ < <(agent_ports "$id")
  echo "http://${PUBLISH_HOST}:${gw}/a2a"
}

agent_agent_card_public_url() {
  local id="$1"
  local base
  base="$(agent_a2a_public_base_url "$id")"
  if [[ -n "$base" ]]; then
    echo "${base}/.well-known/agent-card.json"
    return 0
  fi
  agent_agent_card_url "$id"
}

# Webhook ingress uses RODiT origin signatures (@rodit/rodit-auth-be), not hooks.token / HMAC.
rodit_webhook_auth_ready() {
  local id="$1"
  local config_dir
  config_dir="$(agent_home "$id")"
  agent_has_near_credentials "$config_dir"
}

print_agent_ingress_urls() {
  local id="$1"
  load_env
  local base card a2a wake agent_hook
  base="$(agent_ingress_base_url "$id")"
  if [[ -n "$base" ]]; then
    card="${base}/.well-known/agent-card.json"
    a2a="${base}/a2a"
    wake="${base}/hooks/wake"
    agent_hook="${base}/hooks/agent"
    echo "  ${id} ingress (${base}):"
    echo "    A2A discovery: ${card}"
    echo "    A2A messaging: POST ${a2a}  (Authorization: Bearer <RODiT JWT>)"
    echo "    Webhook wake:  POST ${wake}  (RODiT origin signature: x-signature + x-timestamp)"
    echo "    Webhook agent: POST ${agent_hook}  (RODiT origin signature: x-signature + x-timestamp)"
    if rodit_webhook_auth_ready "$id"; then
      echo "    Webhook auth: RODiT (@rodit/rodit-auth-be) — Ed25519 signed at origin; no hooks.token / HMAC"
    else
      echo "    Webhook auth: needs secrets/near-credentials/*.json for RODiT verification"
    fi
    return 0
  fi
  local gw
  read -r gw _ < <(agent_ports "$id")
  echo "  ${id} (standalone — loopback only unless tunneled):"
  echo "    Webhook wake:  POST http://${PUBLISH_HOST}:${gw}/hooks/wake"
  echo "    Webhook agent: POST http://${PUBLISH_HOST}:${gw}/hooks/agent"
  echo "    A2A:           POST http://${PUBLISH_HOST}:${gw}/a2a"
}

agent_id_from_dir() {
  basename "$1"
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

# Map container-namespace ownership back to the deploy user (rootless uid 0 in podman unshare).
restore_pod_path_for_host() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  podman unshare chown -R 0:0 "$path" 2>/dev/null || true
}

# Runtime mode follows the running container (pod vs keep-id standalone), not env alone.
agent_runtime_deploy_mode() {
  local id="$1"
  local container pod userns
  container="$(agent_container "$id")"
  pod="$(podman inspect "$container" --format '{{.HostConfig.Pod}}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    echo pod
    return 0
  fi
  userns="$(podman inspect "$container" --format '{{.HostConfig.Userns.Mode}}' 2>/dev/null || true)"
  if [[ "$userns" == "keep-id" ]]; then
    echo standalone
    return 0
  fi
  load_env
  echo "${IDENTYCLAW_DEPLOY_MODE:-standalone}"
}

# Pod agents map host state into the container user namespace (uid 1000 / node).
# Host CLI (token, status, bootstrap) needs the inverse — see restore_pod_agent_state_for_host.
ensure_pod_agent_state_for_container() {
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  [[ -n "${IDENTYCLAW_AGENT_STATE_ROOT:-}" ]] || return 0
  local ids=("$@")
  local id dir
  if [[ ${#ids[@]} -eq 0 ]]; then
    ids=(agent-a agent-b agent-d agent-f)
  fi
  for id in "${ids[@]}"; do
    dir="$(agent_home "$id")"
    [[ -d "$dir" ]] || continue
    podman unshare chown -R 1000:1000 "$dir"
    chmod 700 "$dir/secrets" 2>/dev/null || true
  done
}

# Standalone agents use --userns=keep-id; state must be owned by the deploy user on the host.
# Repairs dirs that were accidentally chowned for pod mode (subuid) so gateway/TUI can read sessions.
ensure_standalone_agent_state_for_container() {
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" != "pod" ]] || return 0
  local ids=("$@")
  local id dir uid gid
  uid="$(id -u)"
  gid="$(id -g)"
  if [[ ${#ids[@]} -eq 0 ]]; then
    ids=(agent-a agent-b agent-d agent-f)
  fi
  for id in "${ids[@]}"; do
    dir="$(agent_home "$id")"
    [[ -d "$dir" ]] || continue
    if ! chown -R "${uid}:${gid}" "$dir" 2>/dev/null; then
      podman unshare chown -R 0:0 "$dir" 2>/dev/null || true
    fi
    chmod 700 "$dir/secrets" 2>/dev/null || true
  done
}

# Gateway restart leaves orphaned session locks; clear them only while the container is stopped.
remove_stale_session_locks() {
  local config_dir="$1"
  local sessions_root="$config_dir/agents"
  [[ -d "$sessions_root" ]] || return 0
  find "$sessions_root" -name '*.jsonl.lock' -type f -delete 2>/dev/null || true
}

# Normalize ownership + drop stale locks before (re)starting a gateway container.
prepare_agent_state_for_gateway_start() {
  local id="$1"
  local mode="${2:-}"
  local dir
  dir="$(agent_home "$id")"
  [[ -n "$mode" ]] || mode="${IDENTYCLAW_DEPLOY_MODE:-standalone}"
  if [[ "$mode" == "pod" ]]; then
    ensure_pod_agent_state_for_container "$id"
  else
    ensure_standalone_agent_state_for_container "$id"
  fi
  remove_stale_session_locks "$dir"
}

# Ensure the container user can read/write state before podman exec (gateway already running).
ensure_agent_state_for_container_exec() {
  local id="$1"
  local mode
  mode="$(agent_runtime_deploy_mode "$id")"
  if [[ "$mode" == "pod" ]]; then
    ensure_pod_agent_state_for_container "$id"
  else
    ensure_standalone_agent_state_for_container "$id"
  fi
}

# Nginx sidecar logs run as uid 101 inside the container user namespace.
ensure_pod_logs_for_container() {
  local log_dir="$1"
  mkdir -p "$log_dir"
  chmod 0775 "$log_dir" 2>/dev/null || true
  podman unshare chown -R 101:101 "$log_dir" 2>/dev/null || true
}

# Restore ownership so the deploy user can read/write agent state on the host.
# Skip agents whose gateway is running — restore races with pod container uid (1000).
restore_pod_agent_state_for_host() {
  AGENT_IDS="${1:-${AGENT_IDS:-agent-a agent-b}}"
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  [[ -n "${IDENTYCLAW_AGENT_STATE_ROOT:-}" ]] || return 0
  local id dir container
  for id in $AGENT_IDS; do
    dir="$(agent_home "$id")"
    [[ -d "$dir" ]] || continue
    container="$(agent_container "$id")"
    # Keep container-namespace ownership while the podman container exists (running or exited).
    if command -v podman >/dev/null 2>&1 && podman container exists "$container" 2>/dev/null; then
      continue
    fi
    restore_pod_path_for_host "$dir"
  done
}

# Before host-side deploy writes (config bootstrap, mkdir, chmod), undo container-namespace
# ownership left by the previous pod run. Call after stopping/removing pod containers.
prepare_pod_deploy_host_paths() {
  local app
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  app="${IDENTYCLAW_APP_DIR:-${APP_DIR:-}}"
  [[ -n "$app" ]] || return 0
  echo "==> Restore host ownership for pod deploy paths"
  restore_pod_agent_state_for_host
  restore_pod_path_for_host "${app}/logs/nginx"
}

# Host restore (0:0) and container access (1000:1000) conflict in pod userns — skip restore for exec-only commands.
identyclaw_skips_host_restore() {
  case "${1:-}" in
    chat|ask|logs|test-mail|test-a2a|test-webhook|test-webhook-p2p|send-rodit-webhook|upgrade-plugins|sync-a2a-peers|build-image|start|restart|stop|status|""|-h|--help|help) return 0 ;;
    *) return 1 ;;
  esac
}

# Standalone start/restart touches host-owned openclaw.json; pod deploy uses container-namespace ownership.
# Pod mode: identyclaw.sh start → start_pod_agent (start); restart → start_pod_agent (restart).

# Read AGENT_IDS from env.local (used by deploy.yml host prep and deploy-pod.sh).
deploy_agent_ids_from_env() {
  local app_dir="${1:-}"
  local env_file ids line
  load_env
  if [[ -n "$app_dir" ]]; then
    env_file="${app_dir}/env.local"
  else
    env_file="$(identyclaw_env_file)"
  fi
  ids="${AGENT_IDS:-agent-a agent-b}"
  if [[ -f "$env_file" ]]; then
    line="$(grep -E '^AGENT_IDS=' "$env_file" 2>/dev/null | head -1 || true)"
    if [[ -n "$line" ]]; then
      ids="${line#AGENT_IDS=}"
      ids="${ids%\"}"
      ids="${ids#\"}"
      ids="${ids%\'}"
      ids="${ids#\'}"
    fi
  fi
  echo "$ids"
}

# Start or restart a pod-managed agent without host-side bootstrap (avoids openclaw.json EACCES).
# Second arg: start (idempotent — no-op if running) or restart (bounce gateway if running).
start_pod_agent() {
  local id="$1"
  local mode="${2:-restart}"
  local container dir
  load_env
  container="$(agent_container "$id")"
  dir="$(agent_home "$id")"

  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    if [[ "$mode" == "start" ]]; then
      echo "Already running: ${container} (use './identyclaw.sh restart ${id}' to bounce the gateway)"
      return 0
    fi
    echo "==> ${id} already running in pod — syncing A2A config and restarting gateway"
    sync_a2a_peers_from_logs "$id" || true
    ensure_agent_state_for_container_exec "$id"
    ensure_openclaw_model_defaults "$dir" "$container"
    ensure_session_memory_hook "$dir" "$container"
    sync_agent_plugin_configs "$id" "$dir" || true
    podman restart "$container" >/dev/null
    ensure_discord_plugin_compat_and_restart "$id"
    echo "Restarted ${container}"
    return 0
  fi

  if podman container exists "$container" 2>/dev/null; then
    prepare_agent_state_for_gateway_start "$id" pod
    podman start "$container"
    ensure_discord_plugin_compat_and_restart "$id"
    echo "Started ${container} (pod container)"
    return 0
  fi

  # No pod container yet — host must have agent state (readable or not) before first deploy.
  [[ -d "$dir" ]] || {
    echo "Missing ${dir} — run deploy or ./identyclaw.sh init ${id}" >&2
    return 1
  }
  echo "No pod container for ${id}. Run:" >&2
  echo "  ./scripts/deploy-local-podman.sh" >&2
  return 1
}

sync_deploy_scripts_to_app_dir() {
  local repo_root="${1:?repo root}"
  local app_dir="${2:?app dir}"
  mkdir -p "${app_dir}/repo/scripts"
  cp -a "${repo_root}/scripts/." "${app_dir}/repo/scripts/"
  cp -a "${repo_root}/identyclaw.sh" "${repo_root}/env.example" "${app_dir}/repo/"
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
  is_valid_agent_id "$id" || { echo "unknown agent: $id" >&2; return 1; }
  echo "$(agent_env_value "$id" EMAIL "")|$(agent_env_value "$id" DISPLAY_NAME "$id")"
}

ensure_mail_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local password=""
  load_env
  is_valid_agent_id "$id" && password="$(agent_env_value "$id" PASSWORD "")"
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
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
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
if guild.get("requireMention") is not True:
    guild["requireMention"] = True
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
if ch.get("requireMention") is not True:
    ch["requireMention"] = True
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

sync_identyclaw_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  local cred_file contract_id
  load_env
  contract_id="${IDENTYCLAW_NEAR_CONTRACT_ID}"
  ensure_near_credentials_in_agent "$config_dir" || return 0
  cred_file="$(resolve_near_credentials_file "$config_dir")" || return 0
  python3 - "$cred_file" "$env_file" "$contract_id" <<'PY'
import json, os, sys
from pathlib import Path

cred_file, env_file, contract_id = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
creds = json.loads(cred_file.read_text(encoding="utf-8"))
account_id = creds.get("implicit_account_id") or creds.get("account_id", "")
private_key = creds.get("private_key", "")
if not account_id or not private_key:
    raise SystemExit(0)

container_cred_path = f"/home/node/.openclaw/secrets/near-credentials/{account_id}.json"

strip_prefixes = (
    "IDENTYCLAW_ACCOUNT_ID=",
    "IDENTYCLAW_NEAR_PRIVATE_KEY=",
    "IDENTYCLAW_BASE_URL=",
    "NEAR_CONTRACT_ID=",
    "RODIT_NEAR_CREDENTIALS_SOURCE=",
    "NEAR_CREDENTIALS_FILE_PATH=",
    "NEAR_CREDENTIALS_JSON_B64=",
)
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(strip_prefixes)]

lines.append("IDENTYCLAW_BASE_URL=https://api.identyclaw.com\n")
lines.append(f"IDENTYCLAW_ACCOUNT_ID={account_id}\n")
lines.append(f"IDENTYCLAW_NEAR_PRIVATE_KEY={private_key}\n")
lines.append(f"NEAR_CONTRACT_ID={contract_id}\n")
lines.append("RODIT_NEAR_CREDENTIALS_SOURCE=file\n")
lines.append(f"NEAR_CREDENTIALS_FILE_PATH={container_cred_path}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}

sync_quiet_plugin_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  load_env
  python3 - "$env_file" "$IDENTYCLAW_NEAR_CONTRACT_ID" <<'PY'
import os, sys
from pathlib import Path

env_file = Path(sys.argv[1])
near_contract_id = sys.argv[2]
desired = {
    "LOG_LEVEL": "error",
    "SUPPRESS_NO_CONFIG_WARNING": "true",
    "SUPPRESS_STRICTNESS_CHECK": "true",
    "NEAR_CONTRACT_ID": near_contract_id,
}
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if ln.split("=", 1)[0] not in desired]
for key, value in desired.items():
    lines.append(f"{key}={value}\n")
env_file.parent.mkdir(parents=True, exist_ok=True)
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}

write_agent_identyclaw_doc() {
  local id="$1"
  local config_dir="$2"
  local display_name peers has_a2a=""
  load_env
  display_name="$(agent_display_name "$id")"
  mkdir -p "$config_dir/workspace"
  if agent_has_near_credentials "$config_dir"; then
    has_a2a="yes"
    peers="$(a2a_configured_peer_token_ids)"
  fi
  local own_token_id=""
  if [[ "$has_a2a" == "yes" ]]; then
    own_token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  fi
  cat >"$config_dir/workspace/IDENTYCLAW.md" <<EOF
# IdentyClaw identity + A2A peer messaging

This agent uses **two** published integrations. Use the right one for the job:

| Need | Use | Source |
|------|-----|--------|
| HOLA verify, Passport lookup, DID, API cheat sheet | **identyclaw** skill + \`identyclaw_*\` tools | [ClawHub: identyclaw/identyclaw](https://clawhub.ai/identyclaw/identyclaw) |
| Message another OpenClaw agent (tasks, files, multi-turn) | **a2a_*** tools | [ClawHub: @identyclaw/openclaw-a2a-plugin](https://clawhub.ai/plugins/@identyclaw/openclaw-a2a-plugin) |

## IdentyClaw (ClawHub skill + plugin)

- **Skill:** \`identyclaw\` — workflows for JWT login, HOLA create/verify, DID resolution, agent discovery. Read \`SKILL.md\` when handling identity.
- **Plugin:** \`identyclaw-tools\` — typed tools (\`identyclaw_verify_hola\`, \`identyclaw_list_agents\`, …). Passport signing key stays local; never paste keys into chat.
- **API base:** \`https://api.identyclaw.com\`
- **Credentials:** \`secrets/near-credentials/*.json\` → synced to \`.env\` as \`IDENTYCLAW_*\` plus \`RODIT_NEAR_CREDENTIALS_SOURCE=file\` and \`NEAR_CREDENTIALS_FILE_PATH\` for \`@rodit/rodit-auth-be\`.

### First contact from an unknown agent (HOLA)

1. \`identyclaw_verify_hola\` on the exact inbound HOLA string — trust only when \`verified: true\`.
2. Note \`peerTokenId\` (12-letter Passport ID).
3. \`identyclaw_get_agent_identity\` (or \`identyclaw_list_agents\` + lookup) for DN, \`contactUri\`, traits.
4. **Impersonation guard:** reject if verified \`peerTokenId\` ≠ the ID the entity officially publishes on channels they control.

For outbound HOLA, prefer \`identyclaw_create_hola\` (plugin v1.3.0+) or follow the skill’s HOLA section — fetch a **new** nonce immediately before each HOLA you sign.

## A2A (ClawHub plugin — RODiT JWT)

- **Plugin id:** \`identyclaw-a2a\` — installed from \`${IDENTYCLAW_CLAWHUB_A2A_PLUGIN}\` on bootstrap when Passport credentials exist.
- **Auth:** RODiT / Passport JWT (no static A2A API keys). Outbound login uses \`IDENTYCLAW_*\` env vars; inbound validates \`iss\` + \`aud\` + \`token_id\`.
- **Display name:** ${display_name}
EOF
  if [[ -n "$own_token_id" ]]; then
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<EOF
- **Passport token_id (this agent):** \`${own_token_id}\` — use as the canonical A2A peer id in \`a2a_send_message\`, \`send_rodit_webhook\`, and \`outbound.agents\`.
EOF
  fi
  if [[ "$has_a2a" == "yes" ]]; then
    local open_p2p_note=""
    if a2a_open_p2p_enabled; then
      open_p2p_note="
- **Open P2P:** inbound accepts any Passport holder via \`POST /api/login\` + \`POST /a2a\`. Outbound peers are registered dynamically from inbound JWT \`rodit_webhookurl\` (no \`A2A_PEER_AGENTS\` required for callbacks)."
    elif a2a_dynamic_peers_from_jwt_enabled; then
      open_p2p_note="
- **Dynamic peers:** outbound entries are upserted from inbound JWT \`rodit_webhookurl\` after successful auth (keyed by Passport \`token_id\`)."
    fi
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<EOF
- **Configured peers (Passport token_id):** ${peers:-none} — keys in \`plugins.entries.identyclaw-a2a.config.outbound.agents\`; URLs from \`A2A_PEER_URLS\` in env.local.${open_p2p_note}

### A2A tools

| Tool | Purpose |
|------|---------|
| \`a2a_get_agents\` | List configured remote agents (Passport \`token_id\` keys) |
| \`a2a_send_message\` | Send message/files to a peer by \`token_id\`; returns \`context_id\` / \`task_id\` |
| \`a2a_get_task\` | Poll long-running peer tasks |
| \`a2a_update_agent_card\` | Update this agent’s public Agent Card |
| \`send_rodit_webhook\` | After a delay (default 10s), sign and POST \`/hooks/wake\` to a peer \`token_id\` from \`outbound.agents\` |

For unknown senders: \`identyclaw_verify_hola\` before trusting chat claims. Open P2P inbound does not replace HOLA for impersonation checks. To message a never-seen peer proactively, use \`identyclaw_get_agent_identity\` / \`identyclaw_list_agents\` for discovery; they must expose a public Agent Card and accept P2P login.
EOF
  else
    cat >>"$config_dir/workspace/IDENTYCLAW.md" <<'EOF'
- **A2A:** not configured — add `secrets/near-credentials/*.json` and restart to enable peer messaging.
EOF
  fi
  chmod 644 "$config_dir/workspace/IDENTYCLAW.md"
}

identyclaw_skill_installed_in_container() {
  local container="$1"
  podman exec "$container" sh -c \
    'test -f /home/node/.openclaw/workspace/skills/identyclaw/SKILL.md \
      || test -f /home/node/.openclaw/skills/identyclaw/SKILL.md' 2>/dev/null
}

ensure_identyclaw_config() {
  local config_dir="$1"
  local container="${2:-}"
  local config cred_dir has_creds=0 cred_path=""
  config="$config_dir/openclaw.json"
  cred_dir="$config_dir/secrets/near-credentials"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  if [[ -d "$cred_dir" ]] && [[ -n "$(find "$cred_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)" ]]; then
    has_creds=1
    cred_path="$(agent_near_cred_path_for_config_sync "$config_dir" "$container")"
    sync_identyclaw_env "$config_dir"
  fi
  _agent_openclaw_json_python "$config_dir" "$container" "$has_creds" "$cred_path" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
has_creds = sys.argv[2] == "1"
cred_path = sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

skills = data.setdefault("skills", {}).setdefault("entries", {})
if skills.get("identyclaw", {}).get("enabled") is not True:
    skills["identyclaw"] = {"enabled": True}
    changed = True

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
entry = plugins.setdefault("identyclaw-tools", {})
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True
cfg = entry.setdefault("config", {})
if cfg.get("baseUrl") != "https://api.identyclaw.com":
    cfg["baseUrl"] = "https://api.identyclaw.com"
    changed = True

if has_creds and cred_path:
    creds = json.loads(Path(cred_path).read_text(encoding="utf-8"))
    account_id = creds.get("implicit_account_id") or creds.get("account_id", "")
    private_key = creds.get("private_key", "")
    if account_id and private_key:
        if cfg.get("accountid") != account_id:
            cfg["accountid"] = account_id
            changed = True
        if cfg.get("nearPrivateKey") != private_key:
            cfg["nearPrivateKey"] = private_key
            changed = True

identyclaw_tools = [
    "identyclaw_list_agents",
    "identyclaw_list_resources",
    "identyclaw_get_resource",
]
if has_creds:
    identyclaw_tools.extend([
        "identyclaw_get_my_identity",
        "identyclaw_get_nonce",
        "identyclaw_create_hola",
        "identyclaw_verify_hola",
        "identyclaw_get_agent_identity",
        "identyclaw_check_subagent_signer",
        "identyclaw_resolve_did",
    ])
allow = data.setdefault("tools", {}).setdefault("allow", [])
for tool in identyclaw_tools:
    if tool not in allow:
        allow.append(tool)
        changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

ensure_identyclaw_packages() {
  local id="$1"
  local container config_dir skill_spec
  load_env
  container="$(agent_container "$id")"
  config_dir="$(agent_home "$id")"
  skill_spec="${IDENTYCLAW_CLAWHUB_SKILL}"

  if ! install_identyclaw_plugin "$config_dir" 0 "$id"; then
    echo "    (${id}: IdentyClaw plugin install skipped — see errors above)" >&2
  fi

  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  ensure_openclaw_cli_link "$container"
  link_identyclaw_plugin_deps_in_container "$container"
  podman exec "$container" node /app/openclaw.mjs plugins registry --refresh >&2 || true
  if ! identyclaw_skill_installed_in_container "$container"; then
    echo "    (${id}: installing ClawHub skill ${skill_spec} from identyclaw/identyclaw…)" >&2
    if ! podman exec "$container" node /app/openclaw.mjs skills install "$skill_spec" >&2; then
      podman exec "$container" node /app/openclaw.mjs skills install identyclaw >&2 || true
    fi
  fi
}

ensure_a2a_plugin_build() {
  local id="$1"
  local config_dir container
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  agent_has_near_credentials "$config_dir" || return 0
  install_a2a_plugin "$config_dir" 0 "$id"
  install_identyclaw_webhooks_plugin "$config_dir" 0 "$id" || true
  ensure_webhooks_plugin_config "$config_dir" "$container"
}

ensure_agent_packages() {
  local id="$1"
  ensure_identyclaw_packages "$id"
  ensure_a2a_packages "$id"
}

ensure_agent_identyclaw_tooling() {
  local id="$1"
  local config_dir="$2"
  write_agent_identyclaw_doc "$id" "$config_dir"
}

build_a2a_peer_map() {
  local self_id="$1"
  local self_config_dir self_token_id
  load_env
  warn_invalid_a2a_peer_agents
  self_config_dir="$(agent_home "$self_id")"
  self_token_id="$(probe_rodit_own_token_id "$self_config_dir" 2>/dev/null || true)"

  local peer_token_id public_base card_url peers_json="{"
  local first=1
  for peer_token_id in $A2A_PEER_AGENTS; do
    is_passport_token_id "$peer_token_id" || continue
    [[ -n "$self_token_id" && "$peer_token_id" == "$self_token_id" ]] && continue

    public_base="$(a2a_peer_public_base_url "$peer_token_id")"
    card_url="$(a2a_peer_agent_card_url "$peer_token_id" 2>/dev/null || true)"
    if [[ -z "$public_base" || -z "$card_url" ]]; then
      echo "    (${self_id}: skip peer ${peer_token_id} — no URL in A2A_PEER_URLS)" >&2
      continue
    fi
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      peers_json+=","
    fi
    peers_json+="\"${peer_token_id}\":{\"url\":\"${card_url}\""
    peers_json+=",\"loginBaseUrl\":\"${public_base}\""
    peers_json+="}"
  done
  peers_json+="}"
  echo "$peers_json"
}

ensure_a2a_config() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  agent_has_near_credentials "$config_dir" || return 0

  load_env
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  if [[ -w "$config_dir/.env" ]] 2>/dev/null; then
    sync_identyclaw_env "$config_dir"
  fi

  a2a_warn_legacy_auth_mode_env "$id"

  local audience display_name public_base_url peers_json dynamic_peers_from_jwt own_token_id
  audience="$(agent_a2a_audience "$id" "$config_dir" "$container")"
  display_name="$(agent_display_name "$id")"
  public_base_url="$(agent_a2a_public_base_url "$id")"
  own_token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  sync_rodit_token_id_env "$config_dir"
  peers_json="$(build_a2a_peer_map "$id")"
  dynamic_peers_from_jwt="0"
  if a2a_dynamic_peers_from_jwt_enabled; then
    dynamic_peers_from_jwt="1"
  fi

  _agent_openclaw_json_python "$config_dir" "$container" \
    "$audience" "$display_name" "$public_base_url" "$peers_json" \
    "$IDENTYCLAW_API_BASE_URL" "$dynamic_peers_from_jwt" "$own_token_id" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
audience = sys.argv[2]
display_name = sys.argv[3]
public_base_url = sys.argv[4]
peers = json.loads(sys.argv[5])
issuer = sys.argv[6]
dynamic_peers_from_jwt = sys.argv[7] == "1"
own_token_id = sys.argv[8] if len(sys.argv) > 8 else ""

data = json.loads(path.read_text(encoding="utf-8"))
changed = False

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
legacy = plugins.pop("a2a", None)
entry = plugins.setdefault("identyclaw-a2a", {})
if legacy:
    if legacy.get("enabled") is True:
        entry["enabled"] = True
    legacy_cfg = legacy.get("config") or {}
    merged_cfg = entry.setdefault("config", {})
    for key, value in legacy_cfg.items():
        if key not in merged_cfg:
            merged_cfg[key] = value
    changed = True
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True

cfg = entry.setdefault("config", {})
inbound = cfg.setdefault("inbound", {})
outbound = cfg.setdefault("outbound", {})

if inbound.get("allowUnauthenticated") is not False:
    inbound["allowUnauthenticated"] = False
    changed = True

auth = inbound.setdefault("auth", {})
desired_auth = {
    "provider": "rodit",
    "issuer": issuer,
    "audience": audience,
    "identityClaim": "token_id",
}
for key, value in desired_auth.items():
    if auth.get(key) != value:
        auth[key] = value
        changed = True
for stale in ("mode", "p2pAudience", "p2pIssuer"):
    if stale in auth:
        del auth[stale]
        changed = True

rodit_login = inbound.setdefault("roditLogin", {})
desired_login = {"enabled": True, "loginMode": "promiscuous"}
for key, value in desired_login.items():
    if rodit_login.get(key) != value:
        rodit_login[key] = value
        changed = True

card = inbound.setdefault("agentCard", {})
if card.get("name") != display_name:
    card["name"] = display_name
    changed = True
card_desc = f"{display_name} (IdentyClaw A2A)"
if own_token_id:
    card_desc = f"{display_name} (IdentyClaw A2A, token_id={own_token_id})"
if card.get("description") != card_desc:
    card["description"] = card_desc
    changed = True

if public_base_url:
    if inbound.get("publicBaseUrl") != public_base_url:
        inbound["publicBaseUrl"] = public_base_url
        changed = True
elif "publicBaseUrl" in inbound:
    del inbound["publicBaseUrl"]
    changed = True

out_auth = outbound.setdefault("auth", {})
desired_out_auth = {
    "provider": "rodit",
    "jwtCacheTtlSeconds": 300,
}
for key, value in desired_out_auth.items():
    if out_auth.get(key) != value:
        out_auth[key] = value
        changed = True
for stale in ("mode", "credentialsEnv"):
    if stale in out_auth:
        del out_auth[stale]
        changed = True

if outbound.get("tlsSkipVerify") is not True:
    outbound["tlsSkipVerify"] = True
    changed = True

# 0.4.0+ uses resolvePeersByTokenId / persistResolvedPeers (dynamicPeersFromJwt was patch-only).
if outbound.pop("dynamicPeersFromJwt", None) is not None:
    changed = True

if dynamic_peers_from_jwt:
    if outbound.get("resolvePeersByTokenId") is not True:
        outbound["resolvePeersByTokenId"] = True
        changed = True
    if outbound.get("persistResolvedPeers") is not True:
        outbound["persistResolvedPeers"] = True
        changed = True
else:
    if outbound.get("resolvePeersByTokenId") is not False:
        outbound["resolvePeersByTokenId"] = False
        changed = True
    if outbound.pop("persistResolvedPeers", None) is not None:
        changed = True

if peers:
    existing_agents = outbound.get("agents", {})
    if existing_agents != peers:
        outbound["agents"] = peers
        changed = True
elif dynamic_peers_from_jwt:
    if outbound.get("agents") != {}:
        outbound["agents"] = {}
        changed = True
elif "agents" in outbound:
    del outbound["agents"]
    changed = True

# identyclaw-webhooks still reads legacy plugins.entries.a2a for outbound peers.
if outbound:
    legacy_stub = plugins.setdefault("a2a", {})
    if legacy_stub.get("enabled") is True:
        legacy_stub.pop("enabled", None)
        changed = True
    legacy_cfg = legacy_stub.setdefault("config", {})
    mirrored_outbound = json.loads(json.dumps(outbound))
    if legacy_cfg.get("outbound") != mirrored_outbound:
        legacy_cfg["outbound"] = mirrored_outbound
        changed = True

a2a_tools = [
    "a2a_get_agents",
    "a2a_get_agent",
    "a2a_send_message",
    "a2a_get_task",
    "a2a_view_text_artifact",
    "a2a_view_data_artifact",
    "a2a_update_agent_card",
]
allow = data.setdefault("tools", {}).setdefault("allow", [])
for tool in a2a_tools:
    if tool not in allow:
        allow.append(tool)
        changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY

  if [[ -n "$peers_json" && "$peers_json" != "{}" ]]; then
    sync_a2a_tls_env "$config_dir"
  fi
}

copy_openclaw_plugin_tree() {
  local build_dir="$1"
  local ext_dir="$2"
  shift 2
  local item

  rm -rf "$ext_dir"
  mkdir -p "$ext_dir"
  for item in "$@"; do
    cp -a "$build_dir/$item" "$ext_dir/"
  done
  mkdir -p "$ext_dir/node_modules"
  rm -rf "$ext_dir/node_modules/openclaw"
  ln -sf /app "$ext_dir/node_modules/openclaw"
}

build_git_plugin() {
  local repo="$1"
  local build_dir="$2"
  local build_cmd="${3:-build}"

  command -v git >/dev/null 2>&1 || {
    echo "    (plugin: git required to clone ${repo})" >&2
    return 1
  }
  command -v npm >/dev/null 2>&1 || {
    echo "    (plugin: npm required to build ${repo})" >&2
    return 1
  }

  rm -rf "$build_dir"
  git clone --depth 1 "$repo" "$build_dir" >&2 || return 1
  (
    cd "$build_dir"
    npm install >&2
    npm run "$build_cmd" >&2
  ) || true
}

# Remove legacy dynamicPeersFromJwt so ClawHub install can validate config (0.4.0+ schema).
strip_a2a_dynamic_peers_config_for_install() {
  local config_dir="$1"
  local container="${2:-}"
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
outbound = (
    data.get("plugins", {})
    .get("entries", {})
    .get("identyclaw-a2a", {})
    .get("config", {})
    .get("outbound", {})
)
changed = False
if outbound.pop("dynamicPeersFromJwt", None) is not None:
    changed = True
legacy_outbound = (
    data.get("plugins", {})
    .get("entries", {})
    .get("a2a", {})
    .get("config", {})
    .get("outbound", {})
)
if isinstance(legacy_outbound, dict) and legacy_outbound.pop("dynamicPeersFromJwt", None) is not None:
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

webhooks_plugin_id() {
  echo "identyclaw-webhooks"
}

agent_webhooks_ext_dir() {
  echo "$1/extensions/$(webhooks_plugin_id)"
}

agent_webhooks_ext_dir_container() {
  echo "/home/node/.openclaw/extensions/$(webhooks_plugin_id)"
}

webhooks_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    pkg="$(agent_webhooks_ext_dir_container)/package.json"
    pkg_json="$(podman exec "$container" cat "$pkg" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  pkg="$(agent_webhooks_ext_dir "$config_dir")/package.json"
  [[ -f "$pkg" ]] || return 0
  python3 - "$pkg" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8")).get("version", ""))
PY
}

webhooks_ext_ready() {
  local config_dir="$1"
  local container="${2:-}"
  local ext_dir
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" test \
      -f "$(agent_webhooks_ext_dir_container)/openclaw.plugin.json" \
      -a -f "$(agent_webhooks_ext_dir_container)/dist/index.js"
    return $?
  fi
  ext_dir="$(agent_webhooks_ext_dir "$config_dir")"
  [[ -f "$ext_dir/openclaw.plugin.json" && -f "$ext_dir/dist/index.js" ]]
}

install_identyclaw_webhooks_plugin() {
  local config_dir="$1"
  local force="${2:-0}"
  local id="${3:-}"
  local container ext_dir plugin_spec desired_ver installed_ver
  ext_dir="$(agent_webhooks_ext_dir "$config_dir")"
  load_env
  plugin_spec="${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN}"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""
  agent_has_near_credentials "$config_dir" || return 0

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(webhooks_plugin_installed_version "$config_dir" "$container")"

  if [[ "$force" != "1" && -n "$desired_ver" && "$installed_ver" == "$desired_ver" ]] \
    && webhooks_ext_ready "$config_dir" "$container"; then
    if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
      link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
    else
      link_identyclaw_webhooks_plugin_deps "$ext_dir"
    fi
    return 0
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
      podman exec "$container" rm -rf \
        "$(agent_webhooks_ext_dir_container)" \
        /home/node/.openclaw/.identyclaw-webhooks-plugin-build 2>/dev/null || true
    else
      rm -rf "$ext_dir" "$config_dir/.identyclaw-webhooks-plugin-build" 2>/dev/null || true
    fi
  fi

  echo "    (installing IdentyClaw webhooks plugin from ${plugin_spec}…)" >&2
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=()
  if [[ "$force" == "1" || ( -n "$desired_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    install_args+=(--force)
  fi
  if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
    return 1
  fi
  webhooks_ext_ready "$config_dir" "$container" || {
    echo "    (identyclaw-webhooks: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
  else
    link_identyclaw_webhooks_plugin_deps "$ext_dir"
  fi
}

ensure_webhooks_plugin_config() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  agent_has_near_credentials "$config_dir" || return 0

  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
legacy = plugins.pop("rodit-webhooks", None)
entry = plugins.setdefault("identyclaw-webhooks", {})
if legacy:
    if legacy.get("enabled") is True:
        entry["enabled"] = True
    legacy_cfg = legacy.get("config") or {}
    merged_cfg = entry.setdefault("config", {})
    for key, value in legacy_cfg.items():
        if key not in merged_cfg:
            merged_cfg[key] = value
    changed = True
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True
cfg = entry.setdefault("config", {})
desired = {
    "endpoints": ["/hooks/wake", "/hooks/agent"],
    "logLevel": "error",
}
for key, value in desired.items():
    if cfg.get(key) != value:
        cfg[key] = value
        changed = True

allow = data.setdefault("tools", {}).setdefault("allow", [])
if "send_rodit_webhook" not in allow:
    allow.append("send_rodit_webhook")
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

install_a2a_plugin() {
  local config_dir="$1"
  local force="${2:-0}"
  local id="${3:-}"
  local container ext_dir plugin_spec desired_ver installed_ver
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  load_env
  plugin_spec="${IDENTYCLAW_CLAWHUB_A2A_PLUGIN}"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""
  agent_has_near_credentials "$config_dir" || return 0

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(a2a_plugin_installed_version "$config_dir" "$container")"

  if [[ "$force" != "1" && -n "$desired_ver" && "$installed_ver" == "$desired_ver" ]] \
    && a2a_ext_ready "$config_dir" "$container"; then
    migrate_legacy_a2a_extension "$config_dir" "$container"
    [[ -n "$id" ]] && ensure_a2a_config "$id" "$config_dir" "$container" || true
    return 0
  fi

  migrate_legacy_a2a_extension "$config_dir" "$container"
  if [[ "$force" == "1" ]]; then
    if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
      podman exec "$container" rm -rf "$(agent_a2a_ext_dir_container)" 2>/dev/null || true
    else
      rm -rf "$ext_dir" 2>/dev/null || true
    fi
  fi

  echo "    (installing A2A plugin from ${plugin_spec}…)" >&2
  strip_a2a_dynamic_peers_config_for_install "$config_dir" "$container"
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=()
  [[ "$force" == "1" ]] && install_args+=(--force)
  if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
    return 1
  fi
  a2a_ext_ready "$config_dir" "$container" || {
    echo "    (identyclaw-a2a: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
  fi

  [[ -n "$id" ]] && ensure_a2a_config "$id" "$config_dir" "$container" || true
}

openclaw_agent_image() {
  load_env
  echo "${OPENCLAW_IMAGE:-${OPENCLAW_LOCAL_IMAGE:-${OPENCLAW_BASE_IMAGE}}}"
}

# Run OpenClaw CLI against an agent state dir (live container or ephemeral podman run).
openclaw_agent_exec() {
  local config_dir="$1"
  local container="$2"
  shift 2
  local z image
  load_env
  z="$(selinux_mount_suffix)"
  image="$(openclaw_agent_image)"

  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    ensure_openclaw_cli_link "$container"
    podman exec "$container" env OPENCLAW_STATE_DIR=/home/node/.openclaw \
      node /app/openclaw.mjs "$@"
    return $?
  fi

  podman run --rm --userns=keep-id \
    -e HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/home/node/.openclaw \
    -v "${config_dir}:/home/node/.openclaw:rw${z}" \
    "$image" \
    node /app/openclaw.mjs "$@"
}

link_identyclaw_plugin_deps_in_container() {
  local container="$1"
  podman exec "$container" bash -c '
    set -euo pipefail
    ext="/home/node/.openclaw/extensions/identyclaw-tools"
    [[ -d "$ext" ]] || exit 0
    mkdir -p "$ext/node_modules"
    rm -rf "$ext/node_modules/openclaw"
    ln -sf /app "$ext/node_modules/openclaw"
  ' 2>/dev/null || true
}

identyclaw_tools_plugin_id() {
  echo "identyclaw-tools"
}

agent_identyclaw_tools_ext_dir() {
  echo "$1/extensions/$(identyclaw_tools_plugin_id)"
}

agent_identyclaw_tools_ext_dir_container() {
  echo "/home/node/.openclaw/extensions/$(identyclaw_tools_plugin_id)"
}

identyclaw_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    pkg="$(agent_identyclaw_tools_ext_dir_container)/package.json"
    pkg_json="$(podman exec "$container" cat "$pkg" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  pkg="$(agent_identyclaw_tools_ext_dir "$config_dir")/package.json"
  [[ -f "$pkg" ]] || return 0
  python3 - "$pkg" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8")).get("version", ""))
PY
}

identyclaw_tools_ext_ready() {
  local config_dir="$1"
  local container="${2:-}"
  local ext_dir
  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    podman exec "$container" test \
      -f "$(agent_identyclaw_tools_ext_dir_container)/openclaw.plugin.json" \
      -a -f "$(agent_identyclaw_tools_ext_dir_container)/dist/index.js"
    return $?
  fi
  ext_dir="$(agent_identyclaw_tools_ext_dir "$config_dir")"
  [[ -f "$ext_dir/openclaw.plugin.json" && -f "$ext_dir/dist/index.js" ]]
}

install_identyclaw_plugin() {
  local config_dir="$1"
  local force="${2:-0}"
  local id="${3:-}"
  local container ext_dir plugin_spec desired_ver installed_ver
  ext_dir="$(agent_identyclaw_tools_ext_dir "$config_dir")"
  load_env
  plugin_spec="${IDENTYCLAW_CLAWHUB_PLUGIN}"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(identyclaw_plugin_installed_version "$config_dir" "$container")"

  if [[ "$force" != "1" && -n "$desired_ver" && "$installed_ver" == "$desired_ver" ]] \
    && identyclaw_tools_ext_ready "$config_dir" "$container"; then
    return 0
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
      podman exec "$container" rm -rf \
        "$(agent_identyclaw_tools_ext_dir_container)" \
        /home/node/.openclaw/.identyclaw-plugin-build 2>/dev/null || true
    else
      rm -rf "$ext_dir" "$config_dir/.identyclaw-plugin-build" 2>/dev/null || true
    fi
  fi

  echo "    (installing IdentyClaw plugin from ${plugin_spec}…)" >&2
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=()
  if [[ "$force" == "1" || ( -n "$desired_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    install_args+=(--force)
  fi
  if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
    return 1
  fi
  identyclaw_tools_ext_ready "$config_dir" "$container" || {
    echo "    (identyclaw-tools: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && podman ps --format '{{.Names}}' | grep -qx "$container"; then
    link_identyclaw_plugin_deps_in_container "$container"
  fi
}

link_identyclaw_webhooks_plugin_deps() {
  local target="$1"
  mkdir -p "${target}/node_modules"
  rm -rf "${target}/node_modules/openclaw" "${target}/node_modules/@rodit"
  ln -sf /app "${target}/node_modules/openclaw"
  if [[ -d "$(dirname "$target")/identyclaw-a2a/node_modules/@rodit" ]]; then
    ln -sf "../../identyclaw-a2a/node_modules/@rodit" "${target}/node_modules/@rodit"
  fi
}

link_identyclaw_webhooks_plugin_deps_in_container() {
  local container="$1"
  podman exec "$container" bash -c '
    set -euo pipefail
    ext=/home/node/.openclaw/extensions/identyclaw-webhooks
    mkdir -p "$ext/node_modules"
    rm -rf "$ext/node_modules/openclaw" "$ext/node_modules/@rodit"
    ln -sf /app "$ext/node_modules/openclaw"
    ln -sf ../../identyclaw-a2a/node_modules/@rodit "$ext/node_modules/@rodit"
  '
}

install_plugin_tree_in_container() {
  local container="$1"
  local ext_name="$2"
  local build_dir="$3"
  shift 3
  local item items=() ext_dir="/home/node/.openclaw/extensions/${ext_name}"
  local stage_dir="/tmp/.plugin-build-${ext_name}"
  local copy_items=""

  for item in "$@"; do
    items+=("$item")
    copy_items+=" $(printf '%q' "$item")"
  done

  podman exec "$container" rm -rf "$ext_dir" "$stage_dir" 2>/dev/null || true
  podman cp "$build_dir" "$container:$stage_dir" >/dev/null
  # shellcheck disable=SC2086
  podman exec "$container" bash -c "
    set -euo pipefail
    ext_dir=$(printf '%q' "$ext_dir")
    build_dir=$(printf '%q' "$stage_dir")
    mkdir -p \"\$ext_dir\"
    for item in${copy_items}; do
      cp -a \"\$build_dir/\$item\" \"\$ext_dir/\"
    done
    mkdir -p \"\$ext_dir/node_modules\"
    rm -rf \"\$ext_dir/node_modules/openclaw\"
    ln -sf /app \"\$ext_dir/node_modules/openclaw\"
    rm -rf \"\$build_dir\"
  "
}

upgrade_agent_skill() {
  local id="$1"
  local config_dir container skill_spec skill_ver
  local -a install_args
  load_env
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  skill_spec="${IDENTYCLAW_CLAWHUB_SKILL:-identyclaw}"
  skill_ver="${IDENTYCLAW_CLAWHUB_SKILL_VERSION:-}"

  echo "    (IdentyClaw skill: ${skill_spec}${skill_ver:+ @}${skill_ver})"
  install_args=(--force)
  [[ -n "$skill_ver" ]] && install_args+=(--version "$skill_ver")
  openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" "$skill_spec" >&2 \
    || openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" identyclaw >&2 \
    || echo "    (${id}: ClawHub skill install failed)" >&2
}

upgrade_agent_plugins() {
  local id="$1"
  local container config_dir
  load_env
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"

  rm -rf "${config_dir}/extensions/rodit-webhooks" 2>/dev/null || true

  echo "==> Upgrading plugins for ${id}"
  echo "    (A2A: ${IDENTYCLAW_CLAWHUB_A2A_PLUGIN})"
  install_a2a_plugin "$config_dir" 1 "$id" || {
    echo "A2A plugin install failed for ${id}" >&2
    return 1
  }

  echo "    (IdentyClaw: ${IDENTYCLAW_CLAWHUB_PLUGIN})"
  install_identyclaw_plugin "$config_dir" 1 "$id" || {
    echo "IdentyClaw plugin install failed for ${id}" >&2
    return 1
  }

  sync_agent_plugin_configs "$id" "$config_dir" || {
    echo "    (${id}: openclaw.json plugin config sync failed)" >&2
    return 1
  }

  echo "    (IdentyClaw webhooks: ${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN})"
  strip_a2a_dynamic_peers_config_for_install "$config_dir" "$container"
  install_identyclaw_webhooks_plugin "$config_dir" 1 "$id" || {
    echo "IdentyClaw webhooks plugin install failed for ${id}" >&2
    return 1
  }
  ensure_webhooks_plugin_config "$config_dir" "$container" || return 1

  upgrade_agent_skill "$id"

  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    link_identyclaw_plugin_deps_in_container "$container"
    ensure_openclaw_cli_link "$container"
    podman exec "$container" node /app/openclaw.mjs plugins registry --refresh >&2 || true
  fi
}

ensure_a2a_packages() {
  local id="$1"
  local container config_dir rw_build
  load_env
  container="$(agent_container "$id")"
  config_dir="$(agent_home "$id")"
  agent_has_near_credentials "$config_dir" || return 0
  if ! install_a2a_plugin "$config_dir" 0 "$id"; then
    return 0
  fi
  install_identyclaw_webhooks_plugin "$config_dir" 0 "$id" || true
  ensure_webhooks_plugin_config "$config_dir" "$container" || true
  ensure_a2a_config "$id" "$config_dir" "$container" || true
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  ensure_openclaw_cli_link "$container"
  podman exec "$container" node /app/openclaw.mjs plugins registry --refresh >&2 || true
}

write_instagram_secrets() {
  local config_dir="$1"
  local username="$2"
  local password="$3"
  [[ -n "$username" && -n "$password" ]] || { echo "empty Instagram credentials" >&2; return 1; }
  mkdir -p "$config_dir/secrets"
  printf '%s' "$username" >"$config_dir/secrets/instagram.username"
  printf '%s' "$password" >"$config_dir/secrets/instagram.password"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/instagram.username" "$config_dir/secrets/instagram.password"
  sync_instagram_env "$config_dir"
  write_agent_instagram_doc "$config_dir" "$username"
}

sync_instagram_env() {
  local config_dir="$1"
  local user_file="$config_dir/secrets/instagram.username"
  local pass_file="$config_dir/secrets/instagram.password"
  local env_file="$config_dir/.env"
  [[ -f "$user_file" && -f "$pass_file" ]] || return 0
  local username password
  username="$(<"$user_file")"
  password="$(<"$pass_file")"
  [[ -n "$username" && -n "$password" ]] || return 0
  python3 - "$env_file" "$username" "$password" <<'PY'
import os, sys
path, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("INSTAGRAM_USERNAME=", "INSTAGRAM_PASSWORD="))
        ]
lines.append(f"INSTAGRAM_USERNAME={username}\n")
lines.append(f"INSTAGRAM_PASSWORD={password}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}

write_agent_instagram_doc() {
  local config_dir="$1"
  local username="$2"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/INSTAGRAM.md" <<EOF
# Instagram (Mundo En Blanco)

**Credentials are configured.** Do not ask for manual login handoff or user-browser attach until you have tried browser login below and hit captcha / 2FA / suspicious-login.

- **Profile:** https://www.instagram.com/${username}/
- **Username:** \`${username}\` (\`INSTAGRAM_USERNAME\` in env)
- **Password:** \`INSTAGRAM_PASSWORD\` in env (also \`secrets/instagram.*\`)

## First step on any Instagram task

1. Read this file.
2. Log in via the managed \`browser\` tool (browser-automation skill) using env credentials.
3. Open the profile and snapshot posts before suggesting alternatives.

Save learned caption/reel style to \`workspace/instagram/STYLE.md\`.

## Browser login

1. \`action="open"\` → \`https://www.instagram.com/accounts/login/\` with \`label="instagram"\`
2. \`action="snapshot"\` on \`targetId="instagram"\`
3. Fill username/password from env, submit, snapshot again
4. Reuse the \`instagram\` tab for posting, drafts, and reels

Automated container login often hits reCAPTCHA — stop and point Mariia to \`workspace/instagram/Mariia-SETUP.md\` (user Chrome \`profile="user"\` or cookie import).

## Session persistence

Cookies live under \`browser/openclaw/user-data/\`. After a successful login, keep using the same browser profile; do not clear user data unless asked.
EOF
  chmod 644 "$config_dir/workspace/INSTAGRAM.md"
}

agent_twitter_username() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_USERNAME ""
}

agent_twitter_bird_auth_token() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_AUTH_TOKEN ""
}

agent_twitter_bird_ct0() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_CT0 ""
}

twitter_clawhub_skill_slug() {
  load_env
  local spec="${IDENTYCLAW_CLAWHUB_TWITTER_SKILL:-bird-twitter}"
  spec="${spec#clawhub:}"
  spec="${spec##*/}"
  spec="${spec%%@*}"
  echo "$spec"
}

twitter_bird_bin() {
  echo "/home/node/.openclaw/workspace/node_modules/.bin/bird"
}

twitter_clawhub_skill_installed_in_container() {
  local container="$1"
  local slug
  slug="$(twitter_clawhub_skill_slug)"
  podman exec "$container" sh -c "test -f /home/node/.openclaw/workspace/skills/${slug}/SKILL.md" 2>/dev/null
}

sync_twitter_bird_env() {
  local id="$1"
  local config_dir="$2"
  local env_file="$config_dir/.env"
  local auth_token ct0
  auth_token="$(agent_twitter_bird_auth_token "$id")"
  ct0="$(agent_twitter_bird_ct0 "$id")"
  [[ -f "$config_dir/secrets/twitter.auth_token" ]] && [[ -z "$auth_token" ]] && auth_token="$(<"$config_dir/secrets/twitter.auth_token")"
  [[ -f "$config_dir/secrets/twitter.ct0" ]] && [[ -z "$ct0" ]] && ct0="$(<"$config_dir/secrets/twitter.ct0")"
  [[ -n "$auth_token" && -n "$ct0" ]] || return 0
  python3 - "$env_file" "$auth_token" "$ct0" <<'PY'
import os, sys
path, auth_token, ct0 = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("AUTH_TOKEN=", "CT0=", "AISA_API_KEY="))
        ]
lines.append(f"AUTH_TOKEN={auth_token}\n")
lines.append(f"CT0={ct0}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}

write_twitter_bird_cookies() {
  local id="$1"
  local config_dir="$2"
  local auth_token="$3"
  local ct0="$4"
  [[ -n "$auth_token" && -n "$ct0" ]] || { echo "empty Twitter session cookies" >&2; return 1; }
  if ! mkdir -p "$config_dir/secrets" 2>/dev/null; then
    _write_twitter_bird_cookies_in_container "$id" "$auth_token" "$ct0"
    return $?
  fi
  printf '%s' "$auth_token" >"$config_dir/secrets/twitter.auth_token"
  printf '%s' "$ct0" >"$config_dir/secrets/twitter.ct0"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/twitter.auth_token" "$config_dir/secrets/twitter.ct0"
  sync_twitter_bird_env "$id" "$config_dir"
}

_write_twitter_bird_cookies_in_container() {
  local id="$1"
  local auth_token="$2"
  local ct0="$3"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot write Twitter cookies: ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$auth_token" "$ct0" <<'PY'
import os, sys
auth_token, ct0 = sys.argv[1], sys.argv[2]
root = "/home/node/.openclaw"
secrets = os.path.join(root, "secrets")
os.makedirs(secrets, mode=0o700, exist_ok=True)
for name, value in (("twitter.auth_token", auth_token), ("twitter.ct0", ct0)):
    path = os.path.join(secrets, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)
    os.chmod(path, 0o600)
env_file = os.path.join(root, ".env")
lines = []
if os.path.isfile(env_file):
    with open(env_file, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("AUTH_TOKEN=", "CT0=", "AISA_API_KEY="))
        ]
lines.append(f"AUTH_TOKEN={auth_token}\n")
lines.append(f"CT0={ct0}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}

_ensure_twitter_clawhub_skill_openclaw_json() {
  local config_dir="$1"
  local slug old_slug
  slug="$(twitter_clawhub_skill_slug)"
  old_slug="openclaw-aisa-twitter-search"
  python3 - "$config_dir/openclaw.json" "$slug" "$old_slug" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, old_slug = sys.argv[2], sys.argv[3]
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
changed = False
skills = data.setdefault("skills", {}).setdefault("entries", {})
if old_slug in skills:
    del skills[old_slug]
    changed = True
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True
if changed:
    data["skills"]["entries"] = skills
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

_ensure_twitter_clawhub_skill_openclaw_json_in_container() {
  local container="$1"
  local slug old_slug
  slug="$(twitter_clawhub_skill_slug)"
  old_slug="openclaw-aisa-twitter-search"
  podman exec -i "$container" python3 - "$slug" "$old_slug" <<'PY'
import json, sys
from pathlib import Path

slug, old_slug = sys.argv[1], sys.argv[2]
path = Path("/home/node/.openclaw/openclaw.json")
data = json.loads(path.read_text(encoding="utf-8"))
changed = False
skills = data.setdefault("skills", {}).setdefault("entries", {})
if old_slug in skills:
    del skills[old_slug]
    changed = True
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True
if changed:
    data["skills"]["entries"] = skills
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

ensure_bird_cli_in_container() {
  local container="$1"
  podman exec "$container" sh -c 'test -x /home/node/.openclaw/workspace/node_modules/.bin/bird' 2>/dev/null && return 0
  echo "    (installing bird CLI in workspace…)" >&2
  podman exec "$container" sh -c 'cd /home/node/.openclaw/workspace && npm install --no-save @steipete/bird@0.8.0' >&2 || true
}

ensure_twitter_bird_cookies_from_env() {
  local id="$1"
  local config_dir="$2"
  local auth_token ct0
  auth_token="$(agent_twitter_bird_auth_token "$id")"
  ct0="$(agent_twitter_bird_ct0 "$id")"
  if [[ -n "$auth_token" && -n "$ct0" ]] && [[ ! -f "$config_dir/secrets/twitter.auth_token" ]]; then
    write_twitter_bird_cookies "$id" "$config_dir" "$auth_token" "$ct0"
    echo "    (${id}: Twitter session cookies loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/twitter.auth_token" ]]; then
    sync_twitter_bird_env "$id" "$config_dir"
  fi
}

ensure_twitter_clawhub_skill() {
  local id="$1"
  local config_dir="$2"
  local container skill_spec slug
  load_env
  skill_spec="${IDENTYCLAW_CLAWHUB_TWITTER_SKILL:-bird-twitter}"
  slug="$(twitter_clawhub_skill_slug)"
  container="$(agent_container "$id")"
  ensure_twitter_bird_cookies_from_env "$id" "$config_dir"
  if [[ -f "$config_dir/openclaw.json" ]]; then
    _ensure_twitter_clawhub_skill_openclaw_json "$config_dir"
  fi
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  ensure_openclaw_cli_link "$container"
  podman exec "$container" rm -rf \
    "/home/node/.openclaw/workspace/skills/openclaw-aisa-twitter-search" \
    "/home/node/.openclaw/workspace/skills/twitter-post" 2>/dev/null || true
  if ! twitter_clawhub_skill_installed_in_container "$container"; then
    echo "    (${id}: installing ClawHub Twitter skill ${skill_spec}…)" >&2
    podman exec "$container" node /app/openclaw.mjs skills install "$skill_spec" >&2 \
      || podman exec "$container" node /app/openclaw.mjs skills install "$slug" >&2 || true
  fi
  ensure_bird_cli_in_container "$container"
  _ensure_twitter_clawhub_skill_openclaw_json_in_container "$container"
  sync_twitter_bird_env "$id" "$config_dir"
  if [[ -f "$config_dir/secrets/twitter.auth_token" && -f "$config_dir/secrets/twitter.ct0" ]]; then
    _write_twitter_bird_cookies_in_container "$id" \
      "$(<"$config_dir/secrets/twitter.auth_token")" \
      "$(<"$config_dir/secrets/twitter.ct0")" 2>/dev/null || true
  fi
  local username
  username="$(agent_twitter_username "$id")"
  if [[ -z "$username" ]]; then
    username="$(podman exec "$container" sh -c 'cat /home/node/.openclaw/secrets/twitter.username 2>/dev/null' || true)"
  fi
  if [[ -n "$username" ]]; then
    _write_agent_twitter_doc_in_container "$container" "$username"
    _write_twitter_workspace_guidance_in_container "$container"
    _write_twitter_heartbeat_doc_in_container "$container"
    _ensure_twitter_heartbeat_config_in_container "$container"
  fi
}

linkedin_skill_slug() {
  load_env
  local spec="${IDENTYCLAW_CLAWHUB_LINKEDIN_SKILL:-linkedin-social}"
  spec="${spec#clawhub:}"
  spec="${spec##*/}"
  spec="${spec%%@*}"
  echo "$spec"
}

clawlink_plugin_id() {
  echo "clawlink-plugin"
}

clawlink_tool_names() {
  cat <<'EOF'
clawlink_begin_pairing
clawlink_get_pairing_status
clawlink_start_connection
clawlink_get_connection_status
clawlink_list_integrations
clawlink_list_tools
clawlink_search_tools
clawlink_describe_tool
clawlink_preview_tool
clawlink_call_tool
EOF
}

linkedin_skill_installed_in_container() {
  local container="$1"
  local slug
  slug="$(linkedin_skill_slug)"
  podman exec "$container" sh -c "test -f /home/node/.openclaw/workspace/skills/${slug}/SKILL.md" 2>/dev/null
}

clawlink_plugin_installed_in_container() {
  local container="$1"
  podman exec "$container" sh -c "test -f /home/node/.openclaw/extensions/clawlink-plugin/openclaw.plugin.json" 2>/dev/null
}

_patch_linkedin_openclaw_json() {
  local config_path="$1"
  local slug plugin_id
  slug="$(linkedin_skill_slug)"
  plugin_id="$(clawlink_plugin_id)"
  python3 - "$config_path" "$slug" "$plugin_id" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, plugin_id = sys.argv[2], sys.argv[3]
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
if plugins.get(plugin_id, {}).get("enabled") is not True:
    plugins[plugin_id] = {"enabled": True}
    changed = True

skills = data.setdefault("skills", {}).setdefault("entries", {})
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True

tools = data.setdefault("tools", {})
allow = tools.setdefault("allow", [])
clawlink_tools = [
    "clawlink_begin_pairing",
    "clawlink_get_pairing_status",
    "clawlink_start_connection",
    "clawlink_get_connection_status",
    "clawlink_list_integrations",
    "clawlink_list_tools",
    "clawlink_search_tools",
    "clawlink_describe_tool",
    "clawlink_preview_tool",
    "clawlink_call_tool",
]
for name in clawlink_tools:
    if name not in allow:
        allow.append(name)
        changed = True
tools["allow"] = allow
if "alsoAllow" in tools:
    del tools["alsoAllow"]
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

_patch_linkedin_openclaw_json_in_container() {
  local container="$1"
  local slug plugin_id
  slug="$(linkedin_skill_slug)"
  plugin_id="$(clawlink_plugin_id)"
  podman exec -i "$container" python3 - "$slug" "$plugin_id" <<'PY'
import json, sys
from pathlib import Path

slug, plugin_id = sys.argv[1], sys.argv[2]
path = Path("/home/node/.openclaw/openclaw.json")
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
if plugins.get(plugin_id, {}).get("enabled") is not True:
    plugins[plugin_id] = {"enabled": True}
    changed = True

skills = data.setdefault("skills", {}).setdefault("entries", {})
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True

tools = data.setdefault("tools", {})
allow = tools.setdefault("allow", [])
for name in (
    "clawlink_begin_pairing",
    "clawlink_get_pairing_status",
    "clawlink_start_connection",
    "clawlink_get_connection_status",
    "clawlink_list_integrations",
    "clawlink_list_tools",
    "clawlink_search_tools",
    "clawlink_describe_tool",
    "clawlink_preview_tool",
    "clawlink_call_tool",
):
    if name not in allow:
        allow.append(name)
        changed = True
tools["allow"] = allow
if "alsoAllow" in tools:
    del tools["alsoAllow"]
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

write_agent_linkedin_doc() {
  local config_dir="$1"
  local slug plugin_id
  slug="$(linkedin_skill_slug)"
  plugin_id="$(clawlink_plugin_id)"
  mkdir -p "$config_dir/workspace/linkedin"
  cat >"$config_dir/workspace/LINKEDIN.md" <<EOF
# LinkedIn (ClawLink)

Post and manage LinkedIn via the **\`${slug}\`** ClawHub skill + **ClawLink** OAuth — no LinkedIn API keys in chat.

- **Skill:** [linkedin-social](https://clawhub.ai/hith3sh/linkedin-social)
- **Plugin:** \`${plugin_id}\` (ClawLink) — [claw-link.dev](https://claw-link.dev)
- **Full guide:** \`workspace/skills/${slug}/SKILL.md\`

## First step on any LinkedIn task

1. Read this file and \`workspace/skills/${slug}/SKILL.md\`.
2. Use ClawLink tools (not \`message\`, not browser password login).
3. Confirm writes with the user before posting.

## Setup (one-time)

1. \`clawlink_list_integrations\` — check LinkedIn is connected
2. If not paired: \`clawlink_begin_pairing\` → follow pairing flow
3. Connect LinkedIn: send operator to [claw-link.dev/dashboard?add=linkedin](https://claw-link.dev/dashboard?add=linkedin)
4. Verify: \`clawlink_list_tools --integration linkedin\`

## Post to LinkedIn

\`\`\`bash
clawlink_call_tool --tool "linkedin_create_linked_in_post" --params '{"text": "Your post text"}'
\`\`\`

For unfamiliar tools: \`clawlink_describe_tool\` → \`clawlink_preview_tool\` (writes) → \`clawlink_call_tool\`.

## Read profile

\`\`\`bash
clawlink_call_tool --tool "linkedin_get_my_info" --params '{}'
\`\`\`

Track published posts in \`workspace/linkedin/posts/\`.
EOF
  chmod 644 "$config_dir/workspace/LINKEDIN.md"
  write_linkedin_workspace_guidance "$config_dir"
}

write_linkedin_workspace_guidance() {
  local config_dir="$1"
  local slug
  slug="$(linkedin_skill_slug)"
  local tools="$config_dir/workspace/TOOLS.md"
  local agents="$config_dir/workspace/AGENTS.md"
  [[ -f "$tools" ]] || return 0
  python3 - "$tools" "$slug" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug = sys.argv[2]
block = f"""
## LinkedIn (agent-b)

- **Post on LinkedIn:** `{slug}` + ClawLink (`clawlink-plugin`) — read **`LINKEDIN.md`**
- **Connect:** https://claw-link.dev/dashboard?add=linkedin (OAuth, no API keys in chat)
- **Post:** `clawlink_call_tool --tool "linkedin_create_linked_in_post" --params '{{"text": "…"}}'`
- Confirm with user before writes (see skill guardrails).
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## LinkedIn[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
  [[ -f "$agents" ]] || return 0
  python3 - "$agents" "$slug" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug = sys.argv[2]
block = f"""
## LinkedIn

- You **can** post on LinkedIn via **`{slug}`** + ClawLink tools — read **`LINKEDIN.md`** first.
- Use \`clawlink_list_integrations\`, \`clawlink_call_tool\`, etc. — not browser login.
- If LinkedIn is not connected, send the operator to https://claw-link.dev/dashboard?add=linkedin
- Confirm before write actions (posts, comments, deletes).
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## LinkedIn[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
}

_write_agent_linkedin_doc_in_container() {
  local container="$1"
  local slug plugin_id
  slug="$(linkedin_skill_slug)"
  plugin_id="$(clawlink_plugin_id)"
  podman exec -i "$container" python3 - "$slug" "$plugin_id" <<'PY'
import os, sys
slug, plugin_id = sys.argv[1], sys.argv[2]
workspace = "/home/node/.openclaw/workspace"
os.makedirs(os.path.join(workspace, "linkedin"), exist_ok=True)
content = f"""# LinkedIn (ClawLink)

Post and manage LinkedIn via the **`{slug}`** ClawHub skill + **ClawLink** OAuth — no LinkedIn API keys in chat.

- **Skill:** [linkedin-social](https://clawhub.ai/hith3sh/linkedin-social)
- **Plugin:** `{plugin_id}` (ClawLink) — [claw-link.dev](https://claw-link.dev)
- **Full guide:** `workspace/skills/{slug}/SKILL.md`

## First step on any LinkedIn task

1. Read this file and `workspace/skills/{slug}/SKILL.md`.
2. Use ClawLink tools (not `message`, not browser password login).
3. Confirm writes with the user before posting.

## Setup (one-time)

1. `clawlink_list_integrations` — check LinkedIn is connected
2. If not paired: `clawlink_begin_pairing` → follow pairing flow
3. Connect LinkedIn: send operator to https://claw-link.dev/dashboard?add=linkedin
4. Verify: `clawlink_list_tools --integration linkedin`

## Post to LinkedIn

```bash
clawlink_call_tool --tool "linkedin_create_linked_in_post" --params '{{"text": "Your post text"}}'
```

For unfamiliar tools: `clawlink_describe_tool` → `clawlink_preview_tool` (writes) → `clawlink_call_tool`.

## Read profile

```bash
clawlink_call_tool --tool "linkedin_get_my_info" --params '{{}}'
```

Track published posts in `workspace/linkedin/posts/`.
"""
path = os.path.join(workspace, "LINKEDIN.md")
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
os.chmod(path, 0o644)
PY
  _write_linkedin_workspace_guidance_in_container "$container"
}

_write_linkedin_workspace_guidance_in_container() {
  local container="$1"
  local slug
  slug="$(linkedin_skill_slug)"
  podman exec -i "$container" python3 - "$slug" <<'PY'
import os, re, sys
slug = sys.argv[1]
workspace = "/home/node/.openclaw/workspace"
tools_path = os.path.join(workspace, "TOOLS.md")
agents_path = os.path.join(workspace, "AGENTS.md")
tools_block = f"""
## LinkedIn (agent-b)

- **Post on LinkedIn:** `{slug}` + ClawLink (`clawlink-plugin`) — read **`LINKEDIN.md`**
- **Connect:** https://claw-link.dev/dashboard?add=linkedin (OAuth, no API keys in chat)
- **Post:** `clawlink_call_tool --tool "linkedin_create_linked_in_post" --params '{{"text": "…"}}'`
- Confirm with user before writes (see skill guardrails).
"""
agents_block = f"""
## LinkedIn

- You **can** post on LinkedIn via **`{slug}`** + ClawLink tools — read **`LINKEDIN.md`** first.
- Use `clawlink_list_integrations`, `clawlink_call_tool`, etc. — not browser login.
- If LinkedIn is not connected, send the operator to https://claw-link.dev/dashboard?add=linkedin
- Confirm before write actions (posts, comments, deletes).
"""
for path, block in ((tools_path, tools_block), (agents_path, agents_block)):
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"\n## LinkedIn[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.rstrip() + block + "\n")
PY
}

ensure_linkedin_clawlink_skill() {
  local id="$1"
  local config_dir="$2"
  local container plugin_spec skill_spec slug
  load_env
  skill_spec="${IDENTYCLAW_CLAWHUB_LINKEDIN_SKILL:-}"
  [[ -n "$skill_spec" ]] || return 0
  slug="$(linkedin_skill_slug)"
  plugin_spec="${IDENTYCLAW_CLAWHUB_CLAWLINK_PLUGIN:-clawhub:clawlink-plugin}"
  container="$(agent_container "$id")"
  if [[ -f "$config_dir/openclaw.json" ]]; then
    _patch_linkedin_openclaw_json "$config_dir/openclaw.json"
    write_agent_linkedin_doc "$config_dir"
  fi
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  ensure_openclaw_cli_link "$container"
  if ! clawlink_plugin_installed_in_container "$container"; then
    echo "    (${id}: installing ClawLink plugin ${plugin_spec}…)" >&2
    podman exec "$container" node /app/openclaw.mjs plugins install "$plugin_spec" >&2 || true
  fi
  if ! linkedin_skill_installed_in_container "$container"; then
    echo "    (${id}: installing ClawHub LinkedIn skill ${skill_spec}…)" >&2
    podman exec "$container" node /app/openclaw.mjs skills install "$skill_spec" >&2 \
      || podman exec "$container" node /app/openclaw.mjs skills install "$slug" >&2 || true
  fi
  _patch_linkedin_openclaw_json_in_container "$container"
  _write_agent_linkedin_doc_in_container "$container"
}

write_twitter_secrets() {
  local id="$1"
  local config_dir="$2"
  local username="$3"
  local password="$4"
  [[ -n "$username" && -n "$password" ]] || { echo "empty Twitter credentials" >&2; return 1; }
  if ! mkdir -p "$config_dir/secrets" 2>/dev/null; then
    _write_twitter_secrets_in_container "$id" "$username" "$password"
    return $?
  fi
  printf '%s' "$username" >"$config_dir/secrets/twitter.username"
  printf '%s' "$password" >"$config_dir/secrets/twitter.password"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/twitter.username" "$config_dir/secrets/twitter.password"
  sync_twitter_env "$config_dir"
  write_agent_twitter_doc "$config_dir" "$username"
  write_twitter_heartbeat_doc "$config_dir"
  ensure_twitter_heartbeat_config "$config_dir"
  ensure_twitter_clawhub_skill "$id" "$config_dir"
}

_write_twitter_secrets_in_container() {
  local id="$1"
  local username="$2"
  local password="$3"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot write Twitter secrets: no access to agent dir and ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$username" "$password" <<'PY'
import os, sys
username, password = sys.argv[1], sys.argv[2]
root = "/home/node/.openclaw"
secrets = os.path.join(root, "secrets")
os.makedirs(secrets, mode=0o700, exist_ok=True)
for name, value in (("twitter.username", username), ("twitter.password", password)):
    path = os.path.join(secrets, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)
    os.chmod(path, 0o600)
PY
  _sync_twitter_env_in_container "$container"
  _write_agent_twitter_doc_in_container "$container" "$username"
  _write_twitter_heartbeat_doc_in_container "$container"
  _ensure_twitter_heartbeat_config_in_container "$container"
  ensure_twitter_clawhub_skill "$id" "$(agent_home "$id")"
}

sync_twitter_env() {
  local config_dir="$1"
  local user_file="$config_dir/secrets/twitter.username"
  local pass_file="$config_dir/secrets/twitter.password"
  local env_file="$config_dir/.env"
  [[ -f "$user_file" && -f "$pass_file" ]] || return 0
  local username password
  username="$(<"$user_file")"
  password="$(<"$pass_file")"
  [[ -n "$username" && -n "$password" ]] || return 0
  python3 - "$env_file" "$username" "$password" <<'PY'
import os, sys
path, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("TWITTER_USERNAME=", "TWITTER_PASSWORD="))
        ]
lines.append(f"TWITTER_USERNAME={username}\n")
lines.append(f"TWITTER_PASSWORD={password}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}

_sync_twitter_env_in_container() {
  local container="$1"
  podman exec -i "$container" python3 <<'PY'
import os
root = "/home/node/.openclaw"
user_file = os.path.join(root, "secrets", "twitter.username")
pass_file = os.path.join(root, "secrets", "twitter.password")
env_file = os.path.join(root, ".env")
if not (os.path.isfile(user_file) and os.path.isfile(pass_file)):
    raise SystemExit(0)
with open(user_file, encoding="utf-8") as f:
    username = f.read()
with open(pass_file, encoding="utf-8") as f:
    password = f.read()
lines = []
if os.path.isfile(env_file):
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(("TWITTER_USERNAME=", "TWITTER_PASSWORD="))]
lines.append(f"TWITTER_USERNAME={username}\n")
lines.append(f"TWITTER_PASSWORD={password}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}

write_agent_twitter_doc() {
  local config_dir="$1"
  local username="$2"
  local slug bird_bin
  slug="$(twitter_clawhub_skill_slug)"
  bird_bin="workspace/node_modules/.bin/bird"
  mkdir -p "$config_dir/workspace/twitter"/{threads,drafts,posts}
  cat >"$config_dir/workspace/TWITTER.md" <<EOF
# X / Twitter (Discernible)

Account: \`${username}\` — post via **bird** CLI + ClawHub skill \`${slug}\` (free — no paid API).

- **Skill:** [bird-twitter](https://clawhub.ai/cyzi/bird-twitter) (\`workspace/skills/${slug}/SKILL.md\`)
- **Session:** \`AUTH_TOKEN\` + \`CT0\` in env (\`secrets/twitter.auth_token\`, \`secrets/twitter.ct0\`)
- **CLI:** \`${bird_bin}\` (installed in workspace via npm)

## Skills and tools (read this first)

- **You CAN post on X** using **\`${slug}\`** + \`exec\` + \`bird\` (not \`message\`).
- \`message\` is Discord/Slack only — never use it for X.
- **Do not** use browser password login to post (breaks in container). Use session cookies instead.
- If cookies missing, ask operator to run \`./identyclaw.sh set-twitter-cookies agent-b\`.

## Get session cookies (one-time, Firefox)

1. Log in to [x.com](https://x.com) as \`${username}\` in **Firefox**
2. Open Developer Tools: **F12** (or **Menu → More tools → Web Developer Tools**)
3. Open the **Storage** tab
4. Left sidebar: **Cookies** → **https://x.com**
5. In the table, copy the **Value** for \`auth_token\` (paste as \`AUTH_TOKEN\`)
6. Copy the **Value** for \`ct0\` (paste as \`CT0\`)
7. Run \`./identyclaw.sh set-twitter-cookies agent-b\` and paste each value when prompted

**Chrome:** DevTools → **Application** → **Cookies** → **https://x.com** — same cookie names.

## Post a tweet

\`\`\`bash
${bird_bin} check
${bird_bin} whoami
${bird_bin} tweet "HOLA MUNDO"
\`\`\`

1. \`${bird_bin} check\` — verify \`AUTH_TOKEN\` and \`CT0\`
2. \`${bird_bin} tweet "…"\` with the user's exact text
3. Do not claim success until \`bird tweet\` exits 0

## Read / mentions / search

\`\`\`bash
${bird_bin} mentions
${bird_bin} home
${bird_bin} search "query"
\`\`\`

Track posts in \`workspace/twitter/posts/\`.
EOF
  chmod 644 "$config_dir/workspace/TWITTER.md"
  write_twitter_workspace_guidance "$config_dir"
}

write_twitter_workspace_guidance() {
  local config_dir="$1"
  local tools="$config_dir/workspace/TOOLS.md"
  local agents="$config_dir/workspace/AGENTS.md"
  local slug bird_bin
  slug="$(twitter_clawhub_skill_slug)"
  bird_bin="workspace/node_modules/.bin/bird"
  [[ -f "$tools" ]] || return 0
  python3 - "$tools" "$slug" "$bird_bin" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, bird_bin = sys.argv[2], sys.argv[3]
block = f"""
## X / Twitter (agent-b)

- **Post on x.com:** `{slug}` + `bird` CLI — read **`TWITTER.md`**
- **Command:** `{bird_bin} tweet "…"`
- **Session:** `AUTH_TOKEN` + `CT0` — `./identyclaw.sh set-twitter-cookies agent-b`
- **Not for X:** `message` tool (Discord only). No paid AIsa API.
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
  [[ -f "$agents" ]] || return 0
  python3 - "$agents" "$slug" "$bird_bin" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, bird_bin = sys.argv[2], sys.argv[3]
block = f"""
## X / Twitter

- You **can** post on x.com via **`{slug}`** + `{bird_bin} tweet "…"` — read **`TWITTER.md`** first.
- Requires `AUTH_TOKEN` and `CT0` session cookies (not password login in browser).
- If cookies missing, tell operator to run `./identyclaw.sh set-twitter-cookies agent-b`.
- **Do not** use `message` for X. Never paste cookies in chat.
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
}

_write_agent_twitter_doc_in_container() {
  local container="$1"
  local username="$2"
  local slug
  slug="$(twitter_clawhub_skill_slug)"
  podman exec -i "$container" python3 - "$username" "$slug" <<'PY'
import os, sys
username, slug = sys.argv[1], sys.argv[2]
workspace = "/home/node/.openclaw/workspace"
bird_bin = "workspace/node_modules/.bin/bird"
for sub in ("twitter/threads", "twitter/drafts", "twitter/posts"):
    os.makedirs(os.path.join(workspace, sub), exist_ok=True)
content = f"""# X / Twitter (Discernible)

Account: `{username}` — post via **bird** CLI + ClawHub skill `{slug}` (free — no paid API).

- **Skill:** [bird-twitter](https://clawhub.ai/cyzi/bird-twitter) (`workspace/skills/{slug}/SKILL.md`)
- **Session:** `AUTH_TOKEN` + `CT0` in env (`secrets/twitter.auth_token`, `secrets/twitter.ct0`)
- **CLI:** `{bird_bin}` (installed in workspace via npm)

## Skills and tools (read this first)

- **You CAN post on X** using **`{slug}`** + `exec` + `bird` (not `message`).
- `message` is Discord/Slack only — never use it for X.
- **Do not** use browser password login to post (breaks in container). Use session cookies instead.
- If cookies missing, ask operator to run `./identyclaw.sh set-twitter-cookies agent-b`.

## Get session cookies (one-time, Firefox)

1. Log in to [x.com](https://x.com) as `{username}` in **Firefox**
2. Open Developer Tools: **F12** (or **Menu → More tools → Web Developer Tools**)
3. Open the **Storage** tab
4. Left sidebar: **Cookies** → **https://x.com**
5. In the table, copy the **Value** for `auth_token` (paste as `AUTH_TOKEN`)
6. Copy the **Value** for `ct0` (paste as `CT0`)
7. Run `./identyclaw.sh set-twitter-cookies agent-b` and paste each value when prompted

**Chrome:** DevTools → **Application** → **Cookies** → **https://x.com** — same cookie names.

## Post a tweet

```bash
{bird_bin} check
{bird_bin} whoami
{bird_bin} tweet "HOLA MUNDO"
```

1. `{bird_bin} check` — verify `AUTH_TOKEN` and `CT0`
2. `{bird_bin} tweet "…"` with the user's exact text
3. Do not claim success until `bird tweet` exits 0

## Read / mentions / search

```bash
{bird_bin} mentions
{bird_bin} home
{bird_bin} search "query"
```

Track posts in `workspace/twitter/posts/`.
"""
path = os.path.join(workspace, "TWITTER.md")
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
os.chmod(path, 0o644)
PY
  _write_twitter_workspace_guidance_in_container "$container"
}

_write_twitter_workspace_guidance_in_container() {
  local container="$1"
  local slug
  slug="$(twitter_clawhub_skill_slug)"
  podman exec -i "$container" python3 - "$slug" <<'PY'
import os, re, sys
slug = sys.argv[1]
workspace = "/home/node/.openclaw/workspace"
bird_bin = "workspace/node_modules/.bin/bird"
tools_path = os.path.join(workspace, "TOOLS.md")
agents_path = os.path.join(workspace, "AGENTS.md")
tools_block = f"""
## X / Twitter (agent-b)

- **Post on x.com:** `{slug}` + `bird` CLI — read **`TWITTER.md`**
- **Command:** `{bird_bin} tweet "…"`
- **Session:** `AUTH_TOKEN` + `CT0` — `./identyclaw.sh set-twitter-cookies agent-b`
- **Not for X:** `message` tool (Discord only). No paid AIsa API.
"""
agents_block = f"""
## X / Twitter

- You **can** post on x.com via **`{slug}`** + `{bird_bin} tweet "…"` — read **`TWITTER.md`** first.
- Requires `AUTH_TOKEN` and `CT0` session cookies (not password login in browser).
- If cookies missing, tell operator to run `./identyclaw.sh set-twitter-cookies agent-b`.
- **Do not** use `message` for X. Never paste cookies in chat.
"""
for path, block in ((tools_path, tools_block), (agents_path, agents_block)):
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.rstrip() + block + "\n")
PY
}

write_twitter_heartbeat_doc() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/HEARTBEAT.md" <<'EOF'
tasks:

- name: twitter-mentions
  interval: 1h
  prompt: "Check X/Twitter mentions and notifications. Read workspace/TWITTER.md, run workspace/node_modules/.bin/bird check then bird mentions. Summarize anything needing a response. Draft replies in workspace/twitter/drafts/ when appropriate."

# X/Twitter monitoring (hourly)

Follow TWITTER.md. If bird check fails (missing/expired cookies), tell the operator to refresh via ./identyclaw.sh set-twitter-cookies agent-b. If nothing needs attention, reply HEARTBEAT_OK.
EOF
  chmod 644 "$config_dir/workspace/HEARTBEAT.md"
}

_write_twitter_heartbeat_doc_in_container() {
  local container="$1"
  podman exec -i "$container" python3 <<'PY'
import os
workspace = "/home/node/.openclaw/workspace"
content = """tasks:

- name: twitter-mentions
  interval: 1h
  prompt: "Check X/Twitter mentions and notifications. Read workspace/TWITTER.md, run workspace/node_modules/.bin/bird check then bird mentions. Summarize anything needing a response. Draft replies in workspace/twitter/drafts/ when appropriate."

# X/Twitter monitoring (hourly)

Follow TWITTER.md. If bird check fails (missing/expired cookies), tell the operator to refresh via ./identyclaw.sh set-twitter-cookies agent-b. If nothing needs attention, reply HEARTBEAT_OK.
"""
path = os.path.join(workspace, "HEARTBEAT.md")
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
os.chmod(path, 0o644)
PY
}

ensure_twitter_heartbeat_config() {
  local config_dir="$1"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
heartbeat = defaults.setdefault("heartbeat", {})
changed = False
for key, value in {
    "every": "1h",
    "target": "none",
    "lightContext": True,
    "isolatedSession": True,
}.items():
    if heartbeat.get(key) != value:
        heartbeat[key] = value
        changed = True
defaults["heartbeat"] = heartbeat
agents["defaults"] = defaults
data["agents"] = agents
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

_ensure_twitter_heartbeat_config_in_container() {
  local container="$1"
  podman exec -i "$container" python3 <<'PY'
import json
from pathlib import Path

path = Path("/home/node/.openclaw/openclaw.json")
data = json.loads(path.read_text(encoding="utf-8"))
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
heartbeat = defaults.setdefault("heartbeat", {})
changed = False
for key, value in {
    "every": "1h",
    "target": "none",
    "lightContext": True,
    "isolatedSession": True,
}.items():
    if heartbeat.get(key) != value:
        heartbeat[key] = value
        changed = True
defaults["heartbeat"] = heartbeat
agents["defaults"] = defaults
data["agents"] = agents
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

ensure_twitter_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local username="" password=""
  load_env
  if is_valid_agent_id "$id"; then
    username="$(agent_env_value "$id" TWITTER_USERNAME "")"
    password="$(agent_env_value "$id" TWITTER_PASSWORD "")"
  fi
  if [[ -n "$username" && -n "$password" ]] && [[ ! -f "$config_dir/secrets/twitter.username" ]]; then
    write_twitter_secrets "$id" "$config_dir" "$username" "$password"
    echo "    (${id}: Twitter credentials loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/twitter.username" ]]; then
    sync_twitter_env "$config_dir"
    write_agent_twitter_doc "$config_dir" "$(<"$config_dir/secrets/twitter.username")"
    write_twitter_workspace_guidance "$config_dir"
    write_twitter_heartbeat_doc "$config_dir"
    ensure_twitter_heartbeat_config "$config_dir"
  fi
  ensure_twitter_bird_cookies_from_env "$id" "$config_dir"
  if [[ -n "$username" || -f "$config_dir/secrets/twitter.username" || -f "$config_dir/secrets/twitter.auth_token" ]]; then
    ensure_twitter_clawhub_skill "$id" "$config_dir"
  fi
  ensure_linkedin_clawlink_skill "$id" "$config_dir"
}

ensure_instagram_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local username="" password=""
  load_env
  if is_valid_agent_id "$id"; then
    username="$(agent_env_value "$id" INSTAGRAM_USERNAME "")"
    password="$(agent_env_value "$id" INSTAGRAM_PASSWORD "")"
  fi
  if [[ -n "$username" && -n "$password" ]] && [[ ! -f "$config_dir/secrets/instagram.username" ]]; then
    write_instagram_secrets "$config_dir" "$username" "$password"
    echo "    (${id}: Instagram credentials loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/instagram.username" ]]; then
    sync_instagram_env "$config_dir"
    write_agent_instagram_doc "$config_dir" "$(<"$config_dir/secrets/instagram.username")"
  fi
}

write_agent_browser_doc() {
  local config_dir="$1"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/BROWSER.md" <<'EOF'
# Browser tool (pod / container deploy)

This gateway runs Chromium **inside the agent container** (host browser). The isolated **sandbox browser** sidecar is **not** enabled here — do not use `target="sandbox"` or `targetId="sandbox"`.

## Correct usage

1. Omit `target` (defaults to host) or set `target="host"`.
2. Open: `action="open"`, `url="https://…"`, optional `label="my-tab"`.
3. Snapshot: use `action="tabs"` first, then `action="snapshot"` with `targetId` from the tab list (e.g. `t1`) or the same `label`.
4. Profile: default managed profile is `openclaw` (cookies under `browser/openclaw/user-data/`).

## If browser times out on first use

Chromium cold-start can take ~30s. Retry `open`, or run inside the container:

`node /app/openclaw.mjs browser doctor`

EOF
  chmod 644 "$config_dir/workspace/BROWSER.md"
}

ensure_agent_bootstrap() {
  local id="$1"
  local config_dir="$2"
  local container
  container="$(agent_container "$id")"
  ensure_mail_secrets_from_env "$id" "$config_dir"
  ensure_agent_email_tooling "$id" "$config_dir"
  ensure_instagram_secrets_from_env "$id" "$config_dir"
  ensure_twitter_secrets_from_env "$id" "$config_dir"
  ensure_linkedin_clawlink_skill "$id" "$config_dir"
  ensure_near_credentials_layout "$config_dir"
  ensure_discord_guild_channels "$config_dir" "$container"
  ensure_discord_ready "$id" "$config_dir"
  ensure_identyclaw_config "$config_dir" "$container"
  ensure_openclaw_model_defaults "$config_dir" "$container"
  ensure_session_memory_hook "$config_dir" "$container"
  if agent_has_near_credentials "$config_dir"; then
    ensure_a2a_plugin_build "$id"
  fi
  ensure_a2a_config "$id" "$config_dir" "$container"
  ensure_agent_identyclaw_tooling "$id" "$config_dir"
  write_agent_browser_doc "$config_dir"
  sync_quiet_plugin_env "$config_dir"
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

# Let peer agents reach the other gateway when a bot message @mentions them.
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
  local internal_port="${3:-}"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  load_env
  [[ -n "$internal_port" ]] || internal_port="$(agent_internal_gateway_port "$(agent_id_from_dir "$config_dir")")"
  python3 - "$config" "$host_gateway_port" "$internal_port" <<'PY'
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

ensure_production_ingress_config() {
  local id="$1"
  local config_dir="$2"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  load_env
  local public_url internal_port
  public_url="$(agent_public_base_url "$id")"
  internal_port="$(agent_internal_gateway_port "$id")"
  python3 - "$config" "$public_url" "$internal_port" "$(agent_ingress_port "$id")" <<'PY'
import json, sys
from pathlib import Path

path, public_url, internal_port, ingress_port = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = json.loads(Path(path).read_text(encoding="utf-8"))
gateway = data.setdefault("gateway", {})
changed = False
if gateway.get("bind") != "lan":
    gateway["bind"] = "lan"
    changed = True
if gateway.get("port") != internal_port:
    gateway["port"] = internal_port
    changed = True
origins = gateway.setdefault("controlUi", {}).setdefault("allowedOrigins", [])
candidates = [
    f"http://127.0.0.1:{internal_port}",
    f"http://localhost:{internal_port}",
]
if public_url:
    candidates.append(public_url)
    candidates.append(public_url.replace(f":{ingress_port}", "", 1))
for origin in candidates:
    if origin and origin not in origins:
        origins.append(origin)
        changed = True
if changed:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    Path(path).chmod(0o600)
PY
}

ensure_openclaw_model_defaults() {
  local config_dir="$1"
  local container="${2:-}"
  load_env
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" \
    "$OPENCLAW_MODEL_PRIMARY" "$OPENCLAW_MODEL_FALLBACK_1" "$OPENCLAW_MODEL_FALLBACK_2" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
primary, fb1, fb2 = sys.argv[2:5]
fallbacks = [fb1, fb2]
allowlist = {primary: {}, fb1: {}, fb2: {}}

def model_tail(model_id: str) -> str:
    return model_id.split("/", 1)[1] if "/" in model_id else model_id

paid_fallback = model_tail(fb2)

data = json.loads(path.read_text(encoding="utf-8"))
defaults = data.setdefault("agents", {}).setdefault("defaults", {})
defaults.setdefault("workspace", "/home/node/.openclaw/workspace")
defaults["models"] = allowlist
defaults["model"] = {"primary": primary, "fallbacks": fallbacks}

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
openrouter = plugins.setdefault("openrouter", {})
openrouter["enabled"] = True

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)

sessions_path = path.parent / "agents/main/sessions/sessions.json"
if not sessions_path.is_file():
    raise SystemExit(0)

sessions = json.loads(sessions_path.read_text(encoding="utf-8"))
changed = False
for entry in sessions.values():
    if not isinstance(entry, dict):
        continue
    model = entry.get("model")
    if not model:
        continue
    if (
        model == paid_fallback
        or model == fb2
        or model_tail(str(model)) == paid_fallback
        or str(model).endswith("grok-4.3")
    ):
        entry.pop("model", None)
        entry.pop("modelProvider", None)
        entry.pop("modelOverrideSource", None)
        changed = True

if changed:
    sessions_path.write_text(json.dumps(sessions, indent=2) + "\n", encoding="utf-8")
    sessions_path.chmod(0o600)
PY
}

ensure_session_memory_hook() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {}).setdefault("internal", {})
entries = hooks.setdefault("entries", {})
entry = entries.setdefault("session-memory", {})
changed = False
if hooks.get("enabled") is not True:
    hooks["enabled"] = True
    changed = True
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
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
      "himalaya": { "enabled": true },
      "identyclaw": { "enabled": true }
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
      },
      "openrouter": {
        "enabled": true
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "models": {
        "${OPENCLAW_MODEL_PRIMARY}": {},
        "${OPENCLAW_MODEL_FALLBACK_1}": {},
        "${OPENCLAW_MODEL_FALLBACK_2}": {}
      },
      "model": {
        "primary": "${OPENCLAW_MODEL_PRIMARY}",
        "fallbacks": [
          "${OPENCLAW_MODEL_FALLBACK_1}",
          "${OPENCLAW_MODEL_FALLBACK_2}"
        ]
      }
    }
  },
  "memory": {
    "backend": "qmd"
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "session-memory": { "enabled": true }
      }
    }
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

# Paths bundled for migration (secrets + durable config). Ephemeral/runtime dirs excluded.
agent_export_paths() {
  cat <<'EOF'
openclaw.json
.env
.config
secrets
agents
workspace
identity
extensions
cron
canvas
devices
credentials
exec-approvals.json
plugin-skills
flows
memory
media
discord
EOF
}

agent_export_excludes() {
  cat <<'EOF'
openclaw.json.bak
openclaw.json.bak.*
openclaw.json.last-good
.reset-backup
.a2a-plugin-build
cache
logs
npm
delivery-queue
tasks
tui
plugins
update-check.json
workspace/node_modules
workspace/.git
EOF
}

sync_agent_secrets_for_export() {
  local id="$1"
  local config_dir="$2"
  sync_discord_env "$config_dir"
  sync_identyclaw_env "$config_dir"
  sync_instagram_env "$config_dir"
  sync_twitter_env "$config_dir"
  sync_twitter_bird_env "$id" "$config_dir"
  sync_quiet_plugin_env "$config_dir"
}

write_agent_export_manifest() {
  local id="$1"
  local config_dir="$2"
  local manifest_path="$3"
  local with_browser="$4"
  load_env
  local gw br email display_name repo_rev=""
  read -r gw br < <(agent_ports "$id")
  local mailbox
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  if command -v git >/dev/null 2>&1 && [[ -d "$IDENTYCLAW_ROOT/.git" ]]; then
    repo_rev="$(git -C "$IDENTYCLAW_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  fi
  python3 - "$manifest_path" "$id" "$config_dir" "$gw" "$br" "$email" "$display_name" \
    "$with_browser" "$(hostname -f 2>/dev/null || hostname)" "$repo_rev" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

path, agent_id, config_dir, gw, br, email, display_name, with_browser, source_host, repo_rev = sys.argv[1:11]
manifest = {
    "format": "identyclaw-agent-export",
    "version": 1,
    "agentId": agent_id,
    "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sourceHost": source_host,
    "identyclawRepoRev": repo_rev or None,
    "gatewayPort": int(gw),
    "bridgePort": int(br),
    "email": email,
    "displayName": display_name,
    "includesBrowser": with_browser == "1",
    "stateDirBasename": Path(config_dir).name,
    "importSteps": [
        "Copy identyclaw-agents repo to target host",
        "ensure_app_layout && merge env.local.fragment into identyclaw-agents-app/env.local",
        "./identyclaw.sh build-image",
        f"./identyclaw.sh import-agent {agent_id} <this-archive>",
        f"./identyclaw.sh start {agent_id}",
        f"./identyclaw.sh test-mail {agent_id}",
    ],
}
Path(path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
Path(path).chmod(0o600)
PY
}

write_agent_export_env_fragment() {
  local id="$1"
  local fragment_path="$2"
  load_env
  local gw br email display_name password="" prefix a2a_url=""
  read -r gw br < <(agent_ports "$id")
  local mailbox
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  local prefix
  prefix="$(agent_env_prefix "$id")" || { echo "unknown agent: $id" >&2; return 1; }
  password="$(agent_env_value "$id" PASSWORD "")"
  a2a_url="$(agent_env_value "$id" A2A_PUBLIC_BASE_URL "")"
  cat >"$fragment_path" <<EOF
# Merge into $(identyclaw_app_dir)/env.local on the target host (chmod 600).
# Secrets are inside the archive under secrets/ — passwords here are optional duplicates.

${prefix}_EMAIL=${email}
${prefix}_DISPLAY_NAME="${display_name}"
${prefix}_GATEWAY_PORT=${gw}
${prefix}_BRIDGE_PORT=${br}
EOF
  if [[ -n "$password" ]]; then
    printf '%s_PASSWORD=%s\n' "$prefix" "$password" >>"$fragment_path"
  fi
  if [[ -n "$a2a_url" ]]; then
    printf '%s_A2A_PUBLIC_BASE_URL=%s\n' "$prefix" "$a2a_url" >>"$fragment_path"
  fi
  chmod 600 "$fragment_path"
}

fix_agent_export_permissions() {
  local config_dir="$1"
  chmod 700 "$config_dir" "$config_dir/secrets" 2>/dev/null || true
  find "$config_dir/secrets" -type f -exec chmod 600 {} + 2>/dev/null || true
  find "$config_dir/secrets" -type f -name '*.sh' -exec chmod 700 {} + 2>/dev/null || true
  chmod 600 "$config_dir/.env" "$config_dir/openclaw.json" 2>/dev/null || true
  find "$config_dir/agents" -type f -exec chmod 600 {} + 2>/dev/null || true
  find "$config_dir/identity" -type f -exec chmod 600 {} + 2>/dev/null || true
}

export_agent_bundle() {
  local id="$1"
  local output="${2:-}"
  local with_browser="${3:-0}"
  local stop_first="${4:-1}"
  local config_dir staging manifest fragment
  config_dir="$(agent_home "$id")"
  [[ -d "$config_dir" ]] || { echo "Missing agent dir: $config_dir (run init first)" >&2; exit 1; }
  [[ -f "$config_dir/openclaw.json" ]] || { echo "Missing openclaw.json in $config_dir" >&2; exit 1; }

  if [[ "$stop_first" == "1" ]] && command -v podman >/dev/null 2>&1; then
    local container
    container="$(agent_container "$id")"
    if podman ps --format '{{.Names}}' | grep -qx "$container"; then
      echo "==> Stopping ${container} for consistent export"
      podman stop "$container" >/dev/null
    fi
  fi

  echo "==> Syncing secrets into .env before export"
  sync_agent_secrets_for_export "$id" "$config_dir"

  if [[ -z "$output" ]]; then
    load_env
    mkdir -p "${IDENTYCLAW_APP_DIR}/exports"
    output="${IDENTYCLAW_APP_DIR}/exports/identyclaw-migrate-${id}-$(date +%Y%m%d-%H%M%S).tar.gz"
  fi
  output="$(readlink -f "$output")"

  staging="$(mktemp -d)"
  local _export_staging="$staging"
  trap 'rm -rf "${_export_staging:-}"' RETURN

  write_agent_export_manifest "$id" "$config_dir" "$staging/MANIFEST.json" "$with_browser"
  write_agent_export_env_fragment "$id" "$staging/env.local.fragment"

  local path
  while IFS= read -r path; do
    [[ -n "$path" && -e "$config_dir/$path" ]] || continue
    mkdir -p "$staging/$(dirname "$path")"
    cp -a "$config_dir/$path" "$staging/$path"
  done < <(agent_export_paths)
  if [[ "$with_browser" == "1" && -d "$config_dir/browser" ]]; then
    cp -a "$config_dir/browser" "$staging/browser"
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -rf "$staging/$path" 2>/dev/null || true
  done < <(agent_export_excludes)

  echo "==> Packing ${id} → ${output}"
  tar --create --gzip --file "$output" -C "$staging" .

  chmod 600 "$output"
  local size
  size="$(du -h "$output" | awk '{print $1}')"
  echo ""
  echo "Export ready: ${output} (${size})"
  echo "Contains secrets — store encrypted, transfer over a trusted channel, delete when imported."
  echo "On target: ./identyclaw.sh import-agent ${id} ${output}"
}

import_agent_bundle() {
  local id="$1"
  local archive="${2:?archive required}"
  [[ -f "$archive" ]] || { echo "Archive not found: $archive" >&2; exit 1; }

  local extract staging manifest_id
  staging="$(mktemp -d)"
  local _import_staging="$staging"
  trap 'rm -rf "${_import_staging:-}"' RETURN
  tar -xzf "$archive" -C "$staging"

  [[ -f "$staging/MANIFEST.json" ]] || { echo "Invalid archive: missing MANIFEST.json" >&2; exit 1; }
  manifest_id="$(python3 - "$staging/MANIFEST.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("agentId", ""))
PY
)"
  [[ "$manifest_id" == "$id" ]] || {
    echo "Archive is for ${manifest_id:-unknown}, not ${id}" >&2
    exit 1
  }

  if command -v podman >/dev/null 2>&1; then
    local container
    container="$(agent_container "$id")"
    podman stop "$container" 2>/dev/null || true
    podman rm -f "$container" 2>/dev/null || true
  fi

  local config_dir backup
  config_dir="$(agent_home "$id")"
  if [[ -d "$config_dir" ]]; then
    backup="${config_dir}.pre-import-$(date +%Y%m%d-%H%M%S)"
    echo "==> Backing up existing ${config_dir} → ${backup}"
    mv "$config_dir" "$backup"
  fi
  mkdir -p "$config_dir"

  echo "==> Restoring agent state into ${config_dir}"
  shopt -s dotglob
  for item in "$staging"/*; do
    base="$(basename "$item")"
    [[ "$base" == "MANIFEST.json" || "$base" == "env.local.fragment" ]] && continue
    cp -a "$item" "$config_dir/"
  done
  shopt -u dotglob

  fix_agent_export_permissions "$config_dir"
  load_env
  read -r gw _ < <(agent_ports "$id")
  ensure_internal_gateway_port "$config_dir" "$gw"
  ensure_agent_bootstrap "$id" "$config_dir"

  echo ""
  echo "Imported ${id} into ${config_dir}"
  if [[ -f "$staging/env.local.fragment" ]]; then
    local fragment_dest
    fragment_dest="$(identyclaw_app_dir)/env.local.fragment.${id}"
    cp "$staging/env.local.fragment" "$fragment_dest"
    echo "Merge ${fragment_dest} into $(identyclaw_env_file) on this host."
  fi
  echo "Next: ./identyclaw.sh build-image && ./identyclaw.sh start ${id}"
}
