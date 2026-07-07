#!/usr/bin/env bash
# OpenClaw + IdentyClaw agent deploy template (Podman).
#
# Rootless (recommended): ./identyclaw.sh <cmd>
# Rootful (optional):      sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh <cmd>
#
# Commands:
#   build-image          Pull base + build openclaw-himalaya:local
#   init                 Create agent dirs from AGENT_IDS in env.local
#   set-password <id>    Set Migadu mailbox password (agent-{slug})
#   set-discord-token <id>  Store Discord bot token in secrets/
#   set-instagram <id>      Store Instagram username/password in secrets/
#   set-twitter <id>        Store X/Twitter login + enable hourly DM polling
#   set-twitter-cookies <id>  Store X session cookies for bird-twitter skill
#   start [id|all]       Start one or all agents in AGENT_IDS
#   stop [id|all]        Stop containers
#   restart [id|all]     Restart
#   restore-host-access [id|all]  Stop pod agents and restore host ownership
#   enable-boot          One-time: linger + podman-restart (survives reboot)
#   status               Show podman + health URLs
#   logs <id>            Follow logs
#   test [id]            Smoke-test local agent (A2A, webhooks, optional mail)
#   test-peer-gateway    Unit tests: metadata.webhook_url → agent card URL
#   test-mail [id]       himalaya INBOX list inside container
#   test-a2a [id]        Local agent-card discovery + inbound /a2a auth probe
#   test-a2a-auth [id]   P2P JWT on local /a2a
#   test-webhook [id]    Webhook ingress + optional /api/testhola delivery
#   respond-mail [id|all]  Poll INBOX, verify inbound HOLA, reply (cron entry point)
#   enable-mail-responder [interval]  Install user systemd timer for respond-mail
#   generate-certs [--force]  Issue self-signed TLS PEMs for pod ingress
#   send-rodit-webhook <id> <peer-token-id> [text]  POST signed /hooks/wake to peer
#   webhook-url <id> [path]  Print public HTTPS webhook URL
#   set-api-key <id> [key]     Store OpenRouter API key (validated)
#   set-opencode-key <id> [key]  Store OpenCode Zen/Go API key (validated)
#   mirror <to> [from]     Copy working openclaw.json + auth from another agent
#   export-agent <id> [file]  Pack agent secrets + config for migration
#   import-agent <id> <file>  Restore agent from export-agent archive
#   onboard <id>         Run OpenClaw onboarding (interactive)
#   upgrade-plugins [id|all]  Refresh IdentyClaw plugins from ClawHub
#   sync-a2a-peers [id|all]  Backfill env.local from discovered inbound peers
#   discover-a2a-peers [id|all]  Discover live peers via GET /api/agents
#   token <id>           Print Control UI gateway token
#   chat <id>            OpenClaw TUI against running gateway
#   ask <id> "message"   One-shot agent message

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

require_podman() {
  command -v podman >/dev/null 2>&1 || {
    echo "podman not found. Install podman first." >&2
    exit 1
  }
}

require_rootless_user() {
  if [[ "${IDENTYCLAW_ROOTLESS:-1}" == "1" && "$(id -u)" -eq 0 ]]; then
    echo "Run rootless mode as your normal user, not root." >&2
    echo "For rootful: sudo IDENTITYCLAW_ROOTLESS=0 $0 $*" >&2
    exit 1
  fi
}

cmd_build_image() {
  require_podman
  load_env
  local arch
  arch="$(detect_himalaya_arch)"
  echo "==> Pulling ${OPENCLAW_BASE_IMAGE}"
  podman pull "$OPENCLAW_BASE_IMAGE"
  local bundled_plugins
  bundled_plugins="$(resolve_openclaw_bundled_plugins)"
  echo "==> Building ${OPENCLAW_LOCAL_IMAGE} (gateway ${OPENCLAW_GATEWAY_VERSION}, himalaya ${HIMALAYA_VERSION}, arch ${arch})"
  podman build -f "$ROOT/Containerfile.himalaya" -t "$OPENCLAW_LOCAL_IMAGE" "$ROOT" \
    --build-arg "OPENCLAW_BASE_IMAGE=${OPENCLAW_BASE_IMAGE}" \
    --build-arg "OPENCLAW_GATEWAY_VERSION=${OPENCLAW_GATEWAY_VERSION}" \
    --build-arg "OPENCLAW_BUNDLED_PLUGINS=${bundled_plugins}" \
    --build-arg "HIMALAYA_VERSION=${HIMALAYA_VERSION}" \
    --build-arg "HIMALAYA_ARCH=${arch}"
  podman images "$OPENCLAW_LOCAL_IMAGE"
}

init_one_agent() {
  local id="$1"
  local email="$2"
  local display_name="$3"
  local password="$4"
  local gateway_port="$5"
  local dir
  dir="$(agent_home "$id")"

  echo "==> Initializing ${id} at ${dir}"
  mkdir -p "$dir/workspace" "$dir/canvas" "$dir/cron"
  chmod 700 "$dir" "$dir/workspace"

  write_himalaya_config "$email" "$display_name" "$dir"
  write_himalaya_send_script "$email" "$display_name" "$dir"
  write_agent_email_doc "$email" "$display_name" "$dir"
  write_openclaw_json "$dir" "$gateway_port"
  ensure_agent_env "$dir"

  if [[ -n "$password" ]]; then
    write_secret_helpers "$dir" "$password"
  elif [[ -f "$dir/secrets/imap.pass" ]]; then
    echo "    (keeping existing secrets)"
  else
    echo "    (no password yet — run: $0 set-password ${id})"
  fi
}

cmd_init() {
  require_rootless_user
  ensure_app_layout
  load_env
  local id
  for id in $AGENT_IDS; do
    if ! is_valid_agent_id "$id"; then
      echo "Invalid agent id in AGENT_IDS: ${id} (expected agent-{slug}, e.g. agent-name-not-set)" >&2
      if [[ "$id" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "Did you mean agent-${id}? Update AGENT_IDS and rename AGENT_* env prefix to match." >&2
      fi
      exit 1
    fi
    init_one_agent "$id" "$(agent_email "$id")" "$(agent_display_name "$id")" "$(agent_env_value "$id" PASSWORD "")" "$(agent_env_value "$id" GATEWAY_PORT "")"
  done
  echo ""
  echo "Next:"
  echo "  1. Edit $(identyclaw_env_file) — NEAR RPC URL (and optional env overrides)"
  echo "  2. Add agents/<id>/secrets/near-credentials/*.json + set Passport metadata.webhook_url"
  echo "  3. $0 set-api-key ${AGENT_IDS%% *}"
  echo "  4. $0 build-image"
  echo "  5. $0 generate-certs   # or install CA PEMs in app/certs/"
  echo "  6. ./scripts/deploy-local-podman.sh   # or $0 start all for standalone"
  echo "  7. $0 test"
}

cmd_set_password() {
  local id="${1:?Usage: $0 set-password agent-b}"
  require_agent_id_arg "$id" "$0 set-password <agent-id>"
  local dir
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  local pw
  read -r -s -p "Migadu password for ${id}: " pw
  echo
  [[ -n "$pw" ]] || { echo "empty password" >&2; exit 1; }
  write_secret_helpers "$dir" "$pw"
  echo "Password stored in ${dir}/secrets/ (mode 600)"
}

cmd_set_discord_token() {
  local id="${1:?Usage: $0 set-discord-token agent-b}"
  require_agent_id_arg "$id" "$0 set-discord-token <agent-id>"
  local dir
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  local token
  read -r -s -p "Discord bot token for ${id}: " token
  echo
  write_discord_token "$dir" "$token"
  echo "Discord token stored in ${dir}/secrets/DISCORD_BOT_TOKEN (mode 600)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_set_instagram() {
  local id="${1:?Usage: $0 set-instagram agent-b}"
  local dir username password
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  read -r -p "Instagram username for ${id}: " username
  read -r -s -p "Instagram password for ${id}: " password
  echo
  write_instagram_secrets "$dir" "$username" "$password"
  echo "Instagram credentials stored in ${dir}/secrets/instagram.* (mode 600)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_set_twitter() {
  local id="${1:?Usage: $0 set-twitter agent-b [username]}"
  local dir username password
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  if [[ -n "${2:-}" ]]; then
    username="$2"
    read -r -s -p "Twitter/X password for ${id}: " password
    echo
  else
    read -r -p "Twitter/X login (email or username) for ${id}: " username
    read -r -s -p "Twitter/X password for ${id}: " password
    echo
  fi
  write_twitter_secrets "$id" "$dir" "$username" "$password"
  echo "Twitter credentials stored; hourly heartbeat polling enabled (HEARTBEAT.md + agents.defaults.heartbeat.every=1h)"
  echo "For posting, set session cookies: $0 set-twitter-cookies ${id}"
  echo "Restart to apply env: $0 restart ${id}"
}

cmd_set_twitter_cookies() {
  local id="${1:?Usage: $0 set-twitter-cookies agent-b}"
  local dir auth_token ct0
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  read -r -s -p "Twitter auth_token cookie for ${id}: " auth_token
  echo
  read -r -s -p "Twitter ct0 cookie for ${id}: " ct0
  echo
  [[ -n "$auth_token" && -n "$ct0" ]] || { echo "empty cookie values" >&2; exit 1; }
  write_twitter_bird_cookies "$id" "$dir" "$auth_token" "$ct0"
  ensure_twitter_clawhub_skill "$id" "$dir"
  echo "Twitter session cookies stored; bird-twitter skill enabled for ${id}"
  echo "Restart to apply env: $0 restart ${id}"
}

start_one() {
  local id="$1"
  load_env

  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    case " $AGENT_IDS " in
      *" ${id} "*) ;;
      *)
        echo "${id} is not provisioned on this host (AGENT_IDS=${AGENT_IDS})." >&2
        echo "First deploy: ./scripts/deploy-local-podman.sh" >&2
        return 1
        ;;
    esac
    start_pod_agent "$id" start || return 1
    echo "Full pod redeploy: ./scripts/deploy-local-podman.sh --skip-build"
    return 0
  fi

  local dir container gw br z rt tls_env=()
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  z="$(selinux_mount_suffix)"
  rt="$(podman_runtime_args)"
  if a2a_tls_skip_verify_enabled; then
    tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  fi

  [[ -f "$dir/.env" ]] || { echo "Missing ${dir}/.env — run $0 init" >&2; exit 1; }
  [[ -f "$dir/openclaw.json" ]] || { echo "Missing config — run $0 init" >&2; exit 1; }

  read -r gw br < <(agent_ports "$id")
  ensure_internal_gateway_port "$dir" "$gw"
  ensure_identyclaw_network
  ensure_agent_bootstrap "$id" "$dir"
  sync_discord_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"

  podman rm -f "$container" 2>/dev/null || true
  prepare_agent_state_for_gateway_start "$id" standalone

  local network_args=()
  if podman network exists "$IDENTYCLAW_NETWORK" 2>/dev/null; then
    network_args=(--network "$IDENTYCLAW_NETWORK")
  fi

  # shellcheck disable=SC2086
  podman run -d --replace \
    --name "$container" \
    --init \
    --shm-size=2g \
    --restart always \
    "${network_args[@]}" \
    $rt \
    -e HOME=/home/node \
    -e OPENCLAW_NO_RESPAWN=1 \
    "${tls_env[@]}" \
    --env-file "$dir/.env" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    -p "${PUBLISH_HOST}:${gw}:18789" \
    -p "${PUBLISH_HOST}:${br}:18790" \
    "$OPENCLAW_LOCAL_IMAGE" \
    node dist/index.js gateway --bind lan --port 18789

  sync_agent_openclaw_json_when_container_running "$id"
  ensure_openclaw_cli_link "$container"
  ensure_agent_packages "$id"
  ensure_discord_plugin_compat_and_restart "$id"
  echo "Started ${container} → http://${PUBLISH_HOST}:${gw}/"
}

cmd_start() {
  require_podman
  require_rootless_user
  load_env
  ensure_agent_persistence
  local target="${1:-all}"
  if [[ "$target" == "all" ]]; then
    local id
    for id in $AGENT_IDS; do
      start_one "$id"
    done
  elif is_valid_agent_id "$target"; then
    start_one "$target"
  else
    echo "Usage: $0 start [agent-id|all]" >&2
    exit 1
  fi
}

stop_one() {
  local id="$1"
  podman stop "$(agent_container "$id")" 2>/dev/null || true
  echo "Stopped $(agent_container "$id")"
}

cmd_stop() {
  require_podman
  load_env
  local target="${1:-all}"
  if [[ "$target" == "all" ]]; then
    local id
    for id in $AGENT_IDS; do
      stop_one "$id"
    done
  elif is_valid_agent_id "$target"; then
    stop_one "$target"
  else
    echo "Usage: $0 stop [agent-id|all]" >&2
    exit 1
  fi
}

cmd_restore_host_access() {
  require_podman
  load_env
  local target="${1:-all}"
  if [[ "$target" == "all" ]]; then
    restore_host_access_for_agents "$AGENT_IDS"
  elif is_valid_agent_id "$target"; then
    restore_host_access_for_agents "$target"
  else
    echo "Usage: $0 restore-host-access [agent-id|all]" >&2
    exit 1
  fi
}

cmd_restart() {
  require_podman
  load_env
  local target="${1:-all}"
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    if [[ "$target" == "all" ]]; then
      local id
      for id in $AGENT_IDS; do
        start_pod_agent "$id" restart
      done
    elif is_valid_agent_id "$target"; then
      start_pod_agent "$target" restart
    else
      echo "Usage: $0 restart [agent-id|all]" >&2
      exit 1
    fi
    return 0
  fi
  cmd_stop "$target"
  cmd_start "$target"
}

cmd_enable_boot() {
  require_podman
  require_rootless_user
  local user linger
  user="$(whoami)"
  linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"

  echo "==> Boot persistence for identyclaw (rootless Podman)"
  if [[ "$linger" != "yes" ]]; then
    echo "    Enabling linger for ${user} (needs sudo)..."
    sudo loginctl enable-linger "$user"
  else
    echo "    Linger already enabled for ${user}"
  fi

  echo "==> Enabling podman-restart.service (starts --restart always containers on boot)"
  systemctl --user enable --now podman-restart.service

  echo "==> Recreating agents with --restart always"
  cmd_restart all

  echo ""
  echo "Verify:"
  loginctl show-user "$user" | grep Linger || true
  systemctl --user is-enabled podman-restart.service || true
  local inspect_names=()
  for id in $AGENT_IDS; do
    inspect_names+=("openclaw-${id}")
  done
  podman inspect "${inspect_names[@]}" \
    --format '{{.Name}}  policy={{.HostConfig.RestartPolicy.Name}}  state={{.State.Status}}' 2>/dev/null || true
  echo ""
  ./identyclaw.sh status
  echo ""
  echo "After a reboot, all agents should be Up without running start manually."
  echo "To stop until next reboot: ./identyclaw.sh stop all"
}

cmd_status() {
  require_podman
  load_env
  podman ps -a --filter 'name=openclaw-agent-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  echo ""
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    local first_id ingress_port
    first_id="${AGENT_IDS%% *}"
    ingress_port="$(agent_ingress_port "${first_id}")"
    echo "Main-tier ingress (A2A + webhooks — port ${ingress_port}):"
    for id in $AGENT_IDS; do
      print_agent_ingress_urls "$id"
    done
    echo ""
    echo "Control UI (operator; gateway token required):"
    for id in $AGENT_IDS; do
      local base
      base="$(agent_ingress_base_url "$id")"
      [[ -n "$base" ]] && echo "  ${id}: ${base}/"
    done
  else
    echo "Control UI (use token from: $0 token <id>):"
    for id in $AGENT_IDS; do
      read -r gw _ < <(agent_ports "$id")
      echo "  ${id}: http://${PUBLISH_HOST}:${gw}/"
    done
    echo ""
    echo "Webhooks / A2A (loopback — tunnel or pod deploy for HTTPS):"
    for id in $AGENT_IDS; do
      print_agent_ingress_urls "$id"
    done
  fi
}

cmd_logs() {
  local id="${1:?Usage: $0 logs agent-b}"
  podman logs -f "$(agent_container "$id")"
}

cmd_test_mail() {
  local id="${1:-}"
  load_env
  id="${id:-$(resolve_local_agent_id)}"
  require_podman
  require_agent_running "$id"
  podman exec "$(agent_container "$id")" himalaya --version
  podman exec "$(agent_container "$id")" himalaya folder list
  podman exec "$(agent_container "$id")" himalaya envelope list --folder INBOX
}

# Run the inbound HOLA email responder once for a single agent (cron/timer entry point).
respond_mail_one() {
  local id="$1"
  local container creds ext_dir mailbox email display_name
  container="$(agent_container "$id")"
  if ! podman ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "    (${id}: container not running — skip mail responder)" >&2
    return 0
  fi
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "    (${id}: no NEAR credentials — cannot verify HOLA, skip)" >&2
    return 0
  }
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  [[ -n "$email" ]] || {
    echo "    (${id}: no AGENT_*_EMAIL — skip mail responder)" >&2
    return 0
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_mail_responder_libs "$container" || {
    echo "    (${id}: failed to copy responder libs)" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/respond-agent-mail.mjs" "$container:/tmp/respond-agent-mail.mjs" >/dev/null
  local -a args=(
    --ext-dir "$ext_dir"
    --creds "$creds"
    --from-email "$email"
    --from-name "$display_name"
  )
  local api_base
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] && args+=(--api-base "$api_base")
  [[ "${MAIL_RESPONDER_DRY_RUN:-0}" == 1 ]] && args+=(--dry-run)
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
    node /tmp/respond-agent-mail.mjs "${args[@]}"
}

cmd_respond_mail() {
  local target="${1:-}"
  load_env
  require_podman
  if [[ -z "$target" || "$target" == "all" ]]; then
    local rc=0
    for id in $AGENT_IDS; do
      echo "==> Mail responder: ${id}"
      respond_mail_one "$id" || rc=1
    done
    return "$rc"
  fi
  is_valid_agent_id "$target" || { echo "Invalid agent id: ${target}" >&2; return 1; }
  echo "==> Mail responder: ${target}"
  respond_mail_one "$target"
}

# Install a user systemd timer that runs `respond-mail` on an interval (cron-style).
cmd_enable_mail_responder() {
  require_rootless_user
  local interval="${1:-2min}"
  local unit_dir="${HOME}/.config/systemd/user"
  local script_path="${ROOT}/identyclaw.sh"
  mkdir -p "$unit_dir"
  cat >"${unit_dir}/identyclaw-mail-responder.service" <<EOF
[Unit]
Description=IdentyClaw inbound HOLA email responder (poll INBOX, verify, reply)
After=podman-restart.service

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/env bash ${script_path} respond-mail all
EOF
  cat >"${unit_dir}/identyclaw-mail-responder.timer" <<EOF
[Unit]
Description=Run IdentyClaw mail responder every ${interval}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now identyclaw-mail-responder.timer
  echo "==> Mail responder timer enabled (every ${interval})."
  echo "    Status:  systemctl --user status identyclaw-mail-responder.timer"
  echo "    Logs:    journalctl --user -u identyclaw-mail-responder.service -f"
  echo "    Disable: systemctl --user disable --now identyclaw-mail-responder.timer"
}

cmd_generate_certs() {
  local force=""
  for arg in "$@"; do
    case "$arg" in
      --force) force="--force" ;;
      -h|--help)
        echo "Usage: $0 generate-certs [--force]"
        echo "Writes fullchain.pem + privkey.pem under \$(identyclaw_app_dir)/certs/"
        echo "SANs: AGENT_*_PUBLIC_HOST from env.local (defaults in env.example)."
        exit 0
        ;;
      *)
        echo "Unknown option: $arg (try --force)" >&2
        exit 1
        ;;
    esac
  done
  ensure_tls_certs "$force"
  echo "TLS material ready in $(identyclaw_app_dir)/certs/"
}

a2a_fetch_agent_card() {
  local runner_id="$1" target_id="$2"
  local url container resolve=() curl_flags=(-sk)
  url="$(agent_agent_card_url "$target_id")"
  if agent_is_local "$runner_id" && agent_container_running "$runner_id"; then
    container="$(agent_container "$runner_id")"
    if agent_is_local "$target_id"; then
      mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
    fi
    podman exec "$container" curl "${curl_flags[@]}" "${resolve[@]}" "$url"
    return 0
  fi
  mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
  curl -sk "${resolve[@]}" "$url"
}

a2a_fetch_peer_agent_card() {
  local runner_id="$1" peer_token_id="$2"
  local url container curl_flags=(-sk) resolver_dir
  resolver_dir="$(agent_home "$runner_id")"
  url="$(a2a_peer_agent_card_url "$peer_token_id" "$resolver_dir")"
  [[ -n "$url" ]] || {
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "No agent card URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed (check IDENTYCLAW_BASE_URL, NEAR creds, passport)" >&2
    else
      echo "No agent card URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
    fi
    return 1
  }
  if agent_container_running "$runner_id"; then
    container="$(agent_container "$runner_id")"
    podman exec "$container" curl "${curl_flags[@]}" "$url"
    return $?
  fi
  curl -sk "$url"
}

a2a_probe_unauth_post_url() {
  local label="$1" a2a_url="$2"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$a2a_url" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"tasks/get","params":{"id":"smoke"}}')"
  if [[ "$code" != "401" ]]; then
    echo "not-passed  POST /a2a without Authorization on ${label} — HTTP ${code} (stack requires 401) (${a2a_url})" >&2
    return 1
  fi
  echo "passed  POST /a2a without Authorization on ${label} — HTTP 401"
}

a2a_probe_unauth_post() {
  local id="$1"
  local code a2a_url resolve=()
  a2a_url="$(agent_a2a_endpoint_url "$id")"
  mapfile -t resolve < <(agent_ingress_curl_resolve_args "$id")
  code="$(curl -sk "${resolve[@]}" -o /dev/null -w '%{http_code}' -X POST "$a2a_url" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"tasks/get","params":{"id":"smoke"}}')"
  if [[ "$code" != "401" ]]; then
    echo "not-passed  POST /a2a without Authorization on ${id} — HTTP ${code} (stack requires 401) (${a2a_url})" >&2
    return 1
  fi
  echo "passed  POST /a2a without Authorization on ${id} — HTTP 401"
}

cmd_test_a2a() {
  local from_id self_token_id
  require_podman
  load_env
  from_id="${1:-$(resolve_local_agent_id)}"
  require_agent_running "$from_id"
  self_token_id="$(agent_token_id "$from_id")"

  echo "==> A2A smoke (local=${from_id}, self token_id=${self_token_id:-unknown})"
  echo "==> Discovery: local ${from_id}"
  a2a_fetch_agent_card "$from_id" "$from_id"
  echo ""
  echo "==> Inbound auth probe: POST /a2a without Authorization"
  a2a_probe_unauth_post "$from_id"
  echo ""
  echo "A2A smoke: passed (local discovery + inbound auth probe)."
}

cmd_test_a2a_auth() {
  local local_id target container creds ext_dir failed=0
  require_podman
  load_env
  local_id="${1:-$(resolve_local_agent_id)}"
  require_agent_running "$local_id"

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id} (secrets/near-credentials/*.json)" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || return 1
  podman_cp_lib_test_report "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-a2a-rodit-auth.mjs" "$container:/tmp/test-a2a-rodit-auth.mjs" >/dev/null

  target="$(agent_a2a_public_base_url "$local_id")"
  [[ -n "$target" ]] || target="$(agent_ingress_base_url "$local_id")"
  [[ -n "$target" ]] || {
    echo "No ingress URL for local ${local_id}" >&2
    return 1
  }
  echo "==> A2A RODiT auth (local ${local_id} at ${target})"
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-rodit-auth.mjs     --ext-dir "$ext_dir" --creds "$creds" --target "$target" || failed=1
  return "$failed"
}

cmd_webhook_url() {
  local id="${1:?Usage: $0 webhook-url agent-b [hooks/wake|hooks/agent|hooks/name]}"
  local path="${2:-hooks/wake}"
  agent_webhook_url "$id" "$path"
}

cmd_test_webhook() {
  local id="${1:-}" failed=0
  load_env
  id="${id:-$(resolve_local_agent_id)}"
  local url code creds container
  url="$(agent_webhook_url "$id" hooks/wake)"
  container="$(agent_container "$id")"

  echo "==> Webhook ingress probe: POST /hooks/wake without RODiT signature"
  echo "    POST ${url}"
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$url"     -H 'Content-Type: application/json'     -d '{"text":"identyclaw smoke"}')"
  case "$code" in
    400|401) echo "passed  POST /hooks/wake without RODiT signature — HTTP ${code}" ;;
    404)
      echo "not-passed  POST /hooks/wake without RODiT signature — HTTP 404 (route not exposed)" >&2
      return 1
      ;;
    *)
      echo "not-passed  POST /hooks/wake without RODiT signature — HTTP ${code} (expected 400 or 401)" >&2
      return 1
      ;;
  esac

  if [[ "${SKIP_TESTHOLA:-0}" == 1 ]]; then
    echo ""
    echo "==> Skip /api/testhola webhook delivery (SKIP_TESTHOLA=1)"
    return 0
  fi

  creds="$(agent_near_credentials_for_tests "$id")"
  if ! _agent_container_name_running "$container"; then
    [[ -n "$creds" ]] || {
      echo "skipped: agent not running and no near-credentials — skipping testhola" >&2
      return 1
    }
  fi

  echo ""
  echo "==> /api/testhola webhook delivery (IdentyClaw API → agent webhook_url)"
  local api_base_args=() api_base
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] && api_base_args=(--api-base "$api_base")
  if _agent_container_name_running "$container"; then
    local container_creds ext_dir
    container_creds="$(agent_near_credentials_for_tests "$id")"
    [[ -n "$container_creds" ]] || container_creds="$creds"
    ext_dir="$(agent_a2a_ext_dir_container)"
    podman_cp_lib_rodit_env "$container" || return 1
    podman_cp_lib_test_report "$container" || return 1
    podman cp "${IDENTYCLAW_ROOT}/scripts/test-webhooks-testhola.mjs" "$container:/tmp/test-webhooks-testhola.mjs" >/dev/null
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-webhooks-testhola.mjs       --ext-dir "$ext_dir"       --creds "$container_creds"       --agent-base "$(agent_container_ingress_base_url "$id")"       "${api_base_args[@]}" || failed=1
  elif [[ -n "$creds" ]]; then
    NODE_TLS_REJECT_UNAUTHORIZED=0 node "${IDENTYCLAW_ROOT}/scripts/test-webhooks-testhola.mjs"       --ext-dir "$(agent_a2a_ext_dir "$(agent_home "$id")")"       --creds "$creds"       --agent-base "$(agent_ingress_base_url "$id")"       "${api_base_args[@]}" || failed=1
  fi
  return "$failed"
}

cmd_send_rodit_webhook() {
  local id="${1:?Usage: $0 send-rodit-webhook agent-name-not-set <peer-token-id> [message]}"
  local peer_token_id="${2:?Usage: $0 send-rodit-webhook agent-name-not-set <peer-token-id> [message]}"
  local text="${3:-}"
  local delay="${SEND_RODIT_WEBHOOK_DELAY:-10}"
  require_podman
  load_env
  is_passport_token_id "$peer_token_id" || {
    echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
    exit 1
  }
  require_agent_running "$id"

  local container creds ext_dir
  container="$(agent_container "$id")"
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials in ${id} container" >&2
    exit 1
  }

  podman cp "${IDENTYCLAW_ROOT}/scripts/send-rodit-webhook.mjs" "$container:/tmp/send-rodit-webhook.mjs" >/dev/null
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/send-rodit-webhook.mjs \
    --peer "$peer_token_id" \
    --delay "$delay" \
    --creds "$creds" \
    ${text:+--text "$text"}
}

cmd_test_peer_gateway() {
  echo "==> Peer gateway resolution (unit)"
  node "${IDENTYCLAW_ROOT}/scripts/test-peer-gateway-resolution.mjs"
}

cmd_test() {
  local local_id="${1:-}" failed=0 mail_skipped=0
  load_env
  if [[ -n "$local_id" ]] && ! is_valid_agent_id "$local_id"; then
    echo "Usage: $0 test [agent-id]" >&2
    return 1
  fi
  local_id="${local_id:-$(resolve_local_agent_id)}"
  require_podman
  require_agent_running "$local_id"

  echo "==> Smoke test (local=${local_id})"
  echo ""

  cmd_test_peer_gateway || failed=1
  echo ""
  cmd_test_a2a "$local_id" || failed=1
  echo ""
  cmd_test_a2a_auth "$local_id" || failed=1
  echo ""
  cmd_test_webhook "$local_id" || failed=1
  echo ""
  if [[ -f "$(agent_home "$local_id")/secrets/imap.pass" ]] || agent_container_running "$local_id"; then
    cmd_test_mail "$local_id" || failed=1
  else
    echo "==> Skip test-mail (no Migadu password — run: $0 set-password ${local_id})"
    mail_skipped=1
  fi

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "Smoke test: passed${mail_skipped:+ (mail skipped)}"
  else
    echo "Smoke test: not-passed (see output above)" >&2
  fi
  return "$failed"
}

cmd_token() {
  local id="${1:?Usage: $0 token agent-b}"
  agent_gateway_token "$id"
}

require_agent_running() {
  local id="$1"
  local container attempt=0 max_attempts=5
  load_env
  container="$(agent_container "$id")"
  while (( attempt < max_attempts )); do
    if podman ps --format '{{.Names}}' | grep -qx "$container"; then
      ensure_agent_state_for_container_exec "$id"
      ensure_openclaw_cli_link "$container"
      return 0
    fi
    if podman container inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
      ensure_agent_state_for_container_exec "$id"
      ensure_openclaw_cli_link "$container"
      return 0
    fi
    attempt=$((attempt + 1))
    [[ $attempt -lt $max_attempts ]] && sleep 1
  done
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    cat >&2 <<EOF
${container} is not running.

  ./identyclaw.sh restart ${id}
  podman start ${container}
  ./scripts/deploy-local-podman.sh   # full pod redeploy

EOF
  else
    echo "Start ${container} first: $0 start ${id}" >&2
  fi
  exit 1
}

cmd_chat() {
  local id="${1:?Usage: $0 chat agent-b}"
  shift
  require_podman
  require_agent_running "$id"
  load_env
  local display ui_base container gw_port token
  display="$(agent_display_name "$id")"
  ui_base="$(agent_ui_base_url "$id")"
  container="$(agent_container "$id")"
  gw_port="$(agent_internal_gateway_port "$id")"
  token="$(agent_gateway_token "$id")"
  [[ -n "$token" ]] || { echo "Missing OPENCLAW_GATEWAY_TOKEN for ${id}" >&2; exit 1; }
  printf '\033]0;%s (%s) — identyclaw chat\007' "$display" "$id"
  echo "=== ${display} · ${id} · ${ui_base}/ · session main ==="
  echo ""
  # Connect to the running gateway (not tui --local) — same session as Control UI, no second runtime.
  podman exec -it \
    -e LOG_LEVEL=error \
    -e SUPPRESS_NO_CONFIG_WARNING=true \
    -e SUPPRESS_STRICTNESS_CHECK=true \
    "$container" node dist/index.js tui \
    --url "ws://127.0.0.1:${gw_port}" \
    --token "$token" \
    --session main \
    "$@"
}

cmd_ask() {
  local id="${1:?Usage: $0 ask agent-b \"message\"}"
  local message="${2:?Usage: $0 ask agent-b \"message\"}"
  local container tls_env=()
  require_podman
  require_agent_running "$id"
  load_env
  container="$(agent_container "$id")"
  if a2a_tls_skip_verify_enabled; then
    tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  fi
  podman exec \
    -e LOG_LEVEL=error \
    -e SUPPRESS_NO_CONFIG_WARNING=true \
    -e SUPPRESS_STRICTNESS_CHECK=true \
    "${tls_env[@]}" \
    "$container" node dist/index.js agent \
    --agent main -m "$message"
}

cmd_set_api_key() {
  local id="${1:?Usage: $0 set-api-key agent-b [sk-or-...]}"
  local key="${2:-${OPENROUTER_API_KEY:-}}"
  local dir
  require_agent_id_arg "$id" "$0 set-api-key <agent-id> [sk-or-...]"
  dir="$(agent_home "$id")"
  if ! [[ -d "$dir" ]] && ! agent_container_running "$id"; then
    echo "Run $0 init first (missing ${dir})" >&2
    exit 1
  fi
  if [[ -z "$key" ]]; then
    read -r -s -p "OpenRouter API key for ${id} (sk-or-...): " key
    echo
  fi
  [[ -n "$key" ]] || { echo "empty key" >&2; exit 1; }
  write_openrouter_api_key "$id" "$key"
  echo "API key stored for ${id} (auth-profiles.json)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_set_opencode_key() {
  local id="${1:?Usage: $0 set-opencode-key agent-b [sk-...]}"
  local key="${2:-${OPENCODE_API_KEY:-}}"
  local dir
  require_agent_id_arg "$id" "$0 set-opencode-key <agent-id> [sk-...]"
  dir="$(agent_home "$id")"
  if ! [[ -d "$dir" ]] && ! agent_container_running "$id"; then
    echo "Run $0 init first (missing ${dir})" >&2
    exit 1
  fi
  if [[ -z "$key" ]]; then
    read -r -s -p "OpenCode API key for ${id} (sk-... from opencode.ai/auth): " key
    echo
  fi
  [[ -n "$key" ]] || { echo "empty key" >&2; exit 1; }
  write_opencode_api_key "$id" "$key"
  echo "API key stored for ${id} (opencode + opencode-go auth-profiles.json)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_mirror() {
  local to_id="${1:?Usage: $0 mirror agent-name-not-set [agent-name-not-set]}"
  local from_id="${2:-$(resolve_local_agent_id)}"
  require_rootless_user
  load_env
  mirror_agent_config "$from_id" "$to_id"
  echo "Restart to apply: $0 restart ${to_id}"
}

cmd_export_agent() {
  local id="${1:?Usage: $0 export-agent agent-b [archive.tar.gz] [--with-browser] [--no-stop]}"
  shift || true
  require_rootless_user
  load_env
  local output="" with_browser=0 stop_first=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-browser) with_browser=1 ;;
      --no-stop) stop_first=0 ;;
      -*) echo "Unknown option: $1" >&2; exit 1 ;;
      *)
        if [[ -z "$output" ]]; then
          output="$1"
        else
          echo "Unexpected argument: $1" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done
  export_agent_bundle "$id" "$output" "$with_browser" "$stop_first"
}

cmd_import_agent() {
  local id="${1:?Usage: $0 import-agent agent-b archive.tar.gz}"
  local archive="${2:?Usage: $0 import-agent agent-b archive.tar.gz}"
  require_rootless_user
  load_env
  import_agent_bundle "$id" "$archive"
}

cmd_configure() {
  local id="${1:?Usage: $0 configure agent-b [openclaw configure flags...]}"
  shift
  require_podman
  local container
  container="$(agent_container "$id")"
  require_agent_running "$id"
  podman exec -it "$container" node dist/index.js configure "$@"
}

cmd_upgrade_plugins() {
  require_podman
  require_rootless_user
  load_env
  local target="${1:-all}"
  local id
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      upgrade_agent_plugins "$id"
    done
    echo ""
    echo "Restart gateways to load plugins: $0 restart all"
  else
    upgrade_agent_plugins "$target"
    echo ""
    echo "Restart gateway to load plugins: $0 restart ${target}"
  fi
}

cmd_sync_a2a_peers() {
  require_podman
  require_rootless_user
  load_env
  local target="${1:-all}" id synced=0
  echo "==> Sync A2A peers from inbound P2P login logs"
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      if sync_a2a_peers_from_logs "$id"; then
        synced=1
        ensure_a2a_config "$id" "$(agent_home "$id")" "$(agent_container "$id")" || true
      fi
    done
  else
    sync_a2a_peers_from_logs "$target" || exit 1
    synced=1
    ensure_a2a_config "$target" "$(agent_home "$target")" "$(agent_container "$target")" || true
  fi
  if [[ "$synced" -eq 0 ]]; then
    echo "No peers harvested — wait for a peer P2P login (/api/login or authenticated /a2a), then retry." >&2
    echo "Requires IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1 or IDENTYCLAW_A2A_OPEN_P2P=1." >&2
    exit 1
  fi
  echo ""
  echo "Updated $(identyclaw_env_file) — restart to apply: $0 restart ${target}"
}

cmd_discover_a2a_peers() {
  require_podman
  require_rootless_user
  load_env
  local target="${1:-all}" id peers_json count
  echo "==> Discover live A2A peers via IdentyClaw API (GET /api/agents)"
  if ! a2a_discover_peers_from_api_enabled; then
    echo "API discovery is off — set IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1 in env.local" >&2
    exit 1
  fi
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      echo ""
      echo "--- ${id} ---"
      peers_json="$(discover_live_api_peers_json_for_agent "$id")"
      count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1] or '{}')))" "$peers_json")"
      echo "    live peers discovered: ${count}"
      ensure_a2a_config "$id" "$(agent_home "$id")" "$(agent_container "$id")" || true
    done
  else
    is_valid_agent_id "$target" || {
      echo "Usage: $0 discover-a2a-peers [agent-id|all]" >&2
      exit 1
    }
    peers_json="$(discover_live_api_peers_json_for_agent "$target")"
    count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1] or '{}')))" "$peers_json")"
    echo "    live peers discovered: ${count}"
    ensure_a2a_config "$target" "$(agent_home "$target")" "$(agent_container "$target")" || true
  fi
  echo ""
  echo "Updated openclaw.json outbound.agents — restart to load: $0 restart ${target}"
}

cmd_onboard() {
  local id="${1:?Usage: $0 onboard agent-b}"
  shift
  require_podman
  require_rootless_user
  load_env
  local dir container gw z rt token_file
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")-onboard"
  read -r gw _ < <(agent_ports "$id")
  z="$(selinux_mount_suffix)"
  rt="$(podman_runtime_args)"
  token_file="$(mktemp)"
  grep '^OPENCLAW_GATEWAY_TOKEN=' "$dir/.env" >"$token_file"
  chmod 600 "$token_file"

  echo "Tips:"
  if [[ "$(openclaw_llm_provider)" == opencode ]]; then
    echo "  - OpenCode auth: choose API key in the wizard, or: $0 set-opencode-key ${id} sk-..."
    echo "  - Or onboard non-interactive: $0 onboard ${id} --auth-choice opencode-zen --opencode-zen-api-key \"\$OPENCODE_API_KEY\""
  else
    echo "  - OpenRouter auth: choose API key. Key must start with sk-or-"
    echo "  - Or set the key first: $0 set-api-key ${id}"
  fi
  echo "  - Skipping hatch TUI / health checks (identyclaw uses Podman gateways)."
  echo "  - At end, use Control UI — not 'Hatch in Terminal'."
  echo ""

  podman rm -f "$container" 2>/dev/null || true
  # No -p publish: gateways already bind gw on the host; onboard is CLI-only.
  # shellcheck disable=SC2086
  podman run --rm -it \
    --name "$container" \
    --init \
    $rt \
    -e HOME=/home/node \
    -e OPENCLAW_NO_RESPAWN=1 \
    --env-file "$token_file" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    "$OPENCLAW_LOCAL_IMAGE" \
    node dist/index.js onboard \
      --skip-health --no-install-daemon --skip-ui \
      "$@"
  rm -f "$token_file"
  echo ""
  echo "Onboarding finished."
  if [[ "$(openclaw_llm_provider)" == opencode ]]; then
    echo "  1. $0 set-opencode-key ${id}   # if you did not set OpenCode API key in the wizard"
  else
    echo "  1. $0 set-api-key ${id}   # if you did not set OpenRouter API key in the wizard"
  fi
  echo "  2. $0 restart ${id}"
  echo "  3. Control UI: http://${PUBLISH_HOST}:${gw}/"
  echo "     token: $0 token ${id}"
}

main() {
  local cmd="${1:-}"
  shift || true
  if ! identyclaw_skips_host_restore "$cmd"; then
    restore_pod_agent_state_for_host
  fi
  case "$cmd" in
    build-image) cmd_build_image "$@" ;;
    init) cmd_init "$@" ;;
    set-password) cmd_set_password "$@" ;;
    set-discord-token) cmd_set_discord_token "$@" ;;
    set-instagram) cmd_set_instagram "$@" ;;
    set-twitter) cmd_set_twitter "$@" ;;
    set-twitter-cookies) cmd_set_twitter_cookies "$@" ;;
    set-api-key) cmd_set_api_key "$@" ;;
    set-opencode-key) cmd_set_opencode_key "$@" ;;
    mirror) cmd_mirror "$@" ;;
    export-agent) cmd_export_agent "$@" ;;
    import-agent) cmd_import_agent "$@" ;;
    configure) cmd_configure "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    restore-host-access) cmd_restore_host_access "$@" ;;
    enable-boot) cmd_enable_boot "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    test) cmd_test "$@" ;;
    test-peer-gateway) cmd_test_peer_gateway "$@" ;;
    test-mail) cmd_test_mail "$@" ;;
    respond-mail) cmd_respond_mail "$@" ;;
    enable-mail-responder) cmd_enable_mail_responder "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    test-a2a) cmd_test_a2a "$@" ;;
    test-a2a-auth) cmd_test_a2a_auth "$@" ;;
    test-webhook) cmd_test_webhook "$@" ;;
    send-rodit-webhook) cmd_send_rodit_webhook "$@" ;;
    webhook-url) cmd_webhook_url "$@" ;;
    token) cmd_token "$@" ;;
    chat) cmd_chat "$@" ;;
    ask) cmd_ask "$@" ;;
    onboard) cmd_onboard "$@" ;;
    upgrade-plugins) cmd_upgrade_plugins "$@" ;;
    sync-a2a-peers) cmd_sync_a2a_peers "$@" ;;
    discover-a2a-peers) cmd_discover_a2a_peers "$@" ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
