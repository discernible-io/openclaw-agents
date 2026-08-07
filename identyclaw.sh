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
#   enable-slc-heartbeat <id> [interval]  Enable SLC game heartbeat (default 10m; removes stale local playbooks)
#   fix-session-images [id|all]  Patch OpenClaw image-placeholder bug + compact long sessions
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
#   set-api-key <id> [key]     Store OpenRouter API key (validated); or OPENROUTER_API_KEY
#   set-opencode-key <id> [key]  Store OpenCode Zen/Go API key (validated); or OPENCODE_API_KEY
#   mirror <to> [from]     Copy working openclaw.json + OpenRouter auth from another agent
#   export-agent <id> [file]  Pack agent secrets + config for migration (optional: --with-browser)
#   import-agent <id> <file>  Restore agent from export-agent archive
#   onboard <id>         Run OpenClaw onboarding (interactive; skips hatch TUI by default)
#   upgrade-plugins [id|all]  Refresh A2A + IdentyClaw + webhooks plugins (pinned in env.local)
#   sync-a2a-peers [id|all]  Backfill env.local from discovered peers (optional; URLs normally from API)
#   discover-a2a-peers [id|all]  Proactively discover live peers via GET /api/agents and refresh outbound.agents
#   near-activate <id> [account_id]  Set active NEAR creds (.active + .env + plugin) then restart
#   token <id>           Print gateway token for Control UI
#   chat <id>            Interactive terminal chat (openclaw chat)
#   ask <id> <message>   One-shot question to an agent
#   cache-stats [id|all] Prompt-cache hit metrics (OpenRouter sticky session_id + usage)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

usage() {
  sed -n '2,61p' "$0" | sed 's/^# \{0,1\}//'
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
  case "$target" in
    agent-[a-z]) start_one "$target" ;;
    all)
      local id
      for id in $AGENT_IDS; do
        start_one "$id"
      done
      ;;
    *) echo "Usage: $0 start [agent-id|all]" >&2; exit 1 ;;
  esac
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
    case "$target" in
      agent-[a-z]) start_pod_agent "$target" restart ;;
      all)
        local id
        for id in $AGENT_IDS; do
          start_pod_agent "$id" restart
        done
        ;;
      *) echo "Usage: $0 restart [agent-id|all]" >&2; exit 1 ;;
    esac
    ensure_pod_nginx_ingress_config || true
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

cmd_test_mail_hola() {
  local id="" peer_token_id="" container creds ext_dir mailbox email display_name failed=0
  load_env
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    id="$1"
    shift
  fi
  if [[ -n "${1:-}" ]] && is_passport_token_id "$1"; then
    peer_token_id="$1"
  fi
  id="${id:-$(resolve_local_agent_id)}"
  if [[ -z "$peer_token_id" ]]; then
    peer_token_id="$(resolve_peer_token_id "$id" 2>/dev/null || true)"
  fi
  require_podman
  require_agent_running "$id"
  [[ -n "$peer_token_id" ]] || {
    echo "No peer token_id in A2A_PEER_AGENTS (need a peer for email HOLA probe)" >&2
    return 1
  }
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials in ${id} container (secrets/near-credentials/*.json)" >&2
    return 1
  }
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  [[ -n "$email" ]] || {
    echo "No AGENT_*_EMAIL for ${id} in env.local" >&2
    return 1
  }
  container="$(agent_container "$id")"
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_mail_hola_test_libs "$container" || {
    echo "Failed to copy mail HOLA test libs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-mail-hola-peer.mjs" "$container:/tmp/test-mail-hola-peer.mjs" >/dev/null

  echo "==> Email HOLA peer probe (local=${id} → peer token_id=${peer_token_id})"
  echo "    from=${email}"
  if a2a_peer_token_id_on_this_host "$peer_token_id"; then
    echo "    hint: enable ./identyclaw.sh respond-mail on peer agent for INBOX reply checks"
  fi
  local -a hola_args=(
    --ext-dir "$ext_dir"
    --creds "$creds"
    --peer-token-id "$peer_token_id"
    --from-email "$email"
    --from-name "$display_name"
  )
  local api_base poll_sec peer_base
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] && hola_args+=(--api-base "$api_base")
  poll_sec="${MAIL_HOLA_POLL_SECONDS:-180}"
  hola_args+=(--poll-seconds "$poll_sec")
  # Peer A2A gateway lets us drive the reciprocal inbound probe (peer → us).
  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
  local hola_inbound=0
  if [[ -n "$peer_base" ]]; then
    if a2a_peer_token_id_on_this_host "$peer_token_id"; then
      hola_inbound=1
      echo "    inbound reciprocal: same-host peer — deterministic A2A HOLA smoke responder signs with peer NEAR key"
    elif ! peer_mail_hola_ambiguous "$id" "$peer_token_id"; then
      hola_inbound=1
    else
      echo "    skip inbound reciprocal (peer gateway shares this host's pod ingress; peerTokenId binding is ambiguous)"
    fi
  fi
  if [[ $hola_inbound -eq 1 ]]; then
    hola_args+=(--peer-base "$peer_base")
  else
    hola_args+=(--skip-inbound)
  fi
  [[ "${REQUIRE_MAIL_HOLA:-0}" == 1 ]] && hola_args+=(--require)

  local hola_smoke_pids=() smoke_id=""
  if [[ $hola_inbound -eq 1 ]]; then
    for smoke_id in $AGENT_IDS; do
      if agent_container_running "$smoke_id"; then
        echo "    Inbound: polling ${smoke_id} A2A HOLA smoke responder during reciprocal test"
        (
          while true; do
            respond_a2a_hola_smoke_one "$smoke_id" >/dev/null 2>&1 || true
            sleep "${MAIL_HOLA_SMOKE_POLL_SEC:-2}"
          done
        ) &
        hola_smoke_pids+=("$!")
      fi
    done
  fi

  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 -e "REQUIRE_MAIL_HOLA=${REQUIRE_MAIL_HOLA:-0}" \
    "$container" node /tmp/test-mail-hola-peer.mjs \
    "${hola_args[@]}" || failed=1

  if [[ ${#hola_smoke_pids[@]} -gt 0 ]]; then
    local pid
    for pid in "${hola_smoke_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    for smoke_id in $AGENT_IDS; do
      respond_a2a_hola_smoke_one "$smoke_id" >/dev/null 2>&1 || true
    done
  fi

  return "$failed"
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

a2a_fetch_agent_card() {
  local runner_id="$1" target_id="$2"
  local url container resolve=() curl_flags=(-sk) card_json schema_rc=0
  url="$(agent_agent_card_url "$target_id")"
  if agent_is_local "$runner_id" && agent_container_running "$runner_id"; then
    container="$(agent_container "$runner_id")"
    if agent_is_local "$target_id"; then
      mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
    fi
    card_json="$(podman exec "$container" curl "${curl_flags[@]}" "${resolve[@]}" "$url")"
  else
    mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
    card_json="$(curl -sk "${resolve[@]}" "$url")"
  fi
  echo "$card_json"
  if [[ -f "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" ]]; then
    echo "$card_json" | node "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" --label "${target_id}" || schema_rc=$?
    return "$schema_rc"
  fi
  return 0
}

a2a_fetch_peer_agent_card() {
  local runner_id="$1" peer_token_id="$2"
  local url container curl_flags=(-sk) resolver_dir card_json schema_rc=0
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
    card_json="$(podman exec "$container" curl "${curl_flags[@]}" "$url")"
  else
    card_json="$(curl -sk "$url")"
  fi
  echo "$card_json"
  if [[ -f "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" ]]; then
    echo "$card_json" | node "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" --label "peer:${peer_token_id}" || schema_rc=$?
    return "$schema_rc"
  fi
  return 0
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
  local from_id peer_token_id self_token_id failed=0
  require_podman
  load_env
  from_id="${1:-$(resolve_local_agent_id)}"
  peer_token_id="${2:-}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  elif [[ -z "$peer_token_id" && "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    peer_token_id="$(resolve_peer_token_id "$from_id" 2>/dev/null || true)"
  fi
  require_agent_running "$from_id"
  self_token_id="$(agent_token_id "$from_id")"

  echo "==> A2A smoke (local=${from_id}, self token_id=${self_token_id:-unknown})"

  if [[ -n "$peer_token_id" ]]; then
    is_passport_token_id "$peer_token_id" || {
      echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
      exit 1
    }
    local peer_resolver_dir peer_base
    peer_resolver_dir="$(agent_home "$from_id")"
    echo "==> Discovery: peer token_id=${peer_token_id}"
    peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$peer_resolver_dir" 2>/dev/null || true)"
    if [[ -n "$peer_base" ]]; then
      if a2a_peer_public_base_url_from_env_map "$peer_token_id" >/dev/null 2>&1; then
        echo "    base=${peer_base} (A2A_PEER_URLS)"
      else
        echo "    base=${peer_base} (API /full metadata.webhook_url / registry / chain fallback)"
      fi
    elif a2a_resolve_peers_by_token_id_enabled; then
      echo "    (API /full and on-chain metadata.webhook_url lookup failed — check IDENTYCLAW_BASE_URL, NEAR creds, passport)" >&2
    fi
    a2a_fetch_peer_agent_card "$from_id" "$peer_token_id" || failed=1
    echo ""
  else
    echo "==> Skip peer discovery (no A2A_PEER_AGENTS / IDENTYCLAW_PEER_TOKEN_ID)"
    echo ""
  fi

  if [[ "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    echo "==> Discovery: local ${from_id}"
    a2a_fetch_agent_card "$from_id" "$from_id" || failed=1
    echo ""

    echo "==> Inbound auth probe: POST /a2a without Authorization"
    a2a_probe_unauth_post "$from_id" || failed=1
  fi
  if [[ -n "$peer_token_id" ]]; then
    local peer_a2a_url peer_resolver_dir
    peer_resolver_dir="$(agent_home "$from_id")"
    peer_a2a_url="$(a2a_peer_a2a_endpoint_url "$peer_token_id" "$peer_resolver_dir")"
    [[ -n "$peer_a2a_url" ]] && a2a_probe_unauth_post_url "peer:${peer_token_id}" "$peer_a2a_url" || failed=1
  fi

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "A2A smoke: passed (discovery + inbound auth probe)."
  else
    echo "A2A smoke: not-passed (see output above)." >&2
    return 1
  fi
  if [[ -n "$peer_token_id" ]]; then
    echo "For end-to-end RODiT messaging, run:"
    echo "  $0 test-a2a-messaging ${from_id} ${peer_token_id}"
  fi
}

cmd_test_a2a_auth() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local target container creds ext_dir failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  else
    peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  fi
  require_agent_running "$local_id"

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || {
    echo "Failed to copy lib-rodit-env.mjs into ${container}" >&2
    return 1
  }
  podman_cp_lib_test_report "$container" || {
    echo "Failed to copy lib-test-report.mjs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-a2a-rodit-auth.mjs" "$container:/tmp/test-a2a-rodit-auth.mjs" >/dev/null

  if [[ -n "$peer_token_id" ]]; then
    target="$(a2a_peer_public_base_url_with_retry "$peer_token_id" "$(agent_home "$local_id")")"
    [[ -n "$target" ]] || {
      if a2a_resolve_peers_by_token_id_enabled; then
        echo "No URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed" >&2
      else
        echo "No URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
      fi
      return 1
    }
    echo "==> A2A RODiT auth (→ peer token_id=${peer_token_id} at ${target})"
    echo "    P2P login at peer /api/login, then POST /a2a"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-rodit-auth.mjs \
      --ext-dir "$ext_dir" --creds "$creds" --target "$target" || failed=1
    echo ""
  fi

  if [[ "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    target="$(agent_a2a_public_base_url "$local_id")"
    [[ -n "$target" ]] || target="$(agent_ingress_base_url "$local_id")"
    [[ -n "$target" ]] || {
      echo "No ingress URL for local ${local_id}" >&2
      return 1
    }
    echo "==> A2A RODiT auth (→ local ${local_id} at ${target})"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-rodit-auth.mjs \
      --ext-dir "$ext_dir" --creds "$creds" --target "$target" || failed=1
  fi

  return "$failed"
}

cmd_test_auth_boundaries() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local target peer_target container creds ext_dir failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  else
    peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  fi
  require_agent_running "$local_id"

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || {
    echo "Failed to copy lib-rodit-env.mjs into ${container}" >&2
    return 1
  }
  podman_cp_lib_test_report "$container" || {
    echo "Failed to copy lib-test-report.mjs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-inter-agent-auth-boundaries.mjs" \
    "$container:/tmp/test-inter-agent-auth-boundaries.mjs" >/dev/null

  target="$(agent_a2a_public_base_url "$local_id")"
  [[ -n "$target" ]] || target="$(agent_ingress_base_url "$local_id")"
  [[ -n "$target" ]] || {
    echo "No ingress URL for local ${local_id}" >&2
    return 1
  }

  peer_target=""
  if [[ -n "$peer_token_id" ]]; then
    peer_target="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$local_id")")"
  fi

  echo "==> Inter-agent auth boundaries (channel isolation + mutual P2P binding)"
  echo "    local=${target}${peer_target:+, peer=${peer_target}}"
  local -a boundary_args=(
    --ext-dir "$ext_dir"
    --creds "$creds"
    --local "$target"
  )
  if [[ -n "$peer_target" ]]; then
    boundary_args+=(--peer "$peer_target")
  fi
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-inter-agent-auth-boundaries.mjs \
    "${boundary_args[@]}" || failed=1
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
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
    return 0
  fi
  url="$(agent_webhook_url "$id" hooks/wake)"
  container="$(agent_container "$id")"
  if ! constitution_suite_skipped webhook; then
    echo "==> Webhook ingress probe: POST /hooks/wake without RODiT signature"
    echo "    POST ${url}"
    echo "    Senders sign at origin via @rodit/rodit-auth-be: x-signature + x-timestamp (see clienttest-idc)"
    code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$url" \
      -H 'Content-Type: application/json' \
      -d '{"text":"identyclaw smoke"}')"
    case "$code" in
      400|401) echo "passed  POST /hooks/wake without RODiT signature — HTTP ${code}" ;;
      404)
        echo "not-passed  POST /hooks/wake without RODiT signature — HTTP 404 (route not exposed)" >&2
        exit 1
        ;;
      *)
        echo "not-passed  POST /hooks/wake without RODiT signature — HTTP ${code} (stack requires 400 or 401)" >&2
        exit 1
        ;;
    esac
  else
    echo "==> Skip webhook ingress smoke (CONSTITUTION_SKIP_SUITES includes webhook)"
  fi

  creds="$(agent_near_credentials_for_tests "$id")"
  if ! _agent_container_name_running "$container"; then
    [[ -n "$creds" ]] || {
      echo "skipped: agent not running and no near-credentials — skipping outbound/testhola webhook suites" >&2
      return 1
    }
  fi

  local peer_token_id="" cross_peer
  peer_token_id="$(resolve_peer_token_id "$id" 2>/dev/null || true)"
  if [[ -n "$peer_token_id" ]] && _agent_container_name_running "$container"; then
    local peer_base container_creds deploy_id peer_local_base
    cross_peer="$(resolve_local_cross_agent_peer_token_id "$id" 2>/dev/null || true)"
    if [[ -n "$cross_peer" && "$peer_token_id" == "$cross_peer" ]]; then
      echo "    (outbound smoke peer: same-host cross-agent ${peer_token_id})"
    fi
    peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")")"
    deploy_id="$(find_deploy_id_for_token_id "$peer_token_id" 2>/dev/null || true)"
    if [[ -n "$deploy_id" ]]; then
      local peer_local_base
      peer_local_base="$(agent_container_ingress_base_url "$deploy_id" 2>/dev/null || true)"
      [[ -z "$peer_local_base" ]] && peer_local_base="$(agent_a2a_public_base_url "$deploy_id" 2>/dev/null || true)"
      [[ -n "$peer_local_base" ]] && peer_base="$peer_local_base"
    fi
    container_creds="$(agent_near_credentials_for_tests "$id")"
    if [[ -n "$peer_base" && -n "$container_creds" ]]; then
      echo ""
      echo "==> Outbound: send_rodit_webhook smoke (${id} → ${peer_token_id})"
      podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
      podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node -e "
        import { runOutboundWebhookToPeer } from 'file:///tmp/lib-rodit-webhook-test.mjs';
        const r = await runOutboundWebhookToPeer({
          localId: '${id}',
          peerId: '${peer_token_id}',
          localCredsPath: '${container_creds}',
          peerBase: '${peer_base}',
          markerPrefix: 'test-webhook-outbound',
          delaySeconds: 0,
        });
        const ok = r.deliveredOk && r.peerReceivedOk;
        process.stdout.write((r.deliveredOk ? 'passed' : 'not-passed') + '  send_rodit_webhook to peer — ' + r.deliveredDetail + '\n');
        process.stdout.write((r.peerReceivedOk ? 'passed' : 'not-passed') + '  GET peer /hooks/_receipts — ' + r.peerReceivedDetail + '\n');
        process.exit(ok ? 0 : 1);
      " || failed=1
    fi
  fi

  if [[ "${SKIP_TESTHOLA:-0}" == 1 ]]; then
    echo ""
    echo "==> Skip /api/testhola webhook delivery (SKIP_TESTHOLA=1)"
    return "$failed"
  fi

  echo ""
  echo "==> /api/testhola webhook delivery (IdentyClaw API → agent webhook_url)"
  echo "    Same pattern as clienttest-idc: valid HOLA triggers signed webhooks to /hooks/wake and /hooks/agent"
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
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-webhooks-testhola.mjs \
      --ext-dir "$ext_dir" \
      --creds "$container_creds" \
      --agent-base "$(agent_container_ingress_base_url "$id")" \
      "${api_base_args[@]}" || failed=1
  elif [[ -n "$creds" ]]; then
    NODE_TLS_REJECT_UNAUTHORIZED=0 node "${IDENTYCLAW_ROOT}/scripts/test-webhooks-testhola.mjs" \
      --ext-dir "$(agent_a2a_ext_dir "$(agent_home "$id")")" \
      --creds "$creds" \
      --agent-base "$(agent_ingress_base_url "$id")" \
      "${api_base_args[@]}" || failed=1
  fi
  return "$failed"
}

cmd_send_rodit_webhook() {
  local id="${1:?Usage: $0 send-rodit-webhook agent-c <peer-token-id> [message]}"
  local peer_token_id="${2:?Usage: $0 send-rodit-webhook agent-c <peer-token-id> [message]}"
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

cmd_test_webhook_p2p() {
  local sender peer_token_id
  require_podman
  load_env
  sender="${1:-$(resolve_local_agent_id)}"
  peer_token_id="${2:-}"
  if [[ -z "$peer_token_id" ]]; then
    peer_token_id="$(resolve_peer_token_id "$sender" 2>/dev/null || true)"
    [[ -n "$peer_token_id" ]] || {
      echo "No peer token_id in A2A_PEER_AGENTS for ${sender} — set IDENTYCLAW_PEER_TOKEN_ID or pass token_id" >&2
      return 1
    }
  fi
  is_passport_token_id "$peer_token_id" || {
    echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
    return 1
  }
  require_agent_running "$sender"

  local sender_container sender_creds receiver_base local_base peer_creds ext_dir
  local receiver_deploy_id reverse_via_container=0 local_receiver_base
  sender_container="$(agent_container "$sender")"
  receiver_base="$(a2a_peer_public_base_url_with_retry "$peer_token_id" "$(agent_home "$sender")")"
  receiver_deploy_id="$(find_deploy_id_for_token_id "$peer_token_id" 2>/dev/null || true)"
  if [[ -n "$receiver_deploy_id" ]]; then
    local_receiver_base="$(agent_container_ingress_base_url "$receiver_deploy_id" 2>/dev/null || true)"
    [[ -z "$local_receiver_base" ]] && local_receiver_base="$(agent_a2a_public_base_url "$receiver_deploy_id" 2>/dev/null || true)"
    [[ -n "$local_receiver_base" ]] && receiver_base="$local_receiver_base"
  fi
  local_base="$(agent_container_ingress_base_url "$sender")"
  [[ -n "$local_base" ]] || local_base="$(agent_a2a_public_base_url "$sender")"
  [[ -n "$local_base" ]] || local_base="$(agent_ingress_base_url "$sender")"
  [[ -n "$receiver_base" ]] || {
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "No URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed" >&2
    else
      echo "No URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
    fi
    return 1
  }

  sender_creds="$(agent_near_credentials_for_tests "$sender")"
  [[ -n "$sender_creds" ]] || {
    echo "No NEAR credentials for ${sender} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }

  peer_creds="$(peer_near_credentials_path "$peer_token_id")"
  local receiver_container
  if [[ -n "$receiver_deploy_id" ]]; then
    receiver_container="$(agent_container "$receiver_deploy_id")"
    if podman ps --format '{{.Names}}' | grep -qx "$receiver_container"; then
      reverse_via_container=1
    fi
  fi

  podman_cp_lib_test_report "$sender_container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$sender_container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-webhooks-p2p-suite.mjs" "$sender_container:/tmp/test-webhooks-p2p-suite.mjs" >/dev/null

  local sender_token_id
  sender_token_id="$(agent_token_id "$sender")"
  [[ -n "$sender_token_id" ]] || {
    echo "Cannot resolve Passport token_id for ${sender} — probe NEAR creds / IDENTITYCLAW.md" >&2
    return 1
  }

  echo "==> P2P webhook test (outbound + inbound via send_rodit_webhook)"
  echo "    Outbound: ${sender} (${sender_token_id}) delivers → peer token_id=${peer_token_id} records"
  echo "    Inbound:  peer delivers → ${sender} (${sender_token_id}) records"

  local -a exec_args=(
    node /tmp/test-webhooks-p2p-suite.mjs
    --local "$sender_token_id"
    --peer "$peer_token_id"
    --local-creds "$sender_creds"
    --local-base "$local_base"
    --peer-base "$receiver_base"
    --path hooks/wake
  )
  [[ -n "$sender_token_id" ]] && exec_args+=(--local-token-id "$sender_token_id")
  if [[ -n "${WEBHOOK_P2P_INBOUND_POLL_TIMEOUT_MS:-}" ]]; then
    exec_args+=(--poll-timeout-ms "$WEBHOOK_P2P_INBOUND_POLL_TIMEOUT_MS")
  fi

  if [[ "$reverse_via_container" -eq 1 ]]; then
    exec_args+=(--skip-inbound)
  elif [[ -n "$peer_creds" && "${WEBHOOK_P2P_SIMULATE_INBOUND:-}" == 1 ]]; then
    podman cp "$peer_creds" "$sender_container:/tmp/peer-inbound-creds.json" >/dev/null
    exec_args+=(--simulate-inbound --peer-creds /tmp/peer-inbound-creds.json)
  else
    echo "    Inbound: live peer at ${receiver_base} via A2A message/send (P2P login → send_rodit_webhook at origin)"
  fi

  local smoke_responder_pids=()
  if [[ "$reverse_via_container" -ne 1 ]] && [[ "${WEBHOOK_P2P_SIMULATE_INBOUND:-}" != 1 ]]; then
    local smoke_id
    for smoke_id in $AGENT_IDS; do
      if agent_container_running "$smoke_id"; then
        echo "    Inbound: polling ${smoke_id} A2A webhook smoke responder during live peer test"
        (
          while true; do
            respond_a2a_webhook_smoke_one "$smoke_id" >/dev/null 2>&1 || true
            sleep "${WEBHOOK_P2P_SMOKE_POLL_SEC:-2}"
          done
        ) &
        smoke_responder_pids+=("$!")
      fi
    done
  fi

  local exit_code=0
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" "${exec_args[@]}" || exit_code=$?

  if [[ ${#smoke_responder_pids[@]} -gt 0 ]]; then
    local pid
    for pid in "${smoke_responder_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    for smoke_id in $AGENT_IDS; do
      respond_a2a_webhook_smoke_one "$smoke_id" >/dev/null 2>&1 || true
    done
  fi

  if [[ "$reverse_via_container" -eq 1 && -n "$local_base" && -n "$receiver_deploy_id" ]]; then
    echo ""
    echo "--- Inbound: we receive webhooks from peer (${receiver_deploy_id} container) ---"
    local receiver_creds marker send_out verify_script
    receiver_creds="$(agent_near_credentials_in_container "$receiver_deploy_id")"
    [[ -n "$receiver_creds" ]] || {
      echo "not-passed  peer send_rodit_webhook to local gateway — no NEAR creds in ${receiver_deploy_id} container" >&2
      return 1
    }
    marker="inbound-${peer_token_id}-to-${sender}-$(date +%s)"
    podman cp "${IDENTYCLAW_ROOT}/scripts/send-rodit-webhook.mjs" "$receiver_container:/tmp/send-rodit-webhook.mjs" >/dev/null
    podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$sender_container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" node -e "
      import { clearReceipts } from 'file:///tmp/lib-rodit-webhook-test.mjs';
      await clearReceipts('${local_base}');
    " >/dev/null
    if [[ -n "$sender_token_id" ]]; then
    send_out="$(podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$receiver_container" node /tmp/send-rodit-webhook.mjs \
      --peer "$sender_token_id" --text "$marker" --delay 0 --creds "$receiver_creds" 2>&1)" || true
    if echo "$send_out" | grep -q '"ok": true'; then
      echo "passed  peer send_rodit_webhook to local gateway — $(echo "$send_out" | grep -o '"requestId": "[^"]*"' | head -1)"
    else
      echo "not-passed  peer send_rodit_webhook to local gateway — ${send_out}" >&2
      exit_code=1
    fi
    verify_script="$(mktemp)"
    cat >"$verify_script" <<NODE
import { verifyWebhookReceipt } from "file:///tmp/lib-rodit-webhook-test.mjs";
const r = await verifyWebhookReceipt("${local_base}", { marker: "${marker}" });
process.stdout.write((r.receiptOk ? "passed" : "not-passed") + "  GET local /hooks/_receipts — " + r.receiptDetail + "\\n");
process.exit(r.receiptOk ? 0 : 1);
NODE
    podman cp "$verify_script" "$sender_container:/tmp/verify-webhook-receipt.mjs" >/dev/null
    rm -f "$verify_script"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" node /tmp/verify-webhook-receipt.mjs || exit_code=1
    fi
  fi

  return "$exit_code"
}

cmd_test_peer_gateway() {
  cmd_test_unit
}

cmd_test_unit() {
  echo "==> Unit tests (repo-local, no Podman)"
  node "${IDENTYCLAW_ROOT}/scripts/test-unit-all.mjs"
}

cmd_test_a2a_messaging() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local container creds ext_dir peer_base failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  [[ -n "$peer_token_id" ]] || {
    echo "test-a2a-messaging requires a peer token_id (A2A_PEER_AGENTS)" >&2
    return 1
  }
  if peer_shares_local_gateway_base "$local_id" "$peer_token_id"; then
    echo "==> Skip test-a2a-messaging (peer ${peer_token_id} shares gateway with ${local_id})"
    return 0
  fi
  require_agent_running "$local_id"

  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$local_id")")"
  [[ -n "$peer_base" ]] || {
    echo "No peer base URL for token_id ${peer_token_id}" >&2
    return 1
  }

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id}" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || return 1
  podman_cp_lib_test_report "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-a2a-messaging-e2e.mjs" "$container:/tmp/test-a2a-messaging-e2e.mjs" >/dev/null

  echo "==> A2A messaging E2E (local=${local_id} → peer ${peer_token_id} at ${peer_base})"
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-messaging-e2e.mjs \
    --ext-dir "$ext_dir" --creds "$creds" --peer-base "$peer_base" || failed=1
  return "$failed"
}

cmd_test_all_peers() {
  local local_id peer_token_id peers failed=0
  load_env
  local_id="$(resolve_local_agent_id)"
  peers="$(resolve_live_peer_token_ids "$local_id" 2>/dev/null || true)"
  echo "==> Test constitution — all live remote peers (local=${local_id})"
  echo "    AGENT_IDS=${AGENT_IDS} (excluded from peer targets)"
  echo "    live peers (registry-resolved, deduped by gateway base)=${peers:-none}"
  echo ""

  cmd_test_peer_gateway || failed=1
  echo ""
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
  else
    cmd_test_webhook "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped mail; then
    echo "==> Skip test-mail (CONSTITUTION_SKIP_SUITES includes mail)"
  else
    cmd_test_mail "$local_id" || failed=1
  fi

  if [[ -z "$peers" ]]; then
    echo ""
    echo "==> Skip peer suites (no remote A2A peers — local AGENT_IDS entries are excluded)"
  else
    for peer_token_id in $peers; do
      echo ""
      echo "========================================"
      echo "=== PEER ${peer_token_id} ==="
      echo "========================================"
      if peer_shares_local_gateway_base "$local_id" "$peer_token_id"; then
        echo "==> Skip A2A suites for peer ${peer_token_id} (same gateway as ${local_id}; local suites cover this ingress)"
        echo ""
      else
        if constitution_suite_skipped a2a; then
          echo "==> Skip test-a2a for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a)"
        else
          cmd_test_a2a "$local_id" "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped a2a-auth; then
          echo "==> Skip test-a2a-auth for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
        else
          cmd_test_a2a_auth "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped a2a-messaging; then
          echo "==> Skip test-a2a-messaging for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a-messaging)"
        else
          cmd_test_a2a_messaging "$local_id" "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped auth-boundaries; then
          echo "==> Skip test-auth-boundaries for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
        else
          cmd_test_auth_boundaries "$peer_token_id" || failed=1
        fi
        echo ""
      fi
      if constitution_suite_skipped webhook-p2p; then
        echo "==> Skip test-webhook-p2p for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes webhook-p2p)"
      else
        cmd_test_webhook_p2p "$local_id" "$peer_token_id" || failed=1
      fi
      if constitution_suite_skipped mail-hola; then
        echo ""
        echo "==> Skip test-mail-hola for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes mail-hola)"
      elif peer_mail_hola_ambiguous "$local_id" "$peer_token_id"; then
        echo ""
        echo "==> Skip test-mail-hola for peer ${peer_token_id} (shares this host's pod ingress; HOLA peerTokenId binding is ambiguous)"
      else
        echo ""
        cmd_test_mail_hola "$local_id" "$peer_token_id" || failed=1
      fi
    done
  fi

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites (all peers): passed"
  else
    echo "Constitution suites (all peers): not-passed (see output above)" >&2
  fi
  return "$failed"
}

print_agent_test_candidates() {
  local id="$1" self_token local_email configured_peers api_peers all_peers peer_token_id
  local probed_json a2a_base peer_email mode source primary_peer constitution_mode
  load_env
  is_valid_agent_id "$id" || return 1
  self_token="$(agent_token_id "$id" 2>/dev/null || true)"
  local_email="$(agent_env_value "$id" EMAIL "")"
  configured_peers="$(a2a_remote_peer_token_ids)"
  all_peers="$(a2a_discovered_test_candidate_token_ids)"
  primary_peer="$(resolve_peer_token_id "$id" 2>/dev/null || true)"

  echo "==> ${id} (token_id=${self_token:-unknown}, email=${local_email:-none})"
  if [[ -z "$all_peers" ]]; then
    echo "    test candidates: (none — no remote peers in A2A_PEER_AGENTS or GET /api/agents)"
    echo "    constitution mode: local-only (self a2a + webhooks + mail IMAP; no cross-agent peer)"
    return 0
  fi

  for peer_token_id in $all_peers; do
    if a2a_peer_token_id_is_configured "$peer_token_id"; then
      source="configured"
    else
      source="api"
    fi
    if [[ "$source" == "api" ]]; then
      a2a_base=""
      peer_email=""
      probed_json="$(probe_test_candidate_peer_json "$id" "$peer_token_id" 2>/dev/null || true)"
      if [[ -n "$probed_json" ]]; then
        read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
      fi
      [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
      if [[ -n "$a2a_base" ]]; then
        mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
        echo "    candidate ${peer_token_id} [${source}]: mode=${mode} a2a=${a2a_base} peer_email=${peer_email:-—}"
      else
        echo "    candidate ${peer_token_id} [${source}]: listed via GET /api/agents (no live gateway URL yet)"
      fi
      continue
    fi
    a2a_base=""
    peer_email=""
    probed_json="$(probe_test_candidate_peer_json "$id" "$peer_token_id" 2>/dev/null || true)"
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
    mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    echo "    candidate ${peer_token_id} [${source}]: mode=${mode} a2a=${a2a_base:-—} peer_email=${peer_email:-—}"
  done

  if [[ -n "$primary_peer" ]]; then
    probed_json="$(probe_test_candidate_peer_json "$id" "$primary_peer" 2>/dev/null || true)"
    a2a_base=""
    peer_email=""
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$primary_peer" "$(agent_home "$id")" 2>/dev/null || true)"
    constitution_mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    if a2a_peer_token_id_is_configured "$primary_peer"; then
      source="configured"
    else
      source="api"
    fi
    echo "    constitution peer: ${primary_peer} [${source}] → mode=${constitution_mode}"
  fi
}

print_test_peer_roster() {
  local id configured_peers all_peers api_base api_count cross_peers
  load_env
  configured_peers="$(a2a_remote_peer_token_ids)"
  all_peers="$(a2a_discovered_test_candidate_token_ids)"
  cross_peers="$(local_cross_agent_peer_token_ids "$(resolve_local_agent_id)" 2>/dev/null || true)"
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  api_count="$(fetch_identyclaw_api_peer_token_ids 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('tokenIds') or []))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
  echo "==> Test candidates per agent"
  echo "    AGENT_IDS (local):       ${AGENT_IDS}"
  echo "    A2A_PEER_AGENTS:       ${A2A_PEER_AGENTS:-none}"
  echo "    same-host cross-agent:   ${cross_peers:-none} (preferred for outbound P2P webhooks)"
  echo "    A2A_TEST_EXCLUDE_PEERS:  ${A2A_TEST_EXCLUDE_PEERS:-none}"
  echo "    A2A_TEST_ONLY_PEERS:     ${A2A_TEST_ONLY_PEERS:-none}"
  echo "    CONSTITUTION_SKIP_SUITES: ${CONSTITUTION_SKIP_SUITES:-none}"
  echo "    webhooks pin (local):    ${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN} (peer receivers must match)"
  echo "    configured remote peers: ${configured_peers:-none}"
  if a2a_discover_peers_from_api_enabled; then
    echo "    API discovery:           GET ${api_base:-api.identyclaw.com}/api/agents (${api_count} token_ids, public; webhook_url needs auth /full)"
  else
    echo "    API discovery:           off (set IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1)"
  fi
  echo "    total candidates:        $(echo "$all_peers" | wc -w | tr -d ' ') (configured + api, deduped)"
  echo ""
  for id in $AGENT_IDS; do
    print_agent_test_candidates "$id" || true
    echo ""
  done
}

cmd_test_candidates() {
  load_env
  echo "==> Constitution test candidates"
  echo ""
  print_test_peer_roster
}

cmd_test_constitution_for_agent() {
  local local_id="$1"
  local failed=0 peers peer base local_email peer_email a2a_base constitution_mode
  local peer_count=0
  load_env
  is_valid_agent_id "$local_id" || {
    echo "Invalid agent id: ${local_id}" >&2
    return 1
  }
  print_constitution_agent_preflight "$local_id"

  # All live remote peers (registry-resolved, deduped by gateway base) — test every one.
  peers="$(resolve_live_peer_token_ids "$local_id" 2>/dev/null || true)"
  local_email="$(agent_env_value "$local_id" EMAIL "")"
  echo "==> Test constitution (local=${local_id})"
  if [[ -n "$peers" ]]; then
    echo "    live peers detected:"
    for peer in $peers; do
      base="$(a2a_peer_public_base_url "$peer" "$(agent_home "$local_id")" 2>/dev/null || true)"
      echo "      - ${peer} → ${base:-unresolved}"
      peer_count=$((peer_count + 1))
    done
  else
    echo "    live peers detected: none (local-only run)"
  fi
  echo ""

  # --- Local coverage (once, peer-independent) ---
  echo "======== LOCAL SUITES (${local_id}) ========"
  if constitution_suite_skipped a2a; then
    echo "==> Skip test-a2a (CONSTITUTION_SKIP_SUITES includes a2a)"
  else
    CONSTITUTION_LOCAL_ONLY=1 cmd_test_a2a "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped a2a-auth; then
    echo "==> Skip test-a2a-auth (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
  else
    CONSTITUTION_LOCAL_ONLY=1 cmd_test_a2a_auth "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
  else
    cmd_test_webhook "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped mail; then
    echo "==> Skip test-mail (CONSTITUTION_SKIP_SUITES includes mail)"
  else
    cmd_test_mail "$local_id" || failed=1
  fi

  if [[ -z "$peers" ]]; then
    echo ""
    if constitution_suite_skipped auth-boundaries; then
      echo "==> Skip test-auth-boundaries (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
    else
      CONSTITUTION_LOCAL_ONLY=1 cmd_test_auth_boundaries "$local_id" || failed=1
    fi
    echo ""
    echo "==> Skip peer suites (no live remote peers detected)"
    echo ""
    if [[ $failed -eq 0 ]]; then
      echo "Constitution suites (${local_id}): passed"
    else
      echo "Constitution suites (${local_id}): not-passed (see output above)" >&2
    fi
    return "$failed"
  fi

  # --- Per-peer coverage (every live peer detected) ---
  for peer in $peers; do
    base="$(a2a_peer_public_base_url "$peer" "$(agent_home "$local_id")" 2>/dev/null || true)"
    peer_email=""
    a2a_base=""
    local probed_json peer_shares_gateway=0
    probed_json="$(probe_test_candidate_peer_json "$local_id" "$peer" 2>/dev/null || true)"
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$base"
    if peer_shares_local_gateway_base "$local_id" "$peer"; then
      peer_shares_gateway=1
      a2a_base=""
    fi
    constitution_mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    echo ""
    echo "======== PEER ${peer} (${base:-unresolved}) — from ${local_id} [mode=${constitution_mode}] ========"
    if [[ $peer_shares_gateway -eq 1 ]]; then
      echo "==> Skip A2A suites for peer ${peer} (same gateway as ${local_id}; local suites cover this ingress)"
      echo ""
    else
      if constitution_suite_skipped a2a; then
        echo "==> Skip test-a2a for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a)"
      else
        CONSTITUTION_PEER_ONLY=1 cmd_test_a2a "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped a2a-auth; then
        echo "==> Skip test-a2a-auth for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
      else
        CONSTITUTION_PEER_ONLY=1 cmd_test_a2a_auth "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped a2a-messaging; then
        echo "==> Skip test-a2a-messaging for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a-messaging)"
      elif peer_shares_local_gateway_base "$local_id" "$peer"; then
        echo "==> Skip test-a2a-messaging for peer ${peer} (same gateway as ${local_id})"
      else
        cmd_test_a2a_messaging "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped auth-boundaries; then
        echo "==> Skip test-auth-boundaries for peer ${peer} (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
      else
        cmd_test_auth_boundaries "$local_id" "$peer" || failed=1
      fi
      echo ""
    fi
    if constitution_suite_skipped webhook-p2p; then
      echo "==> Skip test-webhook-p2p for peer ${peer} (CONSTITUTION_SKIP_SUITES includes webhook-p2p)"
    else
      cmd_test_webhook_p2p "$local_id" "$peer" || failed=1
    fi
    if constitution_suite_skipped mail-hola; then
      echo ""
      echo "==> Skip test-mail-hola for peer ${peer} (CONSTITUTION_SKIP_SUITES includes mail-hola)"
    elif peer_mail_hola_ambiguous "$local_id" "$peer"; then
      echo ""
      echo "==> Skip test-mail-hola for peer ${peer} (shares this host's pod ingress; HOLA peerTokenId binding is ambiguous)"
    else
      echo ""
      cmd_test_mail_hola "$local_id" "$peer" || failed=1
    fi
  done

  echo ""
  echo "==> Constitution peer coverage (${local_id}): ${peer_count} live peer(s) tested"
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites (${local_id}): passed"
  else
    echo "Constitution suites (${local_id}): not-passed (see output above)" >&2
  fi
  return "$failed"
}

cmd_test() {
  local local_id="${1:-}" peer_token_id="" failed=0
  load_env
  if [[ -n "$local_id" ]] && ! is_valid_agent_id "$local_id"; then
    echo "Usage: $0 test [agent-id]" >&2
    return 1
  fi
  local_id="${local_id:-$(resolve_local_agent_id)}"
  peer_token_id="$(resolve_peer_token_id "$local_id" 2>/dev/null || true)"
  echo "==> Test constitution (local=${local_id}${peer_token_id:+, peer token_id=${peer_token_id}})"
  echo "    AGENT_IDS=${AGENT_IDS}"
  echo "    A2A_PEER_AGENTS=${A2A_PEER_AGENTS}"
  echo ""

  cmd_test_unit || failed=1
  echo ""
  cmd_test_constitution_for_agent "$local_id" || failed=1

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites: passed"
  else
    echo "Constitution suites: not-passed (see output above)" >&2
  fi
  return "$failed"
}

cmd_test_all_agents() {
  local id failed=0 agent_failed=0
  local -a results=()
  require_podman
  require_rootless_user
  load_env

  echo "==> Test constitution — all agents on this host"
  echo ""

  local missing_mail_pw
  missing_mail_pw="$(constitution_agents_missing_mail_password)"
  if [[ -n "$missing_mail_pw" ]]; then
    echo "==> Preflight not-passed: missing Migadu mailbox password for:${missing_mail_pw}" >&2
    echo "    Run: ./identyclaw.sh set-password <agent-id> for each, then re-run test-all-agents" >&2
    return 1
  fi
  echo "==> Preflight: Migadu passwords present for all AGENT_IDS"
  echo ""

  echo "==> Start agents in AGENT_IDS"
  for id in $AGENT_IDS; do
    if agent_container_running "$id"; then
      echo "    ${id}: already running"
    else
      echo "    ${id}: starting..."
      start_one "$id" || failed=1
    fi
  done
  [[ $failed -eq 0 ]] || {
    echo "Start failed for one or more agents — fix before running constitution suites" >&2
    return 1
  }
  echo ""

  echo "==> Sync A2A config (ensure outbound peers + public base, even when already running)"
  for id in $AGENT_IDS; do
    ensure_a2a_config "$id" "$(agent_home "$id")" "$(agent_container "$id")" || true
  done
  echo ""

  print_test_peer_roster
  echo ""

  cmd_test_peer_gateway || failed=1
  echo ""

  for id in $AGENT_IDS; do
    echo "########################################"
    echo "### AGENT ${id}"
    echo "########################################"
    echo ""
    agent_failed=0
    cmd_test_constitution_for_agent "$id" || agent_failed=1
    if [[ $agent_failed -eq 0 ]]; then
      results+=("${id}: passed")
    else
      results+=("${id}: not-passed")
      failed=1
    fi
    echo ""
  done

  echo "========================================"
  echo "==> Constitution summary (all agents)"
  for line in "${results[@]}"; do
    echo "    ${line}"
  done
  echo "========================================"
  if [[ $failed -eq 0 ]]; then
    echo "All constitution suites: passed"
  else
    echo "All constitution suites: not-passed (see per-agent output above)" >&2
  fi
  return "$failed"
}

cmd_test_all_agents_chat() {
  local id constitution_failed=0 chat_failed=0
  local -a chat_results=()
  require_podman
  require_rootless_user
  load_env

  echo "==> Full test run — constitution suites + chat peer discovery (all agents)"
  echo ""

  cmd_test_all_agents || constitution_failed=1
  echo ""
  echo "========================================"
  echo "==> Chat-driven peer discovery (A2A + email)"
  echo "========================================"
  echo ""

  for id in $AGENT_IDS; do
    require_agent_running "$id"
    echo "########################################"
    echo "### CHAT TEST ${id}"
    echo "########################################"
    echo ""
    if cmd_ask "$id" "$(agent_chat_peer_discovery_test_prompt "$id")"; then
      chat_results+=("${id}: chat passed")
    else
      chat_results+=("${id}: chat not-passed")
      chat_failed=1
    fi
    echo ""
  done

  echo "========================================"
  echo "==> Chat peer-discovery summary"
  for line in "${chat_results[@]}"; do
    echo "    ${line}"
  done
  echo "========================================"
  if [[ $constitution_failed -eq 0 && $chat_failed -eq 0 ]]; then
    echo "All tests (constitution + chat): passed"
    return 0
  fi
  echo "Tests not-passed (constitution=${constitution_failed}, chat=${chat_failed})" >&2
  return 1
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
  echo "API key stored for ${id} (auth-profiles.json)"
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
  echo "API key stored for ${id} (opencode + opencode-go auth-profiles.json)"
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
    enable-slc-heartbeat) cmd_enable_slc_heartbeat "$@" ;;
    fix-session-images) cmd_fix_session_images "$@" ;;
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
    token) cmd_token "$@" ;;
    cache-stats) cmd_cache_stats "$@" ;;
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
