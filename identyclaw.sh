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
#   start [id|all]       Start one or both containers
#   stop [id|all]        Stop containers
#   restart [id|all]     Restart
#   enable-boot          One-time: linger + podman-restart + recreate agents (survives reboot)
#   status               Show podman + health URLs
#   logs <id>            Follow logs
#   test-mail <id>       himalaya envelope list inside container
#   set-api-key <id>     Store OpenRouter API key (validated) for an agent
#   mirror <to> [from]     Copy working openclaw.json + OpenRouter auth from another agent
#   onboard <id>         Run OpenClaw onboarding (interactive; skips hatch TUI by default)
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
  load_env
  init_one_agent agent-a "$AGENT_A_EMAIL" "$AGENT_A_DISPLAY_NAME" "${AGENT_A_PASSWORD:-}" "$AGENT_A_GATEWAY_PORT"
  init_one_agent agent-b "$AGENT_B_EMAIL" "$AGENT_B_DISPLAY_NAME" "${AGENT_B_PASSWORD:-}" "$AGENT_B_GATEWAY_PORT"
  init_one_agent agent-c "$AGENT_C_EMAIL" "$AGENT_C_DISPLAY_NAME" "${AGENT_C_PASSWORD:-}" "$AGENT_C_GATEWAY_PORT"
  echo ""
  echo "Next:"
  echo "  1. Edit ${ROOT}/env.local if needed (cp env.example env.local)"
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

agent_ports() {
  local id="$1"
  case "$id" in
    agent-a) echo "$AGENT_A_GATEWAY_PORT $AGENT_A_BRIDGE_PORT" ;;
    agent-b) echo "$AGENT_B_GATEWAY_PORT $AGENT_B_BRIDGE_PORT" ;;
    agent-c) echo "$AGENT_C_GATEWAY_PORT $AGENT_C_BRIDGE_PORT" ;;
    *) echo "unknown agent: $id" >&2; exit 1 ;;
  esac
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
  ensure_agent_bootstrap "$id" "$dir"
  sync_discord_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"

  podman rm -f "$container" 2>/dev/null || true

  # shellcheck disable=SC2086
  podman run -d --replace \
    --name "$container" \
    --init \
    --restart always \
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
  echo "Control UI (use token from: $0 token <id>):"
  echo "  agent-a: http://${PUBLISH_HOST}:${AGENT_A_GATEWAY_PORT}/"
  echo "  agent-b: http://${PUBLISH_HOST}:${AGENT_B_GATEWAY_PORT}/"
  echo "  agent-c: http://${PUBLISH_HOST}:${AGENT_C_GATEWAY_PORT}/"
}

cmd_logs() {
  local id="${1:?Usage: $0 logs agent-a|agent-b|agent-c}"
  podman logs -f "$(agent_container "$id")"
}

cmd_test_mail() {
  local id="${1:?Usage: $0 test-mail agent-a|agent-b|agent-c}"
  podman exec "$(agent_container "$id")" himalaya --version
  podman exec "$(agent_container "$id")" himalaya folder list
  podman exec "$(agent_container "$id")" himalaya envelope list --folder INBOX
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
  ensure_openclaw_cli_link "$container"
}

cmd_chat() {
  local id="${1:?Usage: $0 chat agent-a|agent-b|agent-c}"
  shift
  require_podman
  require_agent_running "$id"
  load_env
  local display gw
  display="$(agent_display_name "$id")"
  read -r gw _ < <(agent_ports "$id")
  printf '\033]0;%s (%s) — identyclaw chat\007' "$display" "$id"
  echo "=== ${display} · ${id} · http://${PUBLISH_HOST}:${gw}/ · session main ==="
  echo ""
  podman exec -it "$(agent_container "$id")" node dist/index.js chat "$@"
}

cmd_ask() {
  local id="${1:?Usage: $0 ask agent-a|agent-b|agent-c \"message\"}"
  local message="${2:?Usage: $0 ask agent-a|agent-b|agent-c \"message\"}"
  require_podman
  require_agent_running "$id"
  podman exec "$(agent_container "$id")" node dist/index.js agent \
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
  case "$cmd" in
    build-image) cmd_build_image "$@" ;;
    init) cmd_init "$@" ;;
    set-password) cmd_set_password "$@" ;;
    set-discord-token) cmd_set_discord_token "$@" ;;
    set-api-key) cmd_set_api_key "$@" ;;
    mirror) cmd_mirror "$@" ;;
    configure) cmd_configure "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    enable-boot) cmd_enable_boot "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    test-mail) cmd_test_mail "$@" ;;
    token) cmd_token "$@" ;;
    chat) cmd_chat "$@" ;;
    ask) cmd_ask "$@" ;;
    onboard) cmd_onboard "$@" ;;
    -h|--help|help|"") usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage 1
      ;;
  esac
}

main "$@"
