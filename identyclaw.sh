#!/usr/bin/env bash
# Identyclaw: three isolated OpenClaw gateways (Podman) + Himalaya (Migadu).
#
# Rootless (recommended): ./identyclaw.sh <cmd>
# Rootful (optional):      sudo IDENTITYCLAW_ROOTLESS=0 ./identyclaw.sh <cmd>
#
# Commands:
#   build-image          Pull base + build openclaw-agent:local
#   init                 Create agent dirs + Migadu Himalaya config (agent-a, agent-c, agent-e)
#   set-password <id|all>  Set Migadu mailbox password (agent-{a-z} or all AGENT_IDS)
#   set-discord-token <id>  Store Discord bot token in secrets/ (survives rebuilds)
#   set-telegram-token <id> Store Telegram bot token in secrets/ (survives rebuilds)
#   set-instagram <id>      Store Instagram username/password in secrets/ (survives rebuilds)
#   set-twitter <id>        Store X/Twitter login + enable hourly DM polling via heartbeat
#   set-twitter-cookies <id>  Store X session cookies (AUTH_TOKEN + CT0) for bird-twitter skill
#   start [id|all]       Start one or both containers
#   stop [id|all]        Stop containers
#   restart [id|all]     Restart
#   restore-host-access [id|all]  Stop pod agents and restore host ownership (edit creds/.env)
#   enable-boot          One-time: linger + podman-restart + recreate agents (survives reboot)
#   status               Show podman + health URLs
#   logs <id>            Follow logs
#   test [id]            Run gateway test suites (default: first AGENT_IDS entry)
#   test-candidates      List remote test peers per agent and mode (a2a / a2a+email / email only)
#   test-all-agents      Start AGENT_IDS, resolve peers, run constitution per local agent
#   test-all-agents-chat Constitution suites + chat-driven peer discovery (A2A + email) per agent
#   test-all-peers       Run constitution suites against every A2A_PEER_AGENTS peer (excl. own token_id)
#   test-peer-gateway    Unit tests: peer URL resolution + repo-local helpers (alias: test-unit)
#   test-unit            All repo-local unit tests (no Podman; CI-safe)
#   test-mail [id]       himalaya envelope list inside container (default: local agent)
#   test-mail-hola [id] [peer-token-id]  Reciprocal email HOLA: we probe peer + peer probes us (REQUIRE_MAIL_HOLA=1 to enforce)
#   respond-mail [id|all]  Poll INBOX, verify inbound HOLA probes, reply (cron/timer entry point)
#   enable-mail-responder [interval]  Install user systemd timer to run respond-mail (default 5min)
#   enable-inbox-check <id> [interval]  Enable LLM inbox heartbeat (default 1h)
#   enable-calendar-check <id> [interval]  Enable calendar/reminder heartbeat (default 30m)
#   enable-slc-heartbeat <id> [interval]  Enable SLC game heartbeat (default 10m; removes stale local playbooks)
#   fix-session-images [id|all]  Patch OpenClaw image-placeholder bug + compact long sessions
#   cleanup-sessions [id|all] [--dry-run]  Truncate oversized sessions (telegram/cron/A2A/tui) + store/cache maintenance
#   enable-session-cleanup [OnCalendar]  Install daily user systemd timer for cleanup-sessions (default 04:15)
#   respond-a2a-hola-smoke [id|all]  Deterministic inbound A2A HOLA probe email sender (smoke tests)
#   enable-a2a-hola-smoke-responder [interval]  Timer for respond-a2a-hola-smoke (default 1min)
#   generate-certs [--force]  Issue self-signed TLS PEMs for pod ingress (RODiT handles mutual auth)
#   test-a2a [from] [peer-token-id]  Smoke-test A2A discovery + inbound auth
#   test-a2a-auth [peer-token-id]    P2P JWT on /a2a (peer when configured, then local inbound)
#   test-a2a-messaging [from] [peer]  message/send → tasks/get E2E (requires live peer)
#   test-auth-boundaries [peer-token-id]  Channel isolation + mutual P2P JWT binding (local + optional peer)
#   test-webhook [id]    Smoke-test webhook ingress (default: local agent)
#                        Includes /api/testhola delivery; set SKIP_TESTHOLA=1 to skip
#   Constitution suite skips: CONSTITUTION_SKIP_SUITES=a2a a2a-messaging webhook mail mail-hola (see env.example)
#   test-webhook-p2p [from] [to]  P2P webhook (defaults: local → peer)
#   send-rodit-webhook <id> <peer-token-id> [text]  POST signed /hooks/wake to peer after 10s (outbound.agents key)
#   webhook-url <id> [path]  Print public HTTPS webhook URL (pod mode) or loopback URL
#   set-api-key <id> [key]     Store OpenRouter API key in secrets/ (survives rebuilds); or OPENROUTER_API_KEY
#   set-opencode-key <id> [key]  Store OpenCode API key in secrets/ (survives rebuilds); or OPENCODE_API_KEY
#   mirror <to> [from]     Copy working openclaw.json + OpenRouter auth from another agent
#   export-agent <id> [file]  Pack agent secrets + config for migration (optional: --with-browser)
#   import-agent <id> <file>  Restore agent from export-agent archive
#   onboard <id>         Run OpenClaw onboarding (interactive; skips hatch TUI by default)
#   upgrade-plugins [id|all]  Refresh A2A + IdentyClaw + webhooks plugins (pinned in env.local)
#   sync-a2a-peers [id|all]  Backfill env.local from discovered peers (optional; URLs normally from API)
#   discover-a2a-peers [id|all]  Proactively discover live peers via GET /api/agents and refresh outbound.agents
#   near-activate <id> [account_id]  Set active NEAR creds (.active + .env + plugin) then restart
#   pairing <id> list [channel]          List pending pairing requests (default: telegram)
#   pairing <id> approve <channel> <code>  Approve a DM pairing code
#   token <id>           Print gateway token for Control UI
#   chat <id>            Interactive terminal chat (openclaw chat)
#   ask <id> <message>   One-shot question to an agent
#   cache-stats [id|all] Prompt-cache hit metrics (OpenRouter sticky session_id + usage)
#   retire-exec-approvals [id|all]  Remove leftover exec-approvals.json (SQLite is canonical)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'
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
  local arch near_target
  arch="$(detect_himalaya_arch)"
  near_target="$(detect_near_cli_rs_target)"
  echo "==> Pulling ${OPENCLAW_BASE_IMAGE}"
  podman pull "$OPENCLAW_BASE_IMAGE"
  local bundled_plugins
  bundled_plugins="$(resolve_openclaw_bundled_plugins)"
  echo "==> Building ${OPENCLAW_LOCAL_IMAGE} (gateway ${OPENCLAW_GATEWAY_VERSION}, himalaya ${HIMALAYA_VERSION}, near-cli-rs ${NEAR_CLI_RS_VERSION}, arch ${arch})"
  podman build -f "$ROOT/Containerfile.agent" -t "$OPENCLAW_LOCAL_IMAGE" "$ROOT" \
    --build-arg "OPENCLAW_BASE_IMAGE=${OPENCLAW_BASE_IMAGE}" \
    --build-arg "OPENCLAW_GATEWAY_VERSION=${OPENCLAW_GATEWAY_VERSION}" \
    --build-arg "OPENCLAW_BUNDLED_PLUGINS=${bundled_plugins}" \
    --build-arg "HIMALAYA_VERSION=${HIMALAYA_VERSION}" \
    --build-arg "HIMALAYA_ARCH=${arch}" \
    --build-arg "NEAR_CLI_RS_VERSION=${NEAR_CLI_RS_VERSION}" \
    --build-arg "NEAR_CLI_RS_TARGET=${near_target}"
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
  write_himalaya_delete_script "$dir"
  write_himalaya_inbox_script "$dir"
  write_himalaya_read_script "$dir"
  write_agent_email_doc "$email" "$display_name" "$dir"
  write_idcp_wallet_scripts "$dir" "$id"
  write_calendar_tooling "$dir"
  write_openclaw_json "$dir" "$gateway_port"
  ensure_agent_env "$dir"
  ensure_main_ingress_config "$id" "$dir"
  ensure_agent_security_hardening "$id" "$dir"

  if [[ -n "$password" ]]; then
    write_secret_helpers "$id" "$password"
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
  init_one_agent agent-c "$AGENT_C_EMAIL" "$AGENT_C_DISPLAY_NAME" "${AGENT_C_PASSWORD:-}" "$AGENT_C_GATEWAY_PORT"
  init_one_agent agent-e "$AGENT_E_EMAIL" "$AGENT_E_DISPLAY_NAME" "${AGENT_E_PASSWORD:-}" "$AGENT_E_GATEWAY_PORT"
  echo ""
  echo "Next:"
  echo "  1. Edit $(identyclaw_env_file) if needed"
  echo "  2. $0 set-password agent-a   # if passwords not in env.local"
  echo "  3. $0 build-image"
  echo "  4. $0 start all"
  echo "  5. $0 enable-boot       # once: survive logout + reboot (sudo for linger)"
  echo "  6. $0 onboard agent-a   # repeat for each id in AGENT_IDS"
}

cmd_set_password() {
  local target="${1:?Usage: $0 set-password agent-b|all}"
  local id dir pw shared_pw=""
  load_env
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      dir="$(agent_home "$id")"
      [[ -d "$dir" ]] || { echo "Missing ${dir} — run $0 init first" >&2; exit 1; }
      if [[ -n "$shared_pw" ]]; then
        read -r -s -p "Migadu password for ${id} [Enter=reuse previous]: " pw
        echo
        pw="${pw:-$shared_pw}"
      else
        read -r -s -p "Migadu password for ${id}: " pw
        echo
      fi
      [[ -n "$pw" ]] || { echo "empty password for ${id}" >&2; exit 1; }
      shared_pw="$pw"
      write_secret_helpers "$id" "$pw" || exit 1
      echo "Password stored for ${id} (secrets/imap.pass + smtp.pass)"
    done
    echo "Done. Himalaya reads secrets live — optional: $0 restart all"
    return 0
  fi
  id="$target"
  dir="$(agent_home "$id")"
  [[ -d "$dir" ]] || { echo "Run $0 init first" >&2; exit 1; }
  read -r -s -p "Migadu password for ${id}: " pw
  echo
  [[ -n "$pw" ]] || { echo "empty password" >&2; exit 1; }
  write_secret_helpers "$id" "$pw" || exit 1
  echo "Password stored for ${id} (secrets/imap.pass + smtp.pass)"
}

cmd_set_discord_token() {
  local id="${1:?Usage: $0 set-discord-token agent-b}"
  local dir container
  load_env
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if [[ ! -d "$dir" ]] && ! _agent_container_name_running "$container"; then
    echo "Run $0 init first" >&2
    exit 1
  fi
  local token
  read -r -s -p "Discord bot token for ${id}: " token
  echo
  write_discord_token "$dir" "$token" "$container"
  echo "Discord token stored in ${dir}/secrets/DISCORD_BOT_TOKEN (mode 600)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_set_telegram_token() {
  local id="${1:?Usage: $0 set-telegram-token agent-b}"
  local dir container
  load_env
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if [[ ! -d "$dir" ]] && ! _agent_container_name_running "$container"; then
    echo "Run $0 init first" >&2
    exit 1
  fi
  local token
  read -r -s -p "Telegram bot token for ${id}: " token
  echo
  write_telegram_token "$dir" "$token" "$container"
  ensure_telegram_ready "$id" "$dir" "$container"
  ensure_telegram_webhook "$id" "$dir" "$container"
  echo "Telegram token stored in ${dir}/secrets/TELEGRAM_BOT_TOKEN (mode 600)"
  if [[ "${IDENTYCLAW_DEPLOY_MODE:-standalone}" == "pod" ]]; then
    echo "Pod webhook: POST $(agent_ingress_base_url "$id")/telegram-webhook"
  else
    echo "Standalone uses Telegram long polling (webhook needs IDENTYCLAW_DEPLOY_MODE=pod on :8443)."
  fi
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
  sync_telegram_env "$dir"
  ensure_discord_allow_bots_mentions "$dir"
  ensure_main_ingress_config "$id" "$dir"
  ensure_agent_security_hardening "$id" "$dir"

  podman rm -f "$container" 2>/dev/null || true
  prepare_agent_state_for_gateway_start "$id" standalone

  local network_args=()
  if podman network exists "$IDENTYCLAW_NETWORK" 2>/dev/null; then
    network_args=(--network "$IDENTYCLAW_NETWORK")
  fi

  # shellcheck disable=SC2086
  mkdir -p "$dir/xdg-config"
  podman run -d --replace \
    --name "$container" \
    --init \
    --shm-size=2g \
    --restart always \
    "${network_args[@]}" \
    $rt \
    -e HOME=/home/node \
    -e XDG_CONFIG_HOME=/home/node/.openclaw/xdg-config \
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
  local failed=()
  case "$target" in
    agent-[a-z]) start_one "$target" || failed+=("$target") ;;
    all)
      local id
      for id in $AGENT_IDS; do
        start_one "$id" || failed+=("$id")
      done
      ;;
    *) echo "Usage: $0 start [agent-id|all]" >&2; exit 1 ;;
  esac
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    ensure_pod_nginx_sidecar || true
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Start failed for: ${failed[*]}" >&2
    return 1
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
  case "$target" in
    agent-[a-z]) stop_one "$target" ;;
    all)
      local id
      for id in $AGENT_IDS; do
        stop_one "$id"
      done
      ;;
    *) echo "Usage: $0 stop [agent-id|all]" >&2; exit 1 ;;
  esac
}

cmd_restore_host_access() {
  require_podman
  load_env
  local target="${1:-all}"
  case "$target" in
    agent-[a-z]) restore_host_access_for_agents "$target" ;;
    all) restore_host_access_for_agents "$AGENT_IDS" ;;
    *) echo "Usage: $0 restore-host-access [agent-id|all]" >&2; exit 1 ;;
  esac
}

cmd_restart() {
  require_podman
  load_env
  local target="${1:-all}"
  if [[ "$IDENTYCLAW_DEPLOY_MODE" == "pod" ]]; then
    local failed=()
    case "$target" in
      agent-[a-z]) start_pod_agent "$target" restart || failed+=("$target") ;;
      all)
        local id
        for id in $AGENT_IDS; do
          start_pod_agent "$id" restart || failed+=("$id")
        done
        ;;
      *) echo "Usage: $0 restart [agent-id|all]" >&2; exit 1 ;;
    esac
    ensure_pod_nginx_sidecar || true
    if [[ ${#failed[@]} -gt 0 ]]; then
      echo "Restart failed for: ${failed[*]}" >&2
      return 1
    fi
    return 0
  fi
  cmd_stop "$target"
  cmd_start "$target"
}

# Re-point active NEAR credentials then restart the gateway so plugins load the new key.
cmd_near_activate() {
  local id="${1:?Usage: $0 near-activate <agent-id> [account_id]}"
  local account_id="${2:-}"
  local config_dir container activate_script cred_dir
  require_podman
  load_env
  config_dir="$(agent_home "$id")"
  ensure_idcp_wallet_tooling "$id" "$config_dir"
  cred_dir="$config_dir/secrets/near-credentials"
  if [[ -z "$account_id" ]]; then
    if [[ -f "$cred_dir/.active" ]]; then
      account_id="$(tr -d '[:space:]' <"$cred_dir/.active")"
    else
      account_id="$(basename "$(resolve_near_credentials_file "$config_dir" 2>/dev/null || true)" .json)"
    fi
  fi
  [[ -n "$account_id" ]] || {
    echo "Usage: $0 near-activate <agent-id> [account_id]" >&2
    echo "No account_id and no readable credentials under ${cred_dir}" >&2
    exit 1
  }
  container="$(agent_container "$id")"
  activate_script="$config_dir/workspace/scripts/idcp-activate-account.sh"
  echo "==> Activating NEAR account ${account_id} for ${id}"
  if _agent_container_name_running "$container" 2>/dev/null; then
    # Ensure scripts exist in the mounted workspace, then run inside the container.
    ensure_idcp_wallet_tooling "$id" "$config_dir"
    IDENTYCLAW_AGENT_ID="$id" podman exec -e IDENTYCLAW_AGENT_ID="$id" \
      -e OPENCLAW_HOME=/home/node/.openclaw \
      "$container" sh /home/node/.openclaw/workspace/scripts/idcp-activate-account.sh "$account_id" \
      || {
        # Fallback: run on host against agent state dir
        OPENCLAW_HOME="$config_dir" IDENTYCLAW_AGENT_ID="$id" \
          sh "$activate_script" "$account_id"
      }
  else
    OPENCLAW_HOME="$config_dir" IDENTYCLAW_AGENT_ID="$id" \
      sh "$activate_script" "$account_id"
  fi
  # Re-sync plugin config from the newly active file, then bounce gateway.
  ensure_near_credentials_active "$config_dir"
  sync_identyclaw_env "$config_dir" "$container" || true
  ensure_identyclaw_config "$config_dir" "$container" || true
  echo "==> Restarting ${id} to load activated credentials"
  cmd_restart "$id"
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
    echo "Control UI (operator; not on public ingress — use chat or loopback):"
    for id in $AGENT_IDS; do
      echo "  ${id}: ./identyclaw.sh chat ${id}   (token: ./identyclaw.sh token ${id})"
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

cmd_enable_inbox_check() {
  local id="${1:?Usage: $0 enable-inbox-check agent-a [interval]}"
  local interval="${2:-1h}"
  enable_inbox_heartbeat "$id" "$interval"
  echo "Inbox heartbeat enabled (HEARTBEAT.md inbox-check + agents.defaults.heartbeat.every=${interval})"
  echo "Persisted in secrets/inbox-heartbeat.interval (re-applied on start/restart/bootstrap)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_enable_calendar_check() {
  local id="${1:?Usage: $0 enable-calendar-check agent-a [interval]}"
  local interval="${2:-30m}"
  enable_calendar_heartbeat "$id" "$interval"
  echo "Calendar heartbeat enabled (HEARTBEAT.md calendar-upcoming + agents.defaults.heartbeat.every<=${interval})"
  echo "Persisted in secrets/calendar-heartbeat.interval (re-applied on start/restart/bootstrap)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_enable_slc_heartbeat() {
  local id="${1:?Usage: $0 enable-slc-heartbeat agent-a [interval]}"
  local interval="${2:-10m}"
  enable_slc_heartbeat "$id" "$interval"
  echo "SLC heartbeat enabled (HEARTBEAT.md slc-game + agents.defaults.heartbeat.every=${interval})"
  echo "Removed local SLC.md / cached synthetics-last-cradle skill; installed knowledge/references/slc-play-unattended.md (host skill.md is authoritative)"
  echo "Persisted in secrets/slc-heartbeat.interval (re-applied on start/restart/bootstrap)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_fix_session_images() {
  local target="${1:-all}"
  local id
  require_podman
  load_env
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      fix_openclaw_session_images "$id" || true
    done
  else
    fix_openclaw_session_images "$target"
  fi
}

# Truncate oversized transcripts (all session keys), enforce store cleanup, rotate huge cache-trace.
# Prefer this over LLM /compact when auto-compaction times out ("Context is too large…").
cmd_cleanup_sessions() {
  local target="all"
  local dry_run=0
  local arg id
  require_podman
  load_env
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) dry_run=1 ;;
      -h|--help|help)
        echo "Usage: $0 cleanup-sessions [id|all] [--dry-run]"
        echo "  Truncates sessions at/above IDENTYCLAW_SESSION_CLEANUP_TOKEN_FLOOR (default 50k)"
        echo "  to the last IDENTYCLAW_SESSION_CLEANUP_MAX_LINES lines (default 120)."
        echo "  Also runs sessions cleanup --enforce and rotates oversized cache-trace.jsonl."
        echo "  Schedule daily: $0 enable-session-cleanup"
        exit 0
        ;;
      all|agent-[a-z]) target="$arg" ;;
      *)
        echo "Usage: $0 cleanup-sessions [id|all] [--dry-run]" >&2
        exit 1
        ;;
    esac
  done
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      cleanup_openclaw_sessions "$id" "$dry_run" || true
    done
  else
    cleanup_openclaw_sessions "$target" "$dry_run"
  fi
}

# Install a daily user systemd timer that runs cleanup-sessions for all AGENT_IDS.
cmd_enable_session_cleanup() {
  require_rootless_user
  local on_calendar="${1:-${IDENTYCLAW_SESSION_CLEANUP_ON_CALENDAR:-*-*-* 04:15:00}}"
  local unit_dir="${HOME}/.config/systemd/user"
  local script_path="${ROOT}/identyclaw.sh"
  load_env
  mkdir -p "$unit_dir"
  cat >"${unit_dir}/identyclaw-session-cleanup.service" <<EOF
[Unit]
Description=IdentyClaw OpenClaw session cleanup (truncate oversized context + store maintenance)
After=podman-restart.service

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/env bash ${script_path} cleanup-sessions all
EOF
  cat >"${unit_dir}/identyclaw-session-cleanup.timer" <<EOF
[Unit]
Description=Daily IdentyClaw session cleanup (${on_calendar})

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now identyclaw-session-cleanup.timer
  echo "==> Session cleanup timer enabled (OnCalendar=${on_calendar})."
  echo "    Run once:  $0 cleanup-sessions all"
  echo "    Dry-run:   $0 cleanup-sessions all --dry-run"
  echo "    Status:    systemctl --user status identyclaw-session-cleanup.timer"
  echo "    Logs:      journalctl --user -u identyclaw-session-cleanup.service -f"
  echo "    Disable:   systemctl --user disable --now identyclaw-session-cleanup.timer"
}

cmd_retire_exec_approvals() {
  local target="${1:-all}"
  local id seen="" extra
  require_podman
  load_env
  if [[ "$target" == "all" ]]; then
    for id in $AGENT_IDS; do
      retire_legacy_exec_approvals_one "$id" || true
      seen="${seen} $(agent_container "$id")"
    done
    # Running containers not listed in AGENT_IDS (stale or extra letters).
    while read -r extra; do
      [[ -n "$extra" ]] || continue
      [[ " ${seen} " == *" ${extra} "* ]] && continue
      id="${extra#openclaw-}"
      is_valid_agent_id "$id" || continue
      echo "==> extra container ${extra}"
      retire_legacy_exec_approvals_one "$id" || true
    done < <(podman ps --format '{{.Names}}' 2>/dev/null | grep -E '^openclaw-agent-[a-z]$' || true)
    return 0
  fi
  is_valid_agent_id "$target" || {
    echo "Usage: $0 retire-exec-approvals [agent-id|all]" >&2
    return 1
  }
  retire_legacy_exec_approvals_one "$target"
}

# Run deterministic inbound A2A webhook smoke handler once (constitution peer → local webhook).
respond_a2a_webhook_smoke_one() {
  local id="$1"
  local container creds
  container="$(agent_container "$id")"
  if ! podman ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "    (${id}: container not running — skip A2A webhook smoke responder)" >&2
    return 0
  fi
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "    (${id}: no NEAR credentials — skip A2A webhook smoke responder)" >&2
    return 0
  }
  podman_cp_a2a_webhook_smoke_libs "$container" || {
    echo "    (${id}: failed to copy A2A webhook smoke libs)" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/respond-a2a-webhook-smoke.mjs" "$container:/tmp/respond-a2a-webhook-smoke.mjs" >/dev/null
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
    node /tmp/respond-a2a-webhook-smoke.mjs --creds "$creds"
}

cmd_respond_a2a_webhook_smoke() {
  local target="${1:-}"
  load_env
  require_podman
  if [[ -z "$target" || "$target" == "all" ]]; then
    local rc=0
    for id in $AGENT_IDS; do
      echo "==> A2A webhook smoke responder: ${id}"
      respond_a2a_webhook_smoke_one "$id" || rc=1
    done
    return "$rc"
  fi
  is_valid_agent_id "$target" || { echo "Invalid agent id: ${target}" >&2; return 1; }
  echo "==> A2A webhook smoke responder: ${target}"
  respond_a2a_webhook_smoke_one "$target"
}

cmd_enable_a2a_webhook_smoke_responder() {
  require_rootless_user
  local interval="${1:-1min}"
  local unit_dir="${HOME}/.config/systemd/user"
  local script_path="${ROOT}/identyclaw.sh"
  mkdir -p "$unit_dir"
  cat >"${unit_dir}/identyclaw-a2a-webhook-smoke-responder.service" <<EOF
[Unit]
Description=IdentyClaw inbound A2A webhook smoke responder (deterministic send_rodit_webhook)
After=podman-restart.service

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/env bash ${script_path} respond-a2a-webhook-smoke all
EOF
  cat >"${unit_dir}/identyclaw-a2a-webhook-smoke-responder.timer" <<EOF
[Unit]
Description=Run IdentyClaw A2A webhook smoke responder every ${interval}

[Timer]
OnBootSec=90s
OnUnitActiveSec=${interval}
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now identyclaw-a2a-webhook-smoke-responder.timer
  echo "==> A2A webhook smoke responder timer enabled (every ${interval})."
  echo "    Status:  systemctl --user status identyclaw-a2a-webhook-smoke-responder.timer"
  echo "    Logs:    journalctl --user -u identyclaw-a2a-webhook-smoke-responder.service -f"
  echo "    Disable: systemctl --user disable --now identyclaw-a2a-webhook-smoke-responder.timer"
}

# Run deterministic inbound A2A email HOLA smoke handler once (reciprocal mail HOLA peer → local).
respond_a2a_hola_smoke_one() {
  local id="$1"
  local container creds ext_dir mailbox email display_name own_token_id
  container="$(agent_container "$id")"
  if ! podman ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "    (${id}: container not running — skip A2A HOLA smoke responder)" >&2
    return 0
  fi
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "    (${id}: no NEAR credentials — skip A2A HOLA smoke responder)" >&2
    return 0
  }
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  [[ -n "$email" ]] || {
    echo "    (${id}: no AGENT_*_EMAIL — skip A2A HOLA smoke responder)" >&2
    return 0
  }
  own_token_id="$(agent_token_id "$id" 2>/dev/null || true)"
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_a2a_hola_smoke_libs "$container" || {
    echo "    (${id}: failed to copy A2A HOLA smoke libs)" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/respond-a2a-hola-smoke.mjs" "$container:/tmp/respond-a2a-hola-smoke.mjs" >/dev/null
  local -a args=(--creds "$creds" --from-email "$email" --from-name "$display_name" --ext-dir "$ext_dir")
  # Signer token_id is resolved in-container from getConfigOwnRodit (NEAR key); host value is fallback only.
  [[ -n "$own_token_id" ]] && args+=(--own-token-id "$own_token_id")
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
    node /tmp/respond-a2a-hola-smoke.mjs "${args[@]}"
}

cmd_respond_a2a_hola_smoke() {
  local target="${1:-}"
  load_env
  require_podman
  if [[ -z "$target" || "$target" == "all" ]]; then
    local rc=0
    for id in $AGENT_IDS; do
      echo "==> A2A HOLA smoke responder: ${id}"
      respond_a2a_hola_smoke_one "$id" || rc=1
    done
    return "$rc"
  fi
  is_valid_agent_id "$target" || { echo "Invalid agent id: ${target}" >&2; return 1; }
  echo "==> A2A HOLA smoke responder: ${target}"
  respond_a2a_hola_smoke_one "$target"
}

cmd_enable_a2a_hola_smoke_responder() {
  require_rootless_user
  local interval="${1:-1min}"
  local unit_dir="${HOME}/.config/systemd/user"
  local script_path="${ROOT}/identyclaw.sh"
  mkdir -p "$unit_dir"
  cat >"${unit_dir}/identyclaw-a2a-hola-smoke-responder.service" <<EOF
[Unit]
Description=IdentyClaw inbound A2A email HOLA smoke responder (deterministic himalaya send)
After=podman-restart.service

[Service]
Type=oneshot
WorkingDirectory=${ROOT}
ExecStart=/usr/bin/env bash ${script_path} respond-a2a-hola-smoke all
EOF
  cat >"${unit_dir}/identyclaw-a2a-hola-smoke-responder.timer" <<EOF
[Unit]
Description=Run IdentyClaw A2A HOLA smoke responder every ${interval}

[Timer]
OnBootSec=90s
OnUnitActiveSec=${interval}
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now identyclaw-a2a-hola-smoke-responder.timer
  echo "==> A2A HOLA smoke responder timer enabled (every ${interval})."
  echo "    Status:  systemctl --user status identyclaw-a2a-hola-smoke-responder.timer"
  echo "    Logs:    journalctl --user -u identyclaw-a2a-hola-smoke-responder.service -f"
  echo "    Disable: systemctl --user disable --now identyclaw-a2a-hola-smoke-responder.timer"
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

cmd_pairing() {
  local id="${1:?Usage: $0 pairing agent-b list|approve <channel> [code]}"
  shift
  local action="${1:?Usage: $0 pairing <id> list|approve <channel> [code]}"
  shift
  require_podman
  require_agent_running "$id"
  local container
  container="$(agent_container "$id")"
  case "$action" in
    list)
      local channel="${1:-telegram}"
      podman exec "$container" node dist/index.js pairing list "$channel"
      ;;
    approve)
      local channel="${1:?Usage: $0 pairing <id> approve <channel> <code>}"
      local code="${2:?Usage: $0 pairing <id> approve <channel> <code>}"
      podman exec "$container" node dist/index.js pairing approve "$channel" "$code"
      ;;
    *)
      echo "Unknown pairing action: $action (use list or approve)" >&2
      echo "Usage:" >&2
      echo "  $0 pairing <id> list [channel]          (default: telegram)" >&2
      echo "  $0 pairing <id> approve <channel> <code>" >&2
      exit 1
      ;;
  esac
}

cmd_token() {
  local id="${1:?Usage: $0 token agent-b}"
  agent_gateway_token "$id"
}

cmd_cache_stats() {
  local target="${1:-all}"
  local id dir container ids=()
  load_env
  if [[ "$target" == "all" ]]; then
    # shellcheck disable=SC2206
    ids=($AGENT_IDS)
  else
    is_valid_agent_id "$target" || {
      echo "Usage: $0 cache-stats [agent-id|all]" >&2
      return 1
    }
    ids=("$target")
  fi
  [[ ${#ids[@]} -gt 0 ]] || {
    echo "No AGENT_IDS in env.local" >&2
    return 1
  }
  echo "==> Prompt-cache stats (sticky session_id=${OPENCLAW_OPENROUTER_SESSION_ID:-identyclaw}, cacheTrace=${OPENCLAW_CACHE_TRACE:-1})"
  for id in "${ids[@]}"; do
    dir="$(agent_home "$id")"
    container="$(agent_container "$id")"
    # Prefer in-container read when host cannot open container-owned openclaw.json (pod mode).
    if command -v podman >/dev/null 2>&1 \
      && podman container inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
      podman cp "${IDENTYCLAW_ROOT}/scripts/lib-openclaw-cache-config.mjs" \
        "${container}:/tmp/lib-openclaw-cache-config.mjs" >/dev/null 2>&1 || true
      podman cp "${IDENTYCLAW_ROOT}/scripts/summarize-cache-stats.mjs" \
        "${container}:/tmp/summarize-cache-stats.mjs" >/dev/null 2>&1 || true
      podman exec "$container" node /tmp/summarize-cache-stats.mjs \
        --state-dir /home/node/.openclaw --agent "$id" || true
      continue
    fi
    if [[ -r "$dir/openclaw.json" ]]; then
      node "${IDENTYCLAW_ROOT}/scripts/summarize-cache-stats.mjs" \
        --state-dir "$dir" --agent "$id" || true
      continue
    fi
    echo "${id}: (no readable state — start the agent or restore-host-access)"
  done
  echo ""
  echo "Tips: /usage full in chat; DeepSeek may report cached_tokens=0 on the first warm-up turn."
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
  ensure_agent_mail_tooling_refresh "$id"
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
  ensure_agent_mail_tooling_refresh "$id"
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
  echo "API key stored for ${id} (secrets/OPENROUTER_API_KEY; survives rebuilds)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_set_opencode_key() {
  local id="${1:?Usage: $0 set-opencode-key agent-b [sk-...]}"
  local key="${2:-${OPENCODE_API_KEY:-}}"
  local dir
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
  echo "API key stored for ${id} (secrets/OPENCODE_API_KEY; survives rebuilds)"
  echo "Restart to apply: $0 restart ${id}"
}

cmd_mirror() {
  local to_id="${1:?Usage: $0 mirror agent-c [agent-a]}"
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
  # Drop host git build cache so upgrade pulls latest GitHub tip once, then reuses across agents.
  rm -f "$(identyclaw_app_dir)/repo/openclaw-identyclaw-plugin/.identyclaw-git-build" 2>/dev/null || true
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
    set-telegram-token) cmd_set_telegram_token "$@" ;;
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
    near-activate) cmd_near_activate "$@" ;;
    restore-host-access) cmd_restore_host_access "$@" ;;
    enable-boot) cmd_enable_boot "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    test) cmd_test "$@" ;;
    test-candidates) cmd_test_candidates "$@" ;;
    test-all-agents) cmd_test_all_agents "$@" ;;
    test-all-agents-chat) cmd_test_all_agents_chat "$@" ;;
    test-all-peers) cmd_test_all_peers "$@" ;;
    test-peer-gateway) cmd_test_peer_gateway "$@" ;;
    test-unit) cmd_test_unit "$@" ;;
    test-a2a-messaging) cmd_test_a2a_messaging "$@" ;;
    test-mail) cmd_test_mail "$@" ;;
    test-mail-hola) cmd_test_mail_hola "$@" ;;
    respond-mail) cmd_respond_mail "$@" ;;
    enable-mail-responder) cmd_enable_mail_responder "$@" ;;
    enable-inbox-check) cmd_enable_inbox_check "$@" ;;
    enable-calendar-check) cmd_enable_calendar_check "$@" ;;
    enable-slc-heartbeat) cmd_enable_slc_heartbeat "$@" ;;
    fix-session-images) cmd_fix_session_images "$@" ;;
    cleanup-sessions) cmd_cleanup_sessions "$@" ;;
    enable-session-cleanup) cmd_enable_session_cleanup "$@" ;;
    respond-a2a-webhook-smoke) cmd_respond_a2a_webhook_smoke "$@" ;;
    enable-a2a-webhook-smoke-responder) cmd_enable_a2a_webhook_smoke_responder "$@" ;;
    respond-a2a-hola-smoke) cmd_respond_a2a_hola_smoke "$@" ;;
    enable-a2a-hola-smoke-responder) cmd_enable_a2a_hola_smoke_responder "$@" ;;
    generate-certs) cmd_generate_certs "$@" ;;
    test-a2a) cmd_test_a2a "$@" ;;
    test-a2a-auth) cmd_test_a2a_auth "$@" ;;
    test-auth-boundaries) cmd_test_auth_boundaries "$@" ;;
    test-webhook) cmd_test_webhook "$@" ;;
    test-webhook-p2p) cmd_test_webhook_p2p "$@" ;;
    send-rodit-webhook) cmd_send_rodit_webhook "$@" ;;
    webhook-url) cmd_webhook_url "$@" ;;
    pairing) cmd_pairing "$@" ;;
    token) cmd_token "$@" ;;
    cache-stats) cmd_cache_stats "$@" ;;
    retire-exec-approvals) cmd_retire_exec_approvals "$@" ;;
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
