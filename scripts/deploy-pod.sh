#!/usr/bin/env bash
# Main-tier pod deploy: Podman pod with nginx TLS sidecar + OpenClaw agent containers.
# Mirrors .github/workflows/deploy.yml host steps. Run on the deployment host.
#
# Required env:
#   APP_DIR              Host app root (default: ../identyclaw-agents-app sibling of repo)
#   OPENCLAW_IMAGE       Full image ref (ghcr.io/.../openclaw-himalaya:SHA)
#   NGINX_IMAGE          Full image ref (ghcr.io/.../identyclaw-nginx:SHA)
#
# Optional env (defaults match deploy.yml):
#   DEPLOY_TIER / TARGET   main (default: image tag, else git branch)
#   APP_PORT=9443 — defaults via deploy_tier_app_port
#   POD_NAME=identyclaw-agents-pod
#   NGINX_CONTAINER_NAME=identyclaw-nginx
#   IDENTYCLAW_AGENT_STATE_ROOT  (default: ${APP_DIR}/agents)
#   REPO_ROOT            Git checkout path (for identyclaw.sh init/bootstrap)
#   AGENT_IDS            Space-separated list (default: agent-name-not-set)
#   SKIP_PLUGIN_UPDATE=1 Skip GitHub plugin clone/build/install (requires git + npm when unset)

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

DEPLOY_TIER="${DEPLOY_TIER:-main}"
case "$DEPLOY_TIER" in
  main) ;;
  *)
    echo "DEPLOY_TIER must be main (got: $DEPLOY_TIER)" >&2
    exit 1
    ;;
esac
APP_PORT="${APP_PORT:-$(deploy_tier_app_port "$DEPLOY_TIER")}"
POD_LISTEN_PORT="${POD_LISTEN_PORT:-$APP_PORT}"
POD_HOST_PORT="${POD_HOST_PORT:-$APP_PORT}"

ensure_app_layout
load_env
AGENT_IDS="${AGENT_IDS:-agent-name-not-set}"

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
  is_valid_agent_id "$id" || { echo "unknown agent: $id" >&2; return 1; }
  email="$(agent_email "$id")"
  display_name="$(agent_display_name "$id")"
  password="$(agent_env_value "$id" PASSWORD "")"
  gw_port="$(agent_env_value "$id" GATEWAY_PORT "")"
  [[ -n "$email" && -n "$gw_port" ]] || { echo "unknown agent: $id (set AGENT_*_EMAIL / GATEWAY_PORT in env.local)" >&2; return 1; }

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

  ensure_main_ingress_config "$id" "$dir"
  ensure_agent_bootstrap "$id" "$dir"
  sync_discord_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"
}

start_agent_in_pod() {
  local id="$1"
  local dir container gw_port z tls_env=() env_file tmp_env=""
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  gw_port="$(agent_internal_gateway_port "$id")"
  z="$(selinux_mount_suffix)"
  if a2a_tls_skip_verify_enabled; then
    tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  fi

  env_file="$(agent_env_file_for_podman_run "$dir" "$container")" || {
    echo "Missing ${dir}/.env — run identyclaw.sh init ${id}" >&2
    exit 1
  }
  [[ "$env_file" == "${dir}/.env" ]] || tmp_env="$env_file"
  # Plugin bootstrap leaves container-namespace ownership; restore host write access
  # for .env sync, then chown back to the pod uid before podman run.
  restore_pod_path_for_host "$dir"
  sync_identyclaw_env "$dir" "$container"
  ensure_llm_env_auth "$id"
  prepare_agent_state_for_gateway_start "$id" pod

  podman run -d \
    --pod "$POD_NAME" \
    --name "$container" \
    --init \
    --replace \
    --shm-size=2g \
    --restart unless-stopped \
    -e HOME=/home/node \
    -e OPENCLAW_NO_RESPAWN=1 \
    "${tls_env[@]}" \
    --env-file "$env_file" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    "$OPENCLAW_IMAGE" \
    node dist/index.js gateway --bind lan --port "$gw_port"
  if [[ -n "$tmp_env" ]]; then rm -f "$tmp_env"; fi
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

pod_publish_ports=("$POD_LISTEN_PORT")
for id in $AGENT_IDS; do
  agent_port="$(agent_ingress_port "$id")"
  [[ -n "$agent_port" ]] || continue
  found=0
  for p in "${pod_publish_ports[@]}"; do
    [[ "$p" == "$agent_port" ]] && { found=1; break; }
  done
  [[ "$found" -eq 0 ]] && pod_publish_ports+=("$agent_port")
done

pod_create_args=(--name "$POD_NAME")
for p in "${pod_publish_ports[@]}"; do
  pod_create_args+=(-p "${p}:${p}")
done
for id in $AGENT_IDS; do
  while IFS= read -r host_arg; do
    [[ -n "$host_arg" ]] && pod_create_args+=("$host_arg")
  done < <(pod_agent_ingress_host_args "$id")
done
podman pod create "${pod_create_args[@]}"

for id in $AGENT_IDS; do
  ensure_agent_runtime "$id"
done

# Plugin build/install while host still owns agent state (before chown to container uid).
if [[ "${SKIP_PLUGIN_UPDATE:-0}" != 1 ]]; then
  for id in $AGENT_IDS; do
    upgrade_agent_plugins "$id"
    ensure_agent_packages "$id"
  done
else
  echo "==> Skip plugin update (SKIP_PLUGIN_UPDATE=1)"
fi

for id in $AGENT_IDS; do
  echo "==> Start ${id} in pod"
  start_agent_in_pod "$id"
  # Best-effort post-start steps: the freshly started gateway may still be
  # initializing, so a transient non-zero here must not abort the deploy before
  # the nginx sidecar starts. bootstrap re-runs these on the next deploy anyway.
  ensure_agent_trust_doc "$id" "$(agent_home "$id")" || \
    echo "    (${id}: ensure_agent_trust_doc deferred — will retry next deploy)" >&2
  sync_agent_openclaw_json_when_container_running "$id" 0 || \
    echo "    (${id}: openclaw.json sync deferred — will retry next deploy)" >&2
  ensure_discord_plugin_compat_and_restart "$id" || \
    echo "    (${id}: discord plugin compat deferred — will retry next deploy)" >&2
done

ensure_pod_logs_for_container "$APP_DIR/logs/nginx"
ensure_tls_certs
normalize_tls_certs

NGINX_CONF="${APP_DIR}/nginx/nginx.conf"
bash "$REPO_ROOT/scripts/render-nginx-conf.sh" "$NGINX_CONF"

z="$(selinux_mount_suffix)"
echo "==> Start nginx sidecar"
podman run -d \
  --pod "$POD_NAME" \
  --name "$NGINX_CONTAINER_NAME" \
  --replace \
  --restart unless-stopped \
  -v "$APP_DIR/certs:/app/certs:ro${z}" \
  -v "$APP_DIR/logs/nginx:/var/log/nginx${z}" \
  -v "$NGINX_CONF:/etc/nginx/nginx.conf:ro${z}" \
  "$NGINX_IMAGE"

podman ps -a --filter "pod=${POD_NAME}"
if [[ "$POD_HOST_PORT" == "$POD_LISTEN_PORT" ]]; then
  echo "==> Deploy complete — pod ${POD_NAME} on port ${POD_HOST_PORT}"
else
  echo "==> Deploy complete — pod ${POD_NAME} on host port ${POD_HOST_PORT} (container ${POD_LISTEN_PORT})"
fi

if [[ "${IDENTYCLAW_ENABLE_MAIL_RESPONDER:-1}" != 0 ]]; then
  echo "==> Enable inbound HOLA mail responder (systemd user timer)"
  bash "$REPO_ROOT/identyclaw.sh" enable-mail-responder "${IDENTYCLAW_MAIL_RESPONDER_INTERVAL:-2min}" || \
    echo "    (mail responder timer not installed — run ./identyclaw.sh enable-mail-responder manually)" >&2
fi

echo "Restart gateway(s): ${REPO_ROOT}/identyclaw.sh restart all"
echo "Full redeploy: ./scripts/deploy-local-podman.sh --skip-build"
