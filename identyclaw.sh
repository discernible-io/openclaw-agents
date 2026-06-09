#!/usr/bin/env bash
# Identyclaw: three isolated OpenClaw gateways (Podman) + Himalaya (Migadu).
#
# Rootless (recommended): ./identyclaw.sh <cmd>
# Rootful (optional):      sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh <cmd>
#
# Commands:
#   build-image          Pull base + build openclaw-himalaya:local
#   init                 Create agent-a / agent-b / agent-c dirs + Migadu Himalaya config
#   set-password <id>    Set Migadu mailbox password (agent-a | agent-b | agent-c)
#   set-discord-token <id>  Store Discord bot token in secrets/ (survives rebuilds)
#   set-instagram <id>      Store Instagram username/password in secrets/ (survives rebuilds)
#   start [id|all]       Start one or both containers
#   stop [id|all]        Stop containers
#   restart [id|all]     Restart
#   enable-boot          One-time: linger + podman-restart + recreate agents (survives reboot)
#   status               Show podman + health URLs
#   logs <id>            Follow logs
#   test-mail <id>       himalaya envelope list inside container
#   generate-certs [--force]  Issue self-signed TLS PEMs for pod ingress (RODiT handles mutual auth)
#   test-a2a <from> <to> Smoke-test A2A discovery + inbound auth between agents
#   test-webhook <id>    Smoke-test webhook ingress (expect 400/401 without RODiT x-signature)
#   webhook-url <id> [path]  Print public HTTPS webhook URL (pod mode) or loopback URL
#   set-api-key <id>     Store OpenRouter API key (validated) for an agent
#   mirror <to> [from]     Copy working openclaw.json + OpenRouter auth from another agent
#   export-agent <id> [file]  Pack agent secrets + config for migration (optional: --with-browser)
#   import-agent <id> <file>  Restore agent from export-agent archive
#   onboard <id>         Run OpenClaw onboarding (interactive; skips hatch TUI by default)
#   upgrade-plugins [id|all]  Rebuild + install latest A2A + IdentyClaw plugins from GitHub
#   token <id>           Print gateway token for Control UI
#   chat <id>            Interactive terminal chat (openclaw chat)
#   ask <id> <message>   One-shot question to an agent

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
  echo "==> Building ${OPENCLAW_LOCAL_IMAGE} (himalaya ${HIMALAYA_VERSION}, arch ${arch})"
  podman build -f "$ROOT/Containerfile.himalaya" -t "$OPENCLAW_LOCAL_IMAGE" "$ROOT" \
    --build-arg "OPENCLAW_BASE_IMAGE=${OPENCLAW_BASE_IMAGE}" \
    --build-arg "OPENCLAW_BUNDLED_PLUGINS=${OPENCLAW_BUNDLED_PLUGINS}" \
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
  init_one_agent agent-a "$AGENT_A_EMAIL" "$AGENT_A_DISPLAY_NAME" "${AGENT_A_PASSWORD:-}" "$AGENT_A_GATEWAY_PORT"
  init_one_agent agent-b "$AGENT_B_EMAIL" "$AGENT_B_DISPLAY_NAME" "${AGENT_B_PASSWORD:-}" "$AGENT_B_GATEWAY_PORT"
  init_one_agent agent-c "$AGENT_C_EMAIL" "$AGENT_C_DISPLAY_NAME" "${AGENT_C_PASSWORD:-}" "$AGENT_C_GATEWAY_PORT"
  echo ""
  echo "Next:"
  echo "  1. Edit $(identyclaw_env_file) if needed"
  echo "  2. $0 set-password agent-a   # if passwords not in env.local"
  echo "  3. $0 build-image"
  echo "  4. $0 start all"
  echo "  5. $0 enable-boot       # once: survive logout + reboot (sudo for linger)"
  echo "  6. $0 onboard agent-a   # repeat for agent-b, agent-c"
}

cmd_set_password() {
  local id="${1:?Usage: $0 set-password agent-a|agent-b|agent-c}"
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
  local id="${1:?Usage: $0 set-discord-token agent-a|agent-b|agent-c}"
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
  local id="${1:?Usage: $0 set-instagram agent-a|agent-b|agent-c}"
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

start_one() {
  local id="$1"
  load_env
  local dir container gw br z rt
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  read -r gw br < <(agent_ports "$id")
  z="$(selinux_mount_suffix)"
  rt="$(podman_runtime_args)"

  [[ -f "$dir/.env" ]] || { echo "Missing ${dir}/.env — run $0 init" >&2; exit 1; }
  [[ -f "$dir/openclaw.json" ]] || { echo "Missing config — run $0 init" >&2; exit 1; }
  ensure_internal_gateway_port "$dir" "$gw"
  ensure_identyclaw_network
  ensure_agent_bootstrap "$id" "$dir"
  sync_discord_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"

  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    echo "IDENTYCLAW_DEPLOY_MODE=pod — use scripts/deploy-pod.sh instead of identyclaw.sh start" >&2
    exit 1
  fi

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
    --restart always \
    "${network_args[@]}" \
    $rt \
    -e HOME=/home/node \
    -e OPENCLAW_NO_RESPAWN=1 \
    --env-file "$dir/.env" \
    -v "$dir:/home/node/.openclaw:rw${z}" \
    -v "$dir/workspace:/home/node/.openclaw/workspace:rw${z}" \
    -v "$dir/.config:/home/node/.config:ro${z}" \
    -p "${PUBLISH_HOST}:${gw}:18789" \
    -p "${PUBLISH_HOST}:${br}:18790" \
    "$OPENCLAW_LOCAL_IMAGE" \
    node dist/index.js gateway --bind lan --port 18789

  ensure_openclaw_cli_link "$container"
  ensure_agent_packages "$id"
  echo "Started ${container} → http://${PUBLISH_HOST}:${gw}/"
}

cmd_start() {
  require_podman
  require_rootless_user
  ensure_agent_persistence
  local target="${1:-all}"
  case "$target" in
    agent-a|agent-b|agent-c) start_one "$target" ;;
    all)
      start_one agent-a
      start_one agent-b
      start_one agent-c
      ;;
    *) echo "Usage: $0 start [agent-a|agent-b|agent-c|all]" >&2; exit 1 ;;
  esac
}

stop_one() {
  local id="$1"
  podman stop "$(agent_container "$id")" 2>/dev/null || true
  echo "Stopped $(agent_container "$id")"
}

cmd_stop() {
  require_podman
  local target="${1:-all}"
  case "$target" in
    agent-a|agent-b|agent-c) stop_one "$target" ;;
    all)
      stop_one agent-a
      stop_one agent-b
      stop_one agent-c
      ;;
    *) echo "Usage: $0 stop [agent-a|agent-b|agent-c|all]" >&2; exit 1 ;;
  esac
}

cmd_restart() {
  cmd_stop "${1:-all}"
  cmd_start "${1:-all}"
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
  podman inspect openclaw-agent-a openclaw-agent-b openclaw-agent-c \
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
    echo "Production ingress (A2A + webhooks — port ${IDENTYCLAW_INGRESS_PORT}):"
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
  local id="${1:?Usage: $0 logs agent-a|agent-b|agent-c}"
  podman logs -f "$(agent_container "$id")"
}

cmd_test_mail() {
  local id="${1:?Usage: $0 test-mail agent-a|agent-b|agent-c}"
  require_podman
  require_agent_running "$id"
  podman exec "$(agent_container "$id")" himalaya --version
  podman exec "$(agent_container "$id")" himalaya folder list
  podman exec "$(agent_container "$id")" himalaya envelope list --folder INBOX
}

cmd_generate_certs() {
  local force=""
  for arg in "$@"; do
    case "$arg" in
      --force) force="--force" ;;
      -h|--help)
        echo "Usage: $0 generate-certs [--force]"
        echo "Writes fullchain.pem + privkey.pem under \$(identyclaw_app_dir)/certs/"
        echo "SANs: AGENT_A/B/C_PUBLIC_HOST from env.local (defaults in env.example)."
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

cmd_test_a2a() {
  local from_id="${1:?Usage: $0 test-a2a agent-a agent-b}"
  local to_id="${2:?Usage: $0 test-a2a agent-a agent-b}"
  require_podman
  load_env
  require_agent_running "$from_id"
  require_agent_running "$to_id"

  local from_container to_container to_url
  from_container="$(agent_container "$from_id")"
  to_container="$(agent_container "$to_id")"
  to_url="$(agent_agent_card_url "$to_id")"

  echo "==> Discovery: ${from_id} → ${to_id}"
  podman exec "$from_container" curl -sf "$to_url"
  echo ""

  echo "==> Discovery: ${to_id} → ${from_id}"
  podman exec "$to_container" curl -sf "$(agent_agent_card_url "$from_id")"
  echo ""

  echo "==> Inbound auth (expect HTTP 401 without Bearer token)"
  local code a2a_url host port curl_resolve=()
  a2a_url="$(agent_a2a_endpoint_url "$to_id")"
  host="$(agent_public_host "$to_id")"
  port="$(agent_ingress_port "$to_id")"
  if [[ -n "$host" && -n "$port" && "$a2a_url" == https://* ]]; then
    curl_resolve=(--resolve "${host}:${port}:127.0.0.1")
  fi
  code="$(curl -sk "${curl_resolve[@]}" -o /dev/null -w '%{http_code}' -X POST "$a2a_url" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"tasks/get","params":{"id":"smoke"}}')"
  if [[ "$code" != "401" ]]; then
    echo "FAIL: POST /a2a without auth returned HTTP ${code}, expected 401 (${a2a_url})" >&2
    exit 1
  fi
  echo "OK: unauthenticated POST /a2a rejected (HTTP 401)"

  echo ""
  echo "A2A smoke passed (discovery + inbound auth gate)."
  echo "For end-to-end RODiT messaging, run:"
  echo "  $0 ask ${from_id} 'Use a2a_send_message to ping ${to_id} and report the task id'"
}

cmd_webhook_url() {
  local id="${1:?Usage: $0 webhook-url agent-a|agent-b|agent-c [hooks/wake|hooks/agent|hooks/name]}"
  local path="${2:-hooks/wake}"
  agent_webhook_url "$id" "$path"
}

cmd_test_webhook() {
  local id="${1:?Usage: $0 test-webhook agent-a|agent-b|agent-c}"
  load_env
  local url code
  url="$(agent_webhook_url "$id" hooks/wake)"
  echo "==> Webhook ingress auth (expect HTTP 400/401 without RODiT origin signature)"
  echo "    POST ${url}"
  echo "    Senders sign at origin via @rodit/rodit-auth-be: x-signature + x-timestamp (see clienttest-idc)"
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$url" \
    -H 'Content-Type: application/json' \
    -d '{"text":"identyclaw smoke"}')"
  case "$code" in
    400|401) echo "OK: POST /hooks/wake without RODiT signature rejected (HTTP ${code})" ;;
    404)
      echo "WARN: HTTP 404 — webhook route not exposed yet on this gateway" >&2
      exit 1
      ;;
    *)
      echo "FAIL: POST /hooks/wake without auth returned HTTP ${code}, expected 400 or 401" >&2
      exit 1
      ;;
  esac
}

cmd_token() {
  local id="${1:?Usage: $0 token agent-a|agent-b|agent-c}"
  local env_file
  env_file="$(agent_home "$id")/.env"
  grep '^OPENCLAW_GATEWAY_TOKEN=' "$env_file" | cut -d= -f2-
}

require_agent_running() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Start ${container} first: $0 start ${id}" >&2
    exit 1
  }
  ensure_agent_state_for_container_exec "$id"
  ensure_openclaw_cli_link "$container"
}

cmd_chat() {
  local id="${1:?Usage: $0 chat agent-a|agent-b|agent-c}"
  shift
  require_podman
  require_agent_running "$id"
  load_env
  local display ui_base
  display="$(agent_display_name "$id")"
  ui_base="$(agent_ui_base_url "$id")"
  printf '\033]0;%s (%s) — identyclaw chat\007' "$display" "$id"
  echo "=== ${display} · ${id} · ${ui_base}/ · session main ==="
  echo ""
  # Suppress @rodit/rodit-auth-be JSON logs when chat loads the A2A plugin.
  podman exec -it \
    -e LOG_LEVEL=error \
    -e SUPPRESS_NO_CONFIG_WARNING=true \
    -e SUPPRESS_STRICTNESS_CHECK=true \
    "$(agent_container "$id")" node dist/index.js chat "$@"
}

cmd_ask() {
  local id="${1:?Usage: $0 ask agent-a|agent-b|agent-c \"message\"}"
  local message="${2:?Usage: $0 ask agent-a|agent-b|agent-c \"message\"}"
  require_podman
  require_agent_running "$id"
  podman exec \
    -e LOG_LEVEL=error \
    -e SUPPRESS_NO_CONFIG_WARNING=true \
    -e SUPPRESS_STRICTNESS_CHECK=true \
    "$(agent_container "$id")" node dist/index.js agent \
    --agent main -m "$message"
}

cmd_set_api_key() {
  local id="${1:?Usage: $0 set-api-key agent-a|agent-b|agent-c}"
  local dir key
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  read -r -s -p "OpenRouter API key for ${id} (sk-or-...): " key
  echo
  [[ -n "$key" ]] || { echo "empty key" >&2; exit 1; }
  write_openrouter_api_key "$dir" "$key"
  echo "API key stored in ${dir}/agents/main/agent/auth-profiles.json"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_mirror() {
  local to_id="${1:?Usage: $0 mirror agent-b [agent-a]}"
  local from_id="${2:-agent-a}"
  require_rootless_user
  load_env
  mirror_agent_config "$from_id" "$to_id"
  echo "Restart to apply: $0 restart ${to_id}"
}

cmd_export_agent() {
  local id="${1:?Usage: $0 export-agent agent-a|agent-b|agent-c [archive.tar.gz] [--with-browser] [--no-stop]}"
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
  local id="${1:?Usage: $0 import-agent agent-a|agent-b|agent-c archive.tar.gz}"
  local archive="${2:?Usage: $0 import-agent agent-a|agent-b|agent-c archive.tar.gz}"
  require_rootless_user
  load_env
  import_agent_bundle "$id" "$archive"
}

cmd_configure() {
  local id="${1:?Usage: $0 configure agent-a|agent-b|agent-c [openclaw configure flags...]}"
  shift
  require_podman
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Start ${container} first: $0 start ${id}" >&2
    exit 1
  }
  ensure_openclaw_cli_link "$container"
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

cmd_onboard() {
  local id="${1:?Usage: $0 onboard agent-a|agent-b|agent-c}"
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
  echo "  - OpenRouter auth: choose API key. Key must start with sk-or-"
  echo "  - Or set the key first: $0 set-api-key ${id}"
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
  echo "  1. $0 set-api-key ${id}   # if you did not set OpenRouter API key in the wizard"
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
    set-api-key) cmd_set_api_key "$@" ;;
    mirror) cmd_mirror "$@" ;;
    export-agent) cmd_export_agent "$@" ;;
    import-agent) cmd_import_agent "$@" ;;
    configure) cmd_configure "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    enable-boot) cmd_enable_boot "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    test-mail) cmd_test_mail "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    test-a2a) cmd_test_a2a "$@" ;;
    test-webhook) cmd_test_webhook "$@" ;;
    webhook-url) cmd_webhook_url "$@" ;;
    token) cmd_token "$@" ;;
    chat) cmd_chat "$@" ;;
    ask) cmd_ask "$@" ;;
    onboard) cmd_onboard "$@" ;;
    upgrade-plugins) cmd_upgrade_plugins "$@" ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
