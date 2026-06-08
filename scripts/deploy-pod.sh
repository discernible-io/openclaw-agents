#!/usr/bin/env bash
# Production deploy: Podman pod with nginx TLS sidecar + three OpenClaw agent containers.
# Mirrors .github/workflows/deploy.yml host steps. Run on the deployment host.
#
# Required env:
#   APP_DIR              Host app root (e.g. ~/identyclaw-agents-app)
#   OPENCLAW_IMAGE       Full image ref (ghcr.io/.../openclaw-himalaya:SHA)
#   NGINX_IMAGE          Full image ref (ghcr.io/.../identyclaw-nginx:SHA)
#
# Optional env (defaults match deploy.yml):
#   DEPLOY_TIER / TARGET   main or development (default: image tag, else git branch)
#   APP_PORT=9443 (both tiers for now)
#   POD_NAME=identyclaw-agents-pod
#   NGINX_CONTAINER_NAME=identyclaw-nginx
#   IDENTYCLAW_AGENT_STATE_ROOT  (default: ${APP_DIR}/agents)
#   REPO_ROOT            Git checkout path (for identyclaw.sh init/bootstrap)
#   AGENT_IDS            Space-separated list (default: agent-a agent-b agent-c)

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

APP_DIR="${APP_DIR:?APP_DIR is required}"
APP_DIR="${APP_DIR/#\~/$HOME}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:?OPENCLAW_IMAGE is required}"
NGINX_IMAGE="${NGINX_IMAGE:?NGINX_IMAGE is required}"

POD_NAME="${POD_NAME:-identyclaw-agents-pod}"
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-identyclaw-nginx}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

export IDENTYCLAW_APP_DIR="${IDENTYCLAW_APP_DIR:-$APP_DIR}"
export IDENTYCLAW_AGENT_STATE_ROOT="${IDENTYCLAW_AGENT_STATE_ROOT:-${APP_DIR}/agents}"
export IDENTYCLAW_DEPLOY_MODE=pod

# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

DEPLOY_TIER="$(resolve_deploy_tier "$REPO_ROOT" "$OPENCLAW_IMAGE")"
case "$DEPLOY_TIER" in
  development|main) ;;
  *)
    echo "DEPLOY_TIER must be development or main (got: $DEPLOY_TIER)" >&2
    exit 1
    ;;
esac
APP_PORT="${APP_PORT:-$(deploy_tier_app_port "$DEPLOY_TIER")}"
POD_LISTEN_PORT="${POD_LISTEN_PORT:-$APP_PORT}"
POD_HOST_PORT="${POD_HOST_PORT:-$APP_PORT}"

ensure_app_layout
load_env
AGENT_IDS="${AGENT_IDS:-agent-a agent-b agent-c}"

require_podman() {
  command -v podman >/dev/null 2>&1 || { echo "podman not found" >&2; exit 1; }
}

normalize_tls_certs() {
  local cert_dir="$APP_DIR/certs"
  chmod 711 "$cert_dir" || true
  local f
  for f in privkey.pem tls.key; do
    if [[ -f "$cert_dir/$f" ]]; then
      podman unshare chown 101:101 "$cert_dir/$f" || true
      podman unshare chmod 600 "$cert_dir/$f" || true
    fi
  done
  for f in fullchain.pem chain.pem cert.pem tls.crt; do
    if [[ -f "$cert_dir/$f" ]]; then
      podman unshare chown 101:101 "$cert_dir/$f" || true
      podman unshare chmod 644 "$cert_dir/$f" || true
    fi
  done
}

init_agent_if_missing() {
  local id="$1"
  local email display_name password gw_port dir
  dir="$(agent_home "$id")"
  load_env
  case "$id" in
    agent-a)
      email="$AGENT_A_EMAIL"
      display_name="$AGENT_A_DISPLAY_NAME"
      password="${AGENT_A_PASSWORD:-}"
      gw_port="$AGENT_A_GATEWAY_PORT"
      ;;
    agent-b)
      email="$AGENT_B_EMAIL"
      display_name="$AGENT_B_DISPLAY_NAME"
      password="${AGENT_B_PASSWORD:-}"
      gw_port="$AGENT_B_GATEWAY_PORT"
      ;;
    agent-c)
      email="$AGENT_C_EMAIL"
      display_name="$AGENT_C_DISPLAY_NAME"
      password="${AGENT_C_PASSWORD:-}"
      gw_port="$AGENT_C_GATEWAY_PORT"
      ;;
    *) echo "unknown agent: $id" >&2; return 1 ;;
  esac

  echo "==> Initializing ${id} at ${dir}"
  mkdir -p "$dir/workspace" "$dir/canvas" "$dir/cron" "$dir/.config" "$dir/secrets"
  chmod 700 "$dir" "$dir/workspace" "$dir/secrets" 2>/dev/null || true

  write_himalaya_config "$email" "$display_name" "$dir"
  write_himalaya_send_script "$email" "$display_name" "$dir"
  write_agent_email_doc "$email" "$display_name" "$dir"
  write_openclaw_json "$dir" "$gw_port"
  ensure_agent_env "$dir"

  if [[ -n "$password" ]]; then
    write_secret_helpers "$dir" "$password"
  fi
}

ensure_agent_runtime() {
  local id="$1"
  local dir
  dir="$(agent_home "$id")"

  if [[ ! -f "$dir/openclaw.json" ]]; then
    init_agent_if_missing "$id"
  fi

  load_env

  ensure_production_ingress_config "$id" "$dir"
  ensure_agent_bootstrap "$id" "$dir"
  sync_discord_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"
}

start_agent_in_pod() {
  local id="$1"
  local dir container gw_port z
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  gw_port="$(agent_internal_gateway_port "$id")"
  z="$(selinux_mount_suffix)"

  [[ -f "$dir/.env" ]] || { echo "Missing ${dir}/.env — run identyclaw.sh init ${id}" >&2; exit 1; }
  prepare_agent_state_for_gateway_start "$id" pod

  podman run -d \
    --pod "$POD_NAME" \
    --name "$container" \
    --init \
    --replace \
    --restart unless-stopped \
    -e HOME=/home/node \
    -e OPENCLAW_NO_RESPAWN=1 \
    --env-file "$dir/.env" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    "$OPENCLAW_IMAGE" \
    node dist/index.js gateway --bind lan --port "$gw_port"
}

require_podman

mkdir -p "$IDENTYCLAW_AGENT_STATE_ROOT"

if [[ "${SKIP_PULL:-0}" == 1 ]]; then
  echo "==> Skip pull (SKIP_PULL=1) — using local images"
  podman image exists "$OPENCLAW_IMAGE" || { echo "Missing image: $OPENCLAW_IMAGE" >&2; exit 1; }
  podman image exists "$NGINX_IMAGE" || { echo "Missing image: $NGINX_IMAGE" >&2; exit 1; }
else
  echo "==> Pull images"
  podman pull "$OPENCLAW_IMAGE"
  podman pull "$NGINX_IMAGE"
fi

echo "==> Recreate pod ${POD_NAME}"
for c in $AGENT_IDS "$NGINX_CONTAINER_NAME"; do
  podman container exists "$c" 2>/dev/null && podman rm -f "$c" || true
done
podman pod exists "$POD_NAME" 2>/dev/null && podman pod rm -f "$POD_NAME" || true

prepare_pod_deploy_host_paths

podman pod create --name "$POD_NAME" -p "${POD_HOST_PORT}:${POD_LISTEN_PORT}"

for id in $AGENT_IDS; do
  ensure_agent_runtime "$id"
done

for id in $AGENT_IDS; do
  echo "==> Start ${id} in pod"
  start_agent_in_pod "$id"
done

ensure_pod_logs_for_container "$APP_DIR/logs/nginx"
ensure_tls_certs
normalize_tls_certs

z="$(selinux_mount_suffix)"
echo "==> Start nginx sidecar"
podman run -d \
  --pod "$POD_NAME" \
  --name "$NGINX_CONTAINER_NAME" \
  --replace \
  --restart unless-stopped \
  -v "$APP_DIR/certs:/app/certs:ro${z}" \
  -v "$APP_DIR/logs/nginx:/var/log/nginx${z}" \
  "$NGINX_IMAGE"

podman ps -a --filter "pod=${POD_NAME}"
if [[ "$POD_HOST_PORT" == "$POD_LISTEN_PORT" ]]; then
  echo "==> Deploy complete — pod ${POD_NAME} on port ${POD_HOST_PORT}"
else
  echo "==> Deploy complete — pod ${POD_NAME} on host port ${POD_HOST_PORT} (container ${POD_LISTEN_PORT})"
fi
