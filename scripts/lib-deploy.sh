#!/usr/bin/env bash
# Podman pod, nginx sidecar, TLS, host layout, and container lifecycle.
# Sourced from scripts/lib.sh — do not execute directly.

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
    # Telegram Bot API webhooks only accept 80, 88, 443, or 8443.
    development|main) printf '8443' ;;
    *) return 1 ;;
  esac
}


deploy_tier_health_domain() {
  local id host
  load_env
  for id in $(configured_agent_ids); do
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

# Post-deploy health probe: first AGENT_IDS host + ingress port from env.local.
deploy_health_ingress() {
  local id host port
  load_env
  for id in $(configured_agent_ids); do
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
  mkdir -p "${app}"/{certs,logs/nginx,agents,exports,overlays}
  chmod 711 "${app}/certs" 2>/dev/null || true
  if [[ ! -f "$env_file" ]]; then
    cp "${IDENTYCLAW_ROOT}/env.example" "$env_file"
    chmod 600 "$env_file"
    echo "Created ${env_file} from env.example"
  fi
}

# Bootstrap TLS for nginx when no CA-issued certs are installed.
# RODiT JWT handles mutual auth on A2A/webhooks; self-signed PEMs encrypt transport only.

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
  for id in $(configured_agent_ids); do
    h="$(agent_public_host "$id")"
    [[ -n "$h" ]] || continue
    [[ -n "$extra_sans" ]] && extra_sans+=","
    extra_sans+="DNS:${h}"
  done
  if [[ -n "${IDENTYCLAW_INGRESS_ALT_HOST:-}" ]]; then
    extra_sans="${extra_sans},DNS:${IDENTYCLAW_INGRESS_ALT_HOST}"
  fi
  case "$force" in
    --force|1|true) args+=(--force) ;;
  esac
  local tls_cn=""
  for id in $(configured_agent_ids); do
    h="$(agent_public_host "$id")"
    [[ -n "$h" ]] && { tls_cn="$h"; break; }
  done
  TLS_CN="${tls_cn}" EXTRA_SANS="$extra_sans" \
    bash "${IDENTYCLAW_ROOT}/scripts/generate-self-signed-certs.sh" "$cert_dir" "${args[@]}"
}


ensure_identyclaw_network() {
  command -v podman >/dev/null 2>&1 || return 0
  load_env
  if ! podman network exists "$IDENTYCLAW_NETWORK" 2>/dev/null; then
    echo "    (creating Podman network ${IDENTYCLAW_NETWORK})" >&2
    podman network create "$IDENTYCLAW_NETWORK" >/dev/null
  fi
}

# Pod agents resolve their public ingress host to loopback so self-tests hit nginx in-pod
# (container DNS may differ from the host; e.g. agent-c.dev.identyclaw.com:8443).
pod_agent_ingress_host_args() {
  local id="$1" host
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  host="$(agent_public_host "$id")"
  [[ -n "$host" ]] && printf '%s\n' "--add-host=${host}:127.0.0.1"
}

# Migadu publishes multiple A/AAAA records; glibc may prefer broken IPv6, and MTA
# A records rotate. Pin smtp.migadu.com to a live IPv4 so Himalaya STARTTLS keeps
# the hostname for cert validation. Override with MIGADU_SMTP_IPV4; otherwise pick
# the first A record that accepts TCP 587 (stale hardcodes break SMTP send).
_migadu_smtp_ipv4_candidates() {
  if command -v dig >/dev/null 2>&1; then
    dig +short smtp.migadu.com A 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/'
  fi
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 smtp.migadu.com 2>/dev/null | awk '{ print $1 }'
  fi
  # Last-known-good fallbacks (update if Migadu rotates again)
  printf '%s\n' 57.128.22.240 51.210.223.36 141.94.97.118
}

_migadu_smtp_ipv4_reachable() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  timeout 2 bash -c "echo >/dev/tcp/${ip}/587" >/dev/null 2>&1
}

pod_migadu_smtp_host_args() {
  local ip cand
  load_env
  [[ "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]] || return 0
  ip="${MIGADU_SMTP_IPV4:-}"
  if [[ -n "$ip" ]]; then
    if ! _migadu_smtp_ipv4_reachable "$ip"; then
      echo "Warning: MIGADU_SMTP_IPV4=${ip} is not reachable on :587; probing DNS A records." >&2
      ip=""
    fi
  fi
  if [[ -z "$ip" ]]; then
    while IFS= read -r cand; do
      [[ -z "$cand" ]] && continue
      if _migadu_smtp_ipv4_reachable "$cand"; then
        ip="$cand"
        break
      fi
    done < <(_migadu_smtp_ipv4_candidates | awk '!seen[$0]++')
  fi
  [[ -n "$ip" ]] || return 0
  printf '%s\n' "--add-host=smtp.migadu.com:${ip}"
}

# HTTPS ingress from inside the agent container (pod nginx listens on deploy-tier app port, e.g. 8443).


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

# Map container-namespace ownership back to the deploy user (rootless uid 0 in podman unshare).
restore_pod_path_for_host() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  podman unshare chown -R 0:0 "$path" 2>/dev/null || true
}

# Stopped pod containers leave agent state owned by the container uid; the host cannot read .env
# until ownership is restored. Safe to call when the agent is already running (no-op).

# Stopped pod containers leave agent state owned by the container uid; the host cannot read .env
# until ownership is restored. Safe to call when the agent is already running (no-op).
prepare_pod_agent_host_access_for_start() {
  local id="$1"
  local dir container
  load_env
  [[ "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]] || return 0
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  [[ -d "$dir" ]] || return 0
  if [[ -r "$dir/.env" ]]; then
    return 0
  fi
  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    return 0
  fi
  podman rm -f "$container" 2>/dev/null || true
  restore_pod_path_for_host "$dir"
}

# Runtime mode follows the running container (pod vs keep-id standalone), not env alone.

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

# Pod agents map host state into the container user namespace (uid 1000 / node).
# Host CLI (token, status, bootstrap) needs the inverse — see restore_pod_agent_state_for_host.
ensure_pod_agent_state_for_container() {
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  [[ -n "${IDENTYCLAW_AGENT_STATE_ROOT:-}" ]] || return 0
  local ids=("$@")
  local id dir
  if [[ ${#ids[@]} -eq 0 ]]; then
    read -ra ids <<< "$(configured_agent_ids)"
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
    read -ra ids <<< "$(configured_agent_ids)"
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

# Gateway restart leaves orphaned session locks; clear them only while the container is stopped.
remove_stale_session_locks() {
  local config_dir="$1"
  local sessions_root="$config_dir/agents"
  [[ -d "$sessions_root" ]] || return 0
  find "$sessions_root" -name '*.jsonl.lock' -type f -delete 2>/dev/null || true
}

# Normalize ownership + drop stale locks before (re)starting a gateway container.

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

# Nginx sidecar logs run as uid 101 inside the container user namespace.
ensure_pod_logs_for_container() {
  local log_dir="$1"
  mkdir -p "$log_dir"
  chmod 0775 "$log_dir" 2>/dev/null || true
  podman unshare chown -R 101:101 "$log_dir" 2>/dev/null || true
}

# Restore ownership so the deploy user can read/write agent state on the host.
# Skip agents whose gateway is running — restore races with pod container uid (1000).

# Restore ownership so the deploy user can read/write agent state on the host.
# Skip agents whose gateway is running — restore races with pod container uid (1000).
restore_pod_agent_state_for_host() {
  local ids
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  [[ -n "${IDENTYCLAW_AGENT_STATE_ROOT:-}" ]] || return 0
  ids="${1:-$(configured_agent_ids)}"
  local id dir container
  for id in $ids; do
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

# Before host-side deploy writes (config bootstrap, mkdir, chmod), undo container-namespace
# ownership left by the previous pod run. Call after stopping/removing pod containers.
prepare_pod_deploy_host_paths() {
  local app id dir json
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || return 0
  app="${IDENTYCLAW_APP_DIR:-${APP_DIR:-}}"
  [[ -n "$app" ]] || return 0
  echo "==> Restore host ownership for pod deploy paths"
  # Force restore even if a ghost/exited container name still exists in local storage.
  for id in $(configured_agent_ids); do
    dir="$(agent_home "$id")"
    [[ -d "$dir" ]] || continue
    podman rm -f "$(agent_container "$id")" 2>/dev/null || true
    restore_pod_path_for_host "$dir"
    json="${dir}/openclaw.json"
    if [[ -e "$json" ]] && ! { [[ -r "$json" && -w "$json" ]]; }; then
      echo "FATAL: ${json} not host-writable after ownership restore — refuse to continue deploy" >&2
      return 1
    fi
  done
  restore_pod_path_for_host "${app}/logs/nginx"
}

# Stop pod agents and map state dirs back to the deploy user (for editing creds/.env on the host).

# Stop pod agents and map state dirs back to the deploy user (for editing creds/.env on the host).
restore_host_access_for_agents() {
  local ids="${1:-$(configured_agent_ids)}"
  local id container
  load_env
  [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]] || {
    echo "restore-host-access is only needed when IDENTYCLAW_DEPLOY_MODE=pod" >&2
    return 1
  }
  for id in $ids; do
    container="$(agent_container "$id")"
    if podman ps --format '{{.Names}}' | grep -qx "$container"; then
      echo "==> Stopping ${container}"
      podman stop "$container" >/dev/null || true
    fi
    # Exited containers still block restore_pod_agent_state_for_host (container exists check).
    if podman container exists "$container" 2>/dev/null; then
      podman rm -f "$container" >/dev/null || true
    fi
  done
  restore_pod_agent_state_for_host "$ids"
  echo "Host ownership restored under ${IDENTYCLAW_AGENT_STATE_ROOT:-$(identyclaw_app_dir)/agents}."
  echo "Edit creds or .env, then: ./identyclaw.sh start all"
}

# Host restore (0:0) and container access (1000:1000) conflict in pod userns — skip restore for exec-only commands.

# Host restore (0:0) and container access (1000:1000) conflict in pod userns — skip restore for exec-only commands.
identyclaw_skips_host_restore() {
  case "${1:-}" in
    chat|ask|logs|pairing|test-mail|test-mail-hola|respond-mail|enable-mail-responder|respond-a2a-webhook-smoke|enable-a2a-webhook-smoke-responder|respond-a2a-hola-smoke|enable-a2a-hola-smoke-responder|test-a2a|test-webhook|test-webhook-p2p|send-rodit-webhook|upgrade-plugins|install-bearer-http|sync-a2a-peers|discover-a2a-peers|build-image|start|restart|near-activate|stop|status|restore-host-access|fix-session-images|doctor-fix|cleanup-sessions|enable-session-cleanup|retire-exec-approvals|set-telegram-token|set-discord-token|set-password|enable-slc-heartbeat|factory-reset|""|-h|--help|help) return 0 ;;
    *) return 1 ;;
  esac
}

# Standalone start/restart touches host-owned openclaw.json; pod deploy uses container-namespace ownership.
# Pod mode: identyclaw.sh start → start_pod_agent (start); restart → start_pod_agent (restart).

# Read AGENT_IDS from env.local (used by deploy.yml host prep and deploy-pod.sh).

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
  ids="${AGENT_IDS:-}"
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
  if [[ -z "$ids" ]]; then
    ids="$(configured_agent_ids)"
  fi
  echo "$ids"
}

# Start or restart a pod-managed agent without host-side bootstrap (avoids openclaw.json EACCES).
# Second arg: start (idempotent — no-op if running) or restart (bounce gateway if running).

# Start or restart a pod-managed agent without host-side bootstrap (avoids openclaw.json EACCES).
# Second arg: start (idempotent — no-op if running) or restart (bounce gateway if running).
wait_for_running_agent_container() {
  local container="$1"
  local attempt
  for attempt in $(seq 1 40); do
    if podman ps --format '{{.Names}}' | grep -qx "$container" \
      && podman exec "$container" true 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "Timed out waiting for ${container} to start" >&2
  return 1
}

# Recreate a pod agent container so --env-file picks up .env changes (podman restart does not).
# Pod userns leaves agent dirs owned by the container uid; restore host ownership before
# reading --env-file (same pattern as recreate_pod_agent_gateway).

# Recreate a pod agent container so --env-file picks up .env changes (podman restart does not).
# Pod userns leaves agent dirs owned by the container uid; restore host ownership before
# reading --env-file (same pattern as recreate_pod_agent_gateway).
recreate_pod_agent_container() {
  local id="$1"
  local dir container gw_port image pod_name z tls_env=()
  load_env
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  gw_port="$(agent_internal_gateway_port "$id")"
  pod_name="${POD_NAME:-identyclaw-agents-pod}"
  z="$(selinux_mount_suffix)"
  if a2a_tls_skip_verify_enabled; then
    tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  fi

  image="$(resolve_openclaw_run_image "$container")" || {
    echo "No OpenClaw agent image available to recreate ${container}." >&2
    echo "Configured $(openclaw_agent_image) is not present locally; no sibling container or openclaw-agent image to reuse." >&2
    echo "Set OPENCLAW_IMAGE, run ./identyclaw.sh build-image, or redeploy." >&2
    return 1
  }

  # Drop container ownership, then map state back to the deploy user so --env-file is readable.
  prepare_agent_state_for_gateway_start "$id" pod
  podman rm -f "$container" 2>/dev/null || true
  restore_pod_path_for_host "$dir"
  if [[ ! -f "$dir/.env" ]]; then
    echo "Missing ${dir}/.env — run identyclaw.sh init ${id}" >&2
    return 1
  fi
  sync_identyclaw_env "$dir" ""
  ensure_idcp_wallet_tooling "$id" "$dir" || true
  mkdir -p "$dir/xdg-config"

  echo "    (${id}: recreating with image ${image})" >&2
  podman run -d \
    --pod "$pod_name" \
    --name "$container" \
    --init \
    --replace \
    --shm-size=2g \
    --restart unless-stopped \
    -e HOME=/home/node \
    -e XDG_CONFIG_HOME=/home/node/.openclaw/xdg-config \
    -e OPENCLAW_NO_RESPAWN=1 \
    "${tls_env[@]}" \
    --env-file "$dir/.env" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    "$image" \
    node dist/index.js gateway --bind lan --port "$gw_port"
  ensure_pod_agent_state_for_container "$id"
}


start_pod_agent() {
  local id="$1"
  local mode="${2:-restart}"
  local container dir
  load_env
  container="$(agent_container "$id")"
  dir="$(agent_home "$id")"

  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    if [[ "$mode" == "start" ]]; then
      ensure_agent_state_for_container_exec "$id"
      ensure_agent_mail_tooling_refresh "$id" "$dir"
      ensure_agent_security_hardening "$id" "$dir" "$container"
      ensure_main_ingress_config "$id" "$dir" "$container"
      sync_quiet_plugin_env "$dir" "$container"
      sync_agent_plugin_configs "$id" "$dir" || true
      echo "Already running: ${container} (synced .env + plugins; use './identyclaw.sh restart ${id}' to bounce the gateway)"
      return 0
    fi
    echo "==> ${id} already running in pod — syncing credentials/.env and recreating container (refresh --env-file)"
    sync_a2a_peers_from_logs "$id" || true
    ensure_agent_state_for_container_exec "$id"
    ensure_agent_mail_tooling_refresh "$id" "$dir"
    ensure_idcp_wallet_tooling "$id" "$dir" "$container" || true
    ensure_agent_security_hardening "$id" "$dir" "$container" || true
    ensure_main_ingress_config "$id" "$dir" "$container" || true
    # Skip openclaw.json mutations here — host often cannot write container-owned
    # state, and recreate drops the container mid-sync. Post-recreate sync below.
    ensure_llm_sqlite_auth "$id" || true
    recreate_pod_agent_container "$id"
    container="$(agent_container "$id")"
    wait_for_running_agent_container "$container" || return 1
    ensure_agent_mail_tooling_refresh "$id" "$dir"
    # Post-recreate: container owns state — sync plugins/A2A/models now.
    ensure_openclaw_model_defaults "$dir" "$container" "$id" || true
    ensure_memory_config "$dir" "$container" || true
    ensure_session_maintenance_config "$dir" "$container" || true
    ensure_compaction_config "$dir" "$container" || true
    sync_quiet_plugin_env "$dir" "$container" || true
    sync_agent_plugin_configs "$id" "$dir" || true
    ensure_llm_sqlite_auth "$id" || true
    sync_agent_openclaw_json_when_container_running "$id"
    ensure_discord_plugin_compat_and_restart "$id"
    ensure_openclaw_tool_result_image_patch "$id" || true
    ensure_identyclaw_request_body_patch "$id" || true
    echo "Recreated ${container}"
    return 0
  fi

  if podman container exists "$container" 2>/dev/null; then
    ensure_agent_mail_tooling_refresh "$id" "$dir" || true
    recreate_pod_agent_container "$id"
    container="$(agent_container "$id")"
    wait_for_running_agent_container "$container" || return 1
    ensure_agent_mail_tooling_refresh "$id" "$dir"
    ensure_openclaw_model_defaults "$dir" "$container" "$id"
    ensure_memory_config "$dir" "$container"
    ensure_session_maintenance_config "$dir" "$container"
    ensure_compaction_config "$dir" "$container"
    sync_agent_plugin_configs "$id" "$dir" || true
    ensure_llm_sqlite_auth "$id"
    sync_agent_openclaw_json_when_container_running "$id"
    ensure_discord_plugin_compat_and_restart "$id"
    ensure_openclaw_tool_result_image_patch "$id" || true
    ensure_identyclaw_request_body_patch "$id" || true
    echo "Started ${container} (pod container)"
    return 0
  fi

  # No pod container yet — recreate in an existing pod after restore-host-access, or run full deploy.
  [[ -d "$dir" ]] || {
    echo "Missing ${dir} — run deploy or ./identyclaw.sh init ${id}" >&2
    return 1
  }
  local pod_name="${POD_NAME:-identyclaw-agents-pod}"
  prepare_pod_agent_host_access_for_start "$id"
  if podman pod exists "$pod_name" 2>/dev/null && [[ -f "$dir/.env" ]]; then
    echo "==> Recreating ${container} in pod ${pod_name}"
    sync_a2a_peers_from_logs "$id" || true
    ensure_agent_mail_tooling_refresh "$id" "$dir" || true
    recreate_pod_agent_container "$id"
    container="$(agent_container "$id")"
    wait_for_running_agent_container "$container" || return 1
    ensure_agent_mail_tooling_refresh "$id" "$dir"
    ensure_openclaw_model_defaults "$dir" "$container" "$id"
    ensure_memory_config "$dir" "$container"
    ensure_session_maintenance_config "$dir" "$container"
    ensure_compaction_config "$dir" "$container"
    sync_agent_plugin_configs "$id" "$dir" || true
    ensure_llm_sqlite_auth "$id"
    sync_agent_openclaw_json_when_container_running "$id"
    ensure_discord_plugin_compat_and_restart "$id"
    ensure_openclaw_tool_result_image_patch "$id" || true
    ensure_identyclaw_request_body_patch "$id" || true
    echo "Started ${container} (pod container)"
    return 0
  fi
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
  # Image build context for ./identyclaw.sh build-image when operators use APP_DIR/repo.
  # Includes request-body + tool-result patches baked into /opt/identyclaw.
  if [[ -f "${repo_root}/Containerfile.agent" ]]; then
    cp -a "${repo_root}/Containerfile.agent" "${app_dir}/repo/"
  fi
  if [[ -f "${repo_root}/nginx.Dockerfile" ]]; then
    cp -a "${repo_root}/nginx.Dockerfile" "${app_dir}/repo/"
  fi
  # Sidecar includes live under APP_DIR (not the git clone path) so nginx survives
  # checkout rename/move. deploy-pod.sh copies the same tree on recreate.
  if [[ -d "${repo_root}/nginx" ]]; then
    mkdir -p "${app_dir}/repo/nginx"
    cp -a "${repo_root}/nginx/." "${app_dir}/repo/nginx/"
  fi
}


openclaw_agent_image() {
  load_env
  echo "${OPENCLAW_IMAGE:-${OPENCLAW_LOCAL_IMAGE:-${OPENCLAW_BASE_IMAGE}}}"
}

# Image used to (re)create an agent container. Prefer a locally present configured
# ref; otherwise reuse this container, a sibling AGENT_IDS container, or any
# openclaw-agent image still in local storage (CI hosts often have GHCR tags
# while env.local still lists localhost/openclaw-agent:local).

# Image used to (re)create an agent container. Prefer a locally present configured
# ref; otherwise reuse this container, a sibling AGENT_IDS container, or any
# openclaw-agent image still in local storage (CI hosts often have GHCR tags
# while env.local still lists localhost/openclaw-agent:local).
resolve_openclaw_run_image() {
  local container="${1:-}"
  local image inspect_image id sibling listed
  load_env
  image="$(openclaw_agent_image)"
  if [[ -n "$image" ]] && podman image exists "$image" 2>/dev/null; then
    printf '%s\n' "$image"
    return 0
  fi
  if [[ -n "$container" ]]; then
    inspect_image="$(podman inspect "$container" --format '{{.Config.Image}}' 2>/dev/null || true)"
    if [[ -n "$inspect_image" ]]; then
      printf '%s\n' "$inspect_image"
      return 0
    fi
  fi
  for id in ${AGENT_IDS:-}; do
    sibling="$(agent_container "$id")"
    [[ -n "$sibling" && "$sibling" != "$container" ]] || continue
    inspect_image="$(podman inspect "$sibling" --format '{{.Config.Image}}' 2>/dev/null || true)"
    if [[ -n "$inspect_image" ]]; then
      printf '%s\n' "$inspect_image"
      return 0
    fi
  done
  listed="$(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | awk '
    index($0, "openclaw-agent") && $0 !~ /:<none>$/ { print; exit }
  ' || true)"
  if [[ -n "$listed" ]]; then
    printf '%s\n' "$listed"
    return 0
  fi
  return 1
}

# Recreate a pod agent gateway so --env-file picks up .env changes (podman restart does not).

# Recreate a pod agent gateway so --env-file picks up .env changes (podman restart does not).
recreate_pod_agent_gateway() {
  local id="$1"
  local dir container gw_port z tls_env=() image pod_name
  load_env
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  gw_port="$(agent_internal_gateway_port "$id")"
  z="$(selinux_mount_suffix)"
  image="$(resolve_openclaw_run_image "$container")" || {
    echo "No OpenClaw agent image available to recreate ${container}." >&2
    echo "Configured $(openclaw_agent_image) is not present locally; no sibling container or openclaw-agent image to reuse." >&2
    echo "Set OPENCLAW_IMAGE, run ./identyclaw.sh build-image, or redeploy." >&2
    return 1
  }
  pod_name="${POD_NAME:-identyclaw-agents-pod}"
  if a2a_tls_skip_verify_enabled; then
    tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  fi
  prepare_agent_state_for_gateway_start "$id" pod
  podman rm -f "$container" 2>/dev/null || true
  restore_pod_path_for_host "$dir"
  if [[ -f "$dir/.env" ]]; then
    :
  elif podman container exists "$container" 2>/dev/null \
    && podman exec "$container" test -f /home/node/.openclaw/.env 2>/dev/null; then
    :
  else
    echo "Missing ${dir}/.env — run identyclaw.sh init ${id}" >&2
    return 1
  fi
  mkdir -p "$dir/xdg-config"
  ensure_idcp_wallet_tooling "$id" "$dir" || true
  podman run -d \
    --pod "$pod_name" \
    --name "$container" \
    --init \
    --replace \
    --shm-size=2g \
    --restart unless-stopped \
    -e HOME=/home/node \
    -e XDG_CONFIG_HOME=/home/node/.openclaw/xdg-config \
    -e OPENCLAW_NO_RESPAWN=1 \
    "${tls_env[@]}" \
    --env-file "$dir/.env" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    "$image" \
    node dist/index.js gateway --bind lan --port "$gw_port"
  ensure_pod_agent_state_for_container "$id"
}

# Run OpenClaw CLI against an agent state dir (live container or ephemeral podman run).

# Run OpenClaw CLI against an agent state dir (live container or ephemeral podman run).
openclaw_agent_exec() {
  local config_dir="$1"
  local container="$2"
  shift 2
  local z image
  load_env
  z="$(selinux_mount_suffix)"
  image="$(openclaw_agent_image)"

  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    ensure_openclaw_cli_link "$container"
    podman exec "$container" env HOME=/home/node OPENCLAW_STATE_DIR=/home/node/.openclaw \
      node /app/openclaw.mjs "$@"
    return $?
  fi

  # Pod userns leaves agent state owned by the container uid. An ephemeral
  # keep-id run cannot write that tree (mkdir /home/node/.openclaw → EACCES).
  if [[ ! -w "$config_dir" ]]; then
    echo "    (openclaw CLI: ${container:-container} is not running and ${config_dir} is not host-writable)" >&2
    return 1
  fi

  podman run --rm --userns=keep-id \
    -e HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/home/node/.openclaw \
    -v "${config_dir}:/home/node/.openclaw:rw${z}" \
    "$image" \
    node /app/openclaw.mjs "$@"
}

# Copy nginx/inc from the current git checkout into APP_DIR and render nginx.conf.
# Sidecar bind mounts must use APP_DIR only — never the clone path — so a repo
# rename/move or CI rebuild cannot leave nginx pointing at a missing directory.
prepare_pod_nginx_host_files() {
  load_env
  local app repo tier nginx_conf render
  app="$(identyclaw_app_dir)"
  repo="${REPO_ROOT:-${IDENTYCLAW_ROOT}}"
  tier="$(resolve_deploy_tier "$repo" "${OPENCLAW_IMAGE:-}")"
  nginx_conf="${app}/nginx/nginx.conf"
  mkdir -p "${app}/nginx"
  if [[ -d "${repo}/nginx/inc" ]]; then
    mkdir -p "${app}/nginx/inc"
    cp -a "${repo}/nginx/inc/." "${app}/nginx/inc/"
  fi
  render="${repo}/scripts/render-nginx-conf.sh"
  [[ -f "$render" ]] || {
    echo "missing ${render} — sync deploy scripts (include scripts/ + nginx/)" >&2
    return 1
  }
  bash "$render" "$tier" "$nginx_conf"
}

# Host bind sources for the nginx sidecar. All paths are under APP_DIR.
# Prints "host_src:container_dst" (no SELinux suffix). Used by tests + recreate.

# Host bind sources for the nginx sidecar. All paths are under APP_DIR.
# Prints "host_src:container_dst" (no SELinux suffix). Used by tests + recreate.
pod_nginx_bind_specs() {
  local app="${1:-$(identyclaw_app_dir)}"
  printf '%s\n' \
    "${app}/certs:/app/certs" \
    "${app}/logs/nginx:/var/log/nginx"
  if [[ -d "${app}/nginx/inc" ]]; then
    printf '%s\n' "${app}/nginx/inc:/etc/nginx/inc"
  fi
  printf '%s\n' "${app}/nginx/nginx.conf:/etc/nginx/nginx.conf"
}


resolve_nginx_image() {
  local container image
  container="${NGINX_CONTAINER_NAME:-openclaw-nginx}"
  if [[ -n "${NGINX_IMAGE:-}" ]]; then
    printf '%s\n' "$NGINX_IMAGE"
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman container exists "$container" 2>/dev/null; then
    image="$(podman inspect "$container" --format '{{.Config.Image}}' 2>/dev/null || true)"
    if [[ -n "$image" ]]; then
      printf '%s\n' "$image"
      return 0
    fi
  fi
  echo "Set NGINX_IMAGE or run ./scripts/deploy-local-podman.sh to create the nginx sidecar" >&2
  return 1
}

# Recreate openclaw-nginx with APP_DIR binds (certs, logs, rendered conf, copied inc).
# Safe while agent containers keep running. Replaces stale clone-path mounts.

# Recreate openclaw-nginx with APP_DIR binds (certs, logs, rendered conf, copied inc).
# Safe while agent containers keep running. Replaces stale clone-path mounts.
recreate_pod_nginx_sidecar() {
  load_env
  [[ "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]] || return 0
  local app container image z pod_name nginx_conf vol_args=()
  app="$(identyclaw_app_dir)"
  container="${NGINX_CONTAINER_NAME:-openclaw-nginx}"
  pod_name="${POD_NAME:-identyclaw-agents-pod}"
  prepare_pod_nginx_host_files || return 1
  ensure_pod_logs_for_container "${app}/logs/nginx"
  image="$(resolve_nginx_image)" || return 1
  z="$(selinux_mount_suffix)"
  nginx_conf="${app}/nginx/nginx.conf"
  [[ -f "$nginx_conf" ]] || {
    echo "missing ${nginx_conf}" >&2
    return 1
  }
  [[ -d "${app}/certs" ]] || {
    echo "missing ${app}/certs — run ./identyclaw.sh generate-certs" >&2
    return 1
  }
  if ! podman pod exists "$pod_name" 2>/dev/null; then
    echo "pod ${pod_name} does not exist — run ./scripts/deploy-local-podman.sh" >&2
    return 1
  fi
  vol_args=(
    -v "${app}/certs:/app/certs:ro${z}"
    -v "${app}/logs/nginx:/var/log/nginx${z}"
    -v "${nginx_conf}:/etc/nginx/nginx.conf:ro${z}"
  )
  if [[ -d "${app}/nginx/inc" ]]; then
    vol_args+=(-v "${app}/nginx/inc:/etc/nginx/inc:ro${z}")
  fi
  echo "==> Recreate nginx sidecar ${container} (mounts under ${app})"
  # NET_BIND_SERVICE keeps low ports (80/88/443) workable; 8443 does not need it.
  podman run -d \
    --pod "$pod_name" \
    --name "$container" \
    --replace \
    --restart unless-stopped \
    --cap-add NET_BIND_SERVICE \
    "${vol_args[@]}" \
    "$image"
}

# Render + recreate sidecar so start/restart/deploy never keep clone-path binds.

# Render + recreate sidecar so start/restart/deploy never keep clone-path binds.
ensure_pod_nginx_sidecar() {
  load_env
  [[ "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]] || return 0
  recreate_pod_nginx_sidecar
}

# Back-compat name: render files, then recreate (or reload) the sidecar.

# Back-compat name: render files, then recreate (or reload) the sidecar.
ensure_pod_nginx_ingress_config() {
  ensure_pod_nginx_sidecar
}
