#!/usr/bin/env bash
# A2A peer resolution, Passport/NEAR credentials, and IdentyClaw plugins.
# Sourced from scripts/lib.sh — do not execute directly.

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
  local container="${2:-}"
  local env_file use_container_env key="NODE_TLS_REJECT_UNAUTHORIZED" value="0"
  container="$(agent_container_for_config_dir "$config_dir" "$container")"
  read -r use_container_env env_file <<<"$(agent_env_write_context "$config_dir" "$container" | tr '\t' ' ')"
  if [[ "$use_container_env" != "1" ]]; then
    [[ -f "$env_file" ]] || return 0
  fi
  if a2a_tls_skip_verify_enabled; then
    _agent_env_python "$config_dir" "$container" "$use_container_env" "$env_file" "$key" "$value" <<'PY'
import os, sys
from pathlib import Path

env_file, key, value = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
prefix = f"{key}="
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(prefix)]
lines.append(f"{key}={value}\n")
env_file.parent.mkdir(parents=True, exist_ok=True)
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
  else
    _agent_env_python "$config_dir" "$container" "$use_container_env" "$env_file" "$key" <<'PY'
import os, sys
from pathlib import Path

env_file, key = Path(sys.argv[1]), sys.argv[2]
prefix = f"{key}="
if not env_file.is_file():
    raise SystemExit(0)
lines = [ln for ln in env_file.read_text(encoding="utf-8").splitlines(keepends=True) if not ln.startswith(prefix)]
env_file.parent.mkdir(parents=True, exist_ok=True)
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
  fi
}

# Extra podman -e flags for gateway containers (rodit-auth-be fetch to self-signed peer TLS).

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
  local spec="$1" ver
  [[ "$spec" == *@* ]] || return 0
  ver="${spec##*@}"
  # Semver pins only (clawhub/npm). git:@main / SHAs are not package versions.
  [[ "$ver" =~ ^[0-9] ]] || return 0
  echo "$ver"
}


a2a_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    podman exec "$container" rm -rf \
      /home/node/.openclaw/extensions/a2a \
      /home/node/.openclaw/.a2a-plugin-build 2>/dev/null || true
    return 0
  fi
  rm -rf "$config_dir/extensions/a2a" "$config_dir/.a2a-plugin-build" 2>/dev/null || true
}

# openclaw.json lives on the host under -app but may only be writable inside the running container.


agent_near_cred_path_for_config_sync() {
  local config_dir="$1"
  local container="${2:-}"
  local cred=""
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if agent_env_use_container "$config_dir" "$container"; then
    _agent_near_cred_path_in_container "$container"
    return 0
  fi
  cred="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f -readable 2>/dev/null | head -1)"
  [[ -n "$cred" ]] && echo "$cred"
}


sync_agent_plugin_configs() {
  local id="$1"
  local config_dir="$2"
  local container
  container="$(agent_container "$id")"
  ensure_identyclaw_config "$config_dir" "$container" || return 1
  ensure_bearer_http_plugin_config "$config_dir" "$container" || return 1
  if agent_has_near_credentials "$config_dir" "$container"; then
    ensure_a2a_config "$id" "$config_dir" "$container" || return 1
    ensure_webhooks_plugin_config "$config_dir" "$container" || return 1
  fi
}

# Host path: per-agent NEAR Passport JSON (canonical layout for peer coordination).
agent_near_credentials_dir() {
  echo "$(agent_home "$1")/secrets/near-credentials"
}


agent_near_credentials_host_path() {
  local id="$1"
  local cred_dir active_file active_id candidate
  cred_dir="$(agent_near_credentials_dir "$id")"
  active_file="$cred_dir/.active"
  if [[ -f "$active_file" ]]; then
    active_id="$(tr -d '[:space:]' <"$active_file" 2>/dev/null || true)"
    if [[ -n "$active_id" && -f "$cred_dir/${active_id}.json" ]]; then
      echo "$cred_dir/${active_id}.json"
      return 0
    fi
  fi
  find "$cred_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1 || true
}

# Read token_id from host cache written by probe_rodit_own_token_id (no podman/node).
cached_rodit_own_token_id_for_agent() {
  local id="$1"
  local config_dir cache cached_id
  config_dir="$(agent_home "$id")"
  cache="$config_dir/.rodit-own-token-id"
  [[ -f "$cache" ]] || return 1
  read -r _ cached_id <"$cache" || return 1
  cached_id="${cached_id//$'\n'/}"
  cached_id="${cached_id//$'\r'/}"
  [[ -n "$cached_id" ]] || return 1
  is_passport_token_id "$cached_id" || return 1
  echo "$cached_id"
}

# Passport token_ids for agents in AGENT_IDS on this host (container probe when host cannot read secrets).
local_host_agent_token_ids() {
  local id tid out=""
  load_env
  for id in $AGENT_IDS; do
    tid="$(cached_rodit_own_token_id_for_agent "$id" 2>/dev/null || true)"
    [[ -n "$tid" ]] || tid="$(agent_token_id "$id" 2>/dev/null || true)"
    [[ -n "$tid" ]] || continue
    if [[ -z "$out" ]]; then
      out="$tid"
    else
      out="$out $tid"
    fi
  done
  if [[ -z "$out" ]]; then
    echo ""
    return 0
  fi
  printf '%s\n' $out | LC_ALL=C sort | paste -sd' ' -
}

# True when token_id belongs to an agent in AGENT_IDS on this host.

# True when token_id belongs to an agent in AGENT_IDS on this host.
a2a_peer_token_id_on_this_host() {
  local token_id="$1" local_tid
  [[ -n "$token_id" ]] || return 1
  for local_tid in $(local_host_agent_token_ids); do
    [[ "$local_tid" == "$token_id" ]] && return 0
  done
  return 1
}

# Passport token_ids from A2A_PEER_AGENTS that are not deployed on this host (remote A2A peers).

# Passport token_ids from A2A_PEER_AGENTS that are not deployed on this host (remote A2A peers).
a2a_remote_peer_token_ids() {
  local ref out=""
  load_env
  for ref in $A2A_PEER_AGENTS; do
    is_passport_token_id "$ref" || continue
    a2a_peer_token_id_on_this_host "$ref" && continue
    if [[ -z "$out" ]]; then
      out="$ref"
    else
      out="$out $ref"
    fi
  done
  echo "$out"
}

# Public agent registry at GET /api/agents (same as identyclaw_list_agents tool).
# Default off — deploy/bootstrap must stay fast; enable for discover-a2a-peers / tests.

# Public agent registry at GET /api/agents (same as identyclaw_list_agents tool).
# Default off — deploy/bootstrap must stay fast; enable for discover-a2a-peers / tests.
a2a_discover_peers_from_api_enabled() {
  load_env
  [[ "${IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API:-0}" == "1" ]]
}

# JSON line: {"tokenIds":[...],"apiBase":"...","pages":N} — excludes local AGENT_IDS token_ids.

# Merge configured remote A2A_PEER_AGENTS + GET /api/agents (deduped, local excluded).
a2a_merged_remote_peer_token_ids() {
  local configured api_json tid out="" seen=""
  load_env
  configured="$(a2a_remote_peer_token_ids)"
  for tid in $configured; do
    [[ -n "$tid" ]] || continue
    if [[ " $seen " != *" $tid "* ]]; then
      seen="${seen:+$seen }$tid"
      out="${out:+$out }$tid"
    fi
  done
  if a2a_discover_peers_from_api_enabled; then
    api_json="$(fetch_identyclaw_api_peer_token_ids 2>/dev/null || true)"
    if [[ -n "$api_json" ]]; then
      while IFS= read -r tid; do
        [[ -n "$tid" ]] || continue
        if [[ " $seen " != *" $tid "* ]]; then
          seen="${seen:+$seen }$tid"
          out="${out:+$out }$tid"
        fi
      done < <(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for tid in d.get('tokenIds') or []:
    print(tid)
" "$api_json")
    fi
  fi
  echo "$out"
}

# True when a constitution suite name is listed in CONSTITUTION_SKIP_SUITES (space-separated).
# Suite tokens: a2a, a2a-auth, a2a-messaging, auth-boundaries, webhook, webhook-all, webhook-p2p, mail, mail-hola.
# Legacy: SKIP_MAIL_HOLA=1 also skips mail-hola.

# Passport token_ids for other AGENT_IDS on this host (cross-agent, not self).
local_cross_agent_peer_token_ids() {
  local local_deploy_id="${1:-$(resolve_local_agent_id)}"
  local id own_tid tid out=""
  load_env
  own_tid="$(agent_token_id "$local_deploy_id" 2>/dev/null || true)"
  for id in $AGENT_IDS; do
    [[ "$id" == "$local_deploy_id" ]] && continue
    tid="$(agent_token_id "$id" 2>/dev/null || true)"
    [[ -n "$tid" ]] || continue
    [[ "$tid" == "$own_tid" ]] && continue
    a2a_peer_token_id_excluded_from_tests "$tid" && continue
    out="${out:+$out }$tid"
  done
  echo "$out"
}

# First running cross-agent on this host with a resolvable ingress base (webhooks 0.1.5 path).

# File cache (not bash vars): start/restart all share one live peer map — avoid N×
# GET /api/agents. Keyed by API base + probe settings + AGENT_IDS (not probed
# exclude token_ids, which flake during restart). Fixed filename (not $$): subshells
# from $(...) must read/write the same files.
_live_api_peers_cache_base() {
  local dir
  dir="$(identyclaw_app_dir)/.cache"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "${dir}/live-api-peers"
}

# Stable cache key for API peer discovery (identical for every agent on this host).
_live_api_peers_cache_key() {
  local api_base="$1" concurrency="$2" timeout_ms="$3"
  local agents
  load_env
  agents="$(configured_agent_ids | tr ' ' '\n' | LC_ALL=C sort | paste -sd' ' -)"
  printf '%s|%s|%s|%s' "$api_base" "$concurrency" "$timeout_ms" "$agents"
}

_live_api_peers_cache_get() {
  local cache_key="$1"
  local base="${2:-$(_live_api_peers_cache_base)}"
  [[ -f "${base}.key" && -f "${base}.json" ]] || return 1
  [[ "$(cat "${base}.key" 2>/dev/null || true)" == "$cache_key" ]] || return 1
  cat "${base}.json"
}

_live_api_peers_cache_set() {
  local cache_key="$1"
  local json="$2"
  local base="${3:-$(_live_api_peers_cache_base)}"
  mkdir -p "$(dirname "$base")" 2>/dev/null || true
  printf '%s' "$cache_key" >"${base}.key"
  printf '%s' "$json" >"${base}.json"
}

# Probe GET /api/agents, resolve /full + chain URLs, keep peers with live agent-card.
discover_live_api_peers_json_for_agent() {
  local id="$1"
  local config_dir cred ext_dir container api_base probed_json tid
  local concurrency timeout_ms cache_key
  [[ -n "$id" ]] || return 1
  a2a_discover_peers_from_api_enabled || return 0
  load_env
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  agent_has_near_credentials "$config_dir" "$container" || return 0
  api_base="$(identyclaw_api_base_url_for_config_dir "$config_dir" 2>/dev/null || true)"
  [[ -n "$api_base" ]] || api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"

  local -a exclude_args=()
  for tid in $(local_host_agent_token_ids); do
    [[ -n "$tid" ]] || continue
    exclude_args+=(--exclude "$tid")
  done

  concurrency="${IDENTYCLAW_A2A_DISCOVER_CONCURRENCY:-12}"
  timeout_ms="${IDENTYCLAW_A2A_DISCOVER_TIMEOUT_MS:-8000}"
  cache_key="$(_live_api_peers_cache_key "$api_base" "$concurrency" "$timeout_ms")"
  local cached=""
  cached="$(_live_api_peers_cache_get "$cache_key" 2>/dev/null || true)"
  if [[ -n "$cached" ]]; then
    echo "    (${id}: reusing cached API peer discovery)" >&2
    printf '%s' "$cached"
    return 0
  fi

  cred="$(agent_near_credentials_host_path "$id" 2>/dev/null || true)"
  ext_dir="$(agent_a2a_ext_dir "$config_dir" 2>/dev/null || true)"
  if [[ -n "$cred" && -d "$ext_dir" ]] && command -v node >/dev/null 2>&1; then
    local -a discover_args=(
      node "${IDENTYCLAW_ROOT}/scripts/discover-live-api-peers.mjs"
      "$ext_dir" "$cred"
      --concurrency "$concurrency"
      --timeout-ms "$timeout_ms"
    )
    [[ -n "$api_base" ]] && discover_args+=(--api-base "$api_base")
    discover_args+=("${exclude_args[@]}")
    probed_json="$(
      NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
        NODE_TLS_REJECT_UNAUTHORIZED=0 \
        "${discover_args[@]}" 2>/dev/null || true
    )"
  else
    container="$(agent_container "$id")"
    _agent_container_name_running "$container" || return 0
    cred="$(agent_near_credentials_in_container "$id" 2>/dev/null || true)"
    ext_dir="$(a2a_api_probe_ext_dir_container "$container" 2>/dev/null || true)"
    [[ -n "$cred" && -n "$ext_dir" ]] || return 0
    podman_cp_lib_rodit_env "$container" || return 1
    podman cp "${IDENTYCLAW_ROOT}/scripts/lib-discover-agents.mjs" \
      "$container:/tmp/lib-discover-agents.mjs" >/dev/null 2>&1 || return 1
    podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-gateway-url.mjs" \
      "$container:/tmp/lib-peer-gateway-url.mjs" >/dev/null 2>&1 || return 1
    podman cp "${IDENTYCLAW_ROOT}/scripts/discover-live-api-peers.mjs" \
      "$container:/tmp/discover-live-api-peers.mjs" >/dev/null 2>&1 || return 1
    local -a discover_args=(
      node /tmp/discover-live-api-peers.mjs "$ext_dir" "$cred"
      --concurrency "$concurrency"
      --timeout-ms "$timeout_ms"
    )
    [[ -n "$api_base" ]] && discover_args+=(--api-base "$api_base")
    discover_args+=("${exclude_args[@]}")
    probed_json="$(
      podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
        -e NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
        "$container" \
        "${discover_args[@]}" 2>/dev/null || true
    )"
  fi
  [[ -n "$probed_json" && "$probed_json" == \{* ]] || {
    echo "{}"
    return 0
  }
  # Rodit structured logs may precede JSON on stdout — keep the last JSON object line.
  probed_json="$(printf '%s' "$probed_json" | python3 -c "
import json, sys
text = sys.stdin.read()
for line in reversed(text.splitlines()):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if isinstance(obj, dict):
        print(json.dumps(obj, separators=(',', ':')))
        break
" 2>/dev/null || true)"
  [[ -n "$probed_json" && "$probed_json" == \{* ]] || {
    echo "{}"
    return 0
  }
  _live_api_peers_cache_set "$cache_key" "$probed_json"
  printf '%s' "$probed_json"
}

# Merge two outbound.agents JSON objects from files (second wins on key collision).
# File-based I/O avoids ARG_MAX when API discovery returns thousands of peers.

# Merge two outbound.agents JSON objects from files (second wins on key collision).
# File-based I/O avoids ARG_MAX when API discovery returns thousands of peers.
merge_a2a_peer_json_maps_files() {
  local primary_file="$1"
  local secondary_file="$2"
  python3 - "$primary_file" "$secondary_file" <<'PY'
import json, sys
from pathlib import Path

def load_obj(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8") or "{}")
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}

primary = load_obj(sys.argv[1])
secondary = load_obj(sys.argv[2])
merged = dict(primary)
merged.update(secondary)
print(json.dumps(merged, separators=(",", ":")))
PY
}

# True when token_id came from A2A_PEER_AGENTS (remote configured peer).

# True when token_id came from A2A_PEER_AGENTS (remote configured peer).
a2a_peer_token_id_is_configured() {
  local token_id="$1" ref
  [[ -n "$token_id" ]] || return 1
  load_env
  for ref in $A2A_PEER_AGENTS; do
    is_passport_token_id "$ref" || continue
    a2a_peer_token_id_on_this_host "$ref" && continue
    [[ "$ref" == "$token_id" ]] && return 0
  done
  return 1
}

# First remote A2A peer Passport token_id from A2A_PEER_AGENTS.
# Precedence: CLI arg → IDENTYCLAW_PEER_TOKEN_ID → first remote A2A_PEER_AGENTS entry.
# Skips any token_id deployed in AGENT_IDS on this host.

# Remote A2A peer token_ids (excludes any Passport deployed in AGENT_IDS on this host).
a2a_peer_token_ids_excluding_local() {
  a2a_remote_peer_token_ids
}

# True when POST /a2a without auth returns 401/403 (gateway alive, auth enforced).

# True when POST /a2a without auth returns 401/403 (gateway alive, auth enforced).
a2a_probe_endpoint_reachable() {
  local base="$1"
  local code resolve_args=()
  [[ -n "$base" ]] || return 1
  base="${base%/}"
  command -v curl >/dev/null 2>&1 || return 1
  while IFS= read -r resolve_arg; do
    [[ -n "$resolve_arg" ]] && resolve_args+=("$resolve_arg")
  done < <(agent_ingress_curl_resolve_args_for_base "$base" 2>/dev/null || true)
  code="$(
    curl -sk "${resolve_args[@]}" -o /dev/null -w '%{http_code}' \
      --max-time "${A2A_PROBE_TIMEOUT:-8}" \
      -X POST "${base}/a2a" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"probe","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"probe"}],"messageId":"probe"}}}' \
      2>/dev/null || echo "000"
  )"
  [[ "$code" == "401" || "$code" == "403" ]]
}

# curl --resolve when base host matches a local agent public host (multi-host self-tests).

# curl --resolve when base host matches a local agent public host (multi-host self-tests).
agent_ingress_curl_resolve_args_for_base() {
  local base="$1" id host port
  load_env
  [[ -n "$base" ]] || return 0
  for id in $AGENT_IDS; do
    host="$(agent_public_host "$id")"
    port="$(agent_ingress_port "$id")"
    [[ -n "$host" && -n "$port" ]] || continue
    if [[ "$base" == *"${host}:${port}"* ]]; then
      printf '%s\n' --resolve "${host}:${port}:127.0.0.1"
      return 0
    fi
  done
}

# Probe external agent-card reachability (HTTP status + brief detail).

# Probe external agent-card reachability (HTTP status + brief detail).
a2a_probe_agent_card_status() {
  local base="$1"
  local code resolve_args=()
  [[ -n "$base" ]] || { echo "missing-base"; return 1; }
  base="${base%/}"
  command -v curl >/dev/null 2>&1 || { echo "no-curl"; return 1; }
  while IFS= read -r resolve_arg; do
    [[ -n "$resolve_arg" ]] && resolve_args+=("$resolve_arg")
  done < <(agent_ingress_curl_resolve_args_for_base "$base" 2>/dev/null || true)
  code="$(
    curl -sk "${resolve_args[@]}" -o /dev/null -w '%{http_code}' \
      --max-time "${A2A_PROBE_TIMEOUT:-8}" \
      "${base}/.well-known/agent-card.json" 2>/dev/null || echo "000"
  )"
  echo "$code"
  [[ "$code" == "200" ]]
}

# Normalized gateway base URLs (protocol//host[:port], trailing slash stripped) for a local
# agent. A discovered peer that resolves to one of these shares the agent's own gateway (self
# or a co-located agent behind the same ingress), so it is not a real cross-gateway peer and
# is skipped — the agent still gets its local coverage instead of the run aborting on self.

# Normalized gateway base URLs (protocol//host[:port], trailing slash stripped) for a local
# agent. A discovered peer that resolves to one of these shares the agent's own gateway (self
# or a co-located agent behind the same ingress), so it is not a real cross-gateway peer and
# is skipped — the agent still gets its local coverage instead of the run aborting on self.
local_agent_gateway_bases() {
  local id="$1" b out=""
  for b in \
    "$(agent_container_ingress_base_url "$id" 2>/dev/null || true)" \
    "$(agent_a2a_public_base_url "$id" 2>/dev/null || true)" \
    "$(agent_ingress_base_url "$id" 2>/dev/null || true)"; do
    b="${b%/}"
    [[ -n "$b" ]] || continue
    [[ " $out " == *" $b "* ]] && continue
    out="${out:+$out }$b"
  done
  echo "$out"
}

# True when a peer's registry-resolved gateway base matches any base for local_id (same ingress).

# True when a peer's registry-resolved gateway base matches any base for local_id (same ingress).
peer_shares_local_gateway_base() {
  local local_id="$1" peer_token_id="$2"
  local local_bases peer_base config_dir
  [[ -n "$local_id" && -n "$peer_token_id" ]] || return 1
  config_dir="$(agent_home "$local_id")"
  local_bases="$(local_agent_gateway_bases "$local_id")"
  [[ -n "$local_bases" ]] || return 1
  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$config_dir" 2>/dev/null || true)"
  [[ -n "$peer_base" ]] || return 1
  peer_base="${peer_base%/}"
  [[ " $local_bases " == *" $peer_base "* ]]
}

# host[:port] from a gateway base URL (scheme and path stripped).

# host[:port] from a gateway base URL (scheme and path stripped).
gateway_base_host_port() {
  local url="${1%/}"
  [[ -n "$url" ]] || return 1
  url="${url#*://}"
  url="${url%%/*}"
  [[ -n "$url" ]] || return 1
  echo "$url"
}

# True when two gateway host:port pairs hit the same pod nginx (multi-agent subdomain layout).
# e.g. peer https://john.dihola.io:8443 vs local https://agent-a.john.dihola.io:8443.

# True when two gateway host:port pairs hit the same pod nginx (multi-agent subdomain layout).
# e.g. peer https://john.dihola.io:8443 vs local https://agent-a.john.dihola.io:8443.
gateway_host_on_same_pod_ingress() {
  local peer_hp="$1" local_hp="$2"
  local peer_host="${peer_hp%%:*}" peer_port="${peer_hp#*:}"
  local local_host="${local_hp%%:*}" local_port="${local_hp#*:}"
  [[ -n "$peer_host" && -n "$local_host" && -n "$peer_port" && -n "$local_port" ]] || return 1
  [[ "$peer_port" == "$local_port" ]] || return 1
  [[ "$peer_host" == "$local_host" ]] && return 0
  [[ "$local_host" == "$peer_host" || "$local_host" == *".$peer_host" ]] && return 0
  load_env
  [[ -n "${IDENTYCLAW_INGRESS_ALT_HOST:-}" && "$peer_host" == "$IDENTYCLAW_INGRESS_ALT_HOST" ]] && return 0
  return 1
}

# Email HOLA peerTokenId binding is unreliable when the peer shares this host's pod ingress
# (exact URL match, co-located Passport, or parent/alt hostname on the same listen port).

# Email HOLA peerTokenId binding is unreliable when the peer shares this host's pod ingress
# (exact URL match, co-located Passport, or parent/alt hostname on the same listen port).
peer_mail_hola_ambiguous() {
  local local_id="$1" peer_token_id="$2"
  local config_dir peer_base peer_hp id b local_hp deploy_id
  [[ -n "$local_id" && -n "$peer_token_id" ]] || return 1
  load_env
  a2a_peer_token_id_on_this_host "$peer_token_id" && return 0
  deploy_id="$(find_deploy_id_for_token_id "$peer_token_id" 2>/dev/null || true)"
  [[ -n "$deploy_id" ]] && return 0
  config_dir="$(agent_home "$local_id")"
  for id in $AGENT_IDS; do
    peer_shares_local_gateway_base "$id" "$peer_token_id" && return 0
  done
  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$config_dir" 2>/dev/null || true)"
  [[ -n "$peer_base" ]] || return 1
  peer_hp="$(gateway_base_host_port "${peer_base%/}")"
  [[ -n "$peer_hp" ]] || return 1
  for id in $AGENT_IDS; do
    for b in $(local_agent_gateway_bases "$id"); do
      local_hp="$(gateway_base_host_port "$b")"
      [[ -n "$local_hp" ]] || continue
      gateway_host_on_same_pod_ingress "$peer_hp" "$local_hp" && return 0
    done
  done
  return 1
}

# Agents in AGENT_IDS missing secrets/imap.pass (blocks test-mail and email HOLA).

# Primary local gateway base (first resolved) — used to detect peers that resolve to our own
# ingress (e.g. an alternate token_id registered to this agent).
agent_own_gateway_base_url() {
  local id="$1" bases
  bases="$(local_agent_gateway_bases "$id")"
  [[ -n "$bases" ]] || return 1
  echo "${bases%% *}"
}

# Default peer for smoke tests. Precedence: local cross-agent (same-host webhooks 0.1.5),
# then first remote candidate whose /a2a is auth-gated. Skips A2A_TEST_EXCLUDE_PEERS.

# curl --resolve for local HTTPS ingress (host + in-container probes; pod nginx on loopback).
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

# Probe/test .mjs scripts import ./lib-rodit-env.mjs — copy beside them at /tmp in containers.


probe_rodit_own_owner_id_in_container() {
  local container="$1"
  local cred ext_dir probed
  [[ -n "$container" ]] || return 1
  _agent_container_name_running "$container" || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || return 1
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

# Own passport owner_id — inbound P2P JWT audience (Phase 9).

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
  # Use mtime:size (no spaces) — space-delimited keys break read(1) cache hits.
  cred_stat="$(stat -c '%Y:%s' "$cred_file" 2>/dev/null || stat -f '%m:%z' "$cred_file" 2>/dev/null || true)"
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

# True when ref is a Passport token_id (12-char), not a deployment slug like agent-a.
is_passport_token_id() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || return 1
  [[ "$ref" == agent-* ]] && return 1
  [[ "$ref" =~ ^[A-Za-z][A-Za-z0-9]{11}$ ]]
}

# Own passport token_id — canonical A2A peer identity (12-char Passport ID).

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
  # Use mtime:size (no spaces) — space-delimited keys break read(1) cache hits.
  cred_stat="$(stat -c '%Y:%s' "$cred_file" 2>/dev/null || stat -f '%m:%z' "$cred_file" 2>/dev/null || true)"
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

# Resolve Passport token_id for a local deployment slug (AGENT_IDS only — not for A2A_PEER_AGENTS).
probe_rodit_own_token_id_in_container() {
  local container="$1"
  local cred ext_dir probed
  [[ -n "$container" ]] || return 1
  _agent_container_name_running "$container" || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/probe-rodit-own-token-id.mjs" "$container:/tmp/probe-rodit-own-token-id.mjs" >/dev/null 2>&1 || return 1
  probed="$(
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
      -e NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
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
  local config_dir probed container cached
  config_dir="$(agent_home "$deploy_id")"
  cached="$(cached_rodit_own_token_id_for_agent "$deploy_id" 2>/dev/null || true)"
  [[ -n "$cached" ]] && { echo "$cached"; return 0; }
  probed="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  [[ -n "$probed" ]] && { echo "$probed"; return 0; }
  container="$(agent_container "$deploy_id" 2>/dev/null || true)"
  probe_rodit_own_token_id_in_container "$container" 2>/dev/null || true
}

# Chat prompt: discover remote peers via API and exercise A2A + email cross-agent tests.

# Map token_id → local deployment slug when this host runs that Passport (AGENT_IDS / agents/).
find_deploy_id_for_token_id() {
  local token_id="$1" id config_dir probed app_dir entry
  [[ -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  load_env
  for id in $(configured_agent_ids); do
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

# Plugin ext dir for peer probe: a2a preferred (API client + @rodit/rodit-auth-be for chain fallback).
a2a_api_probe_ext_dir() {
  local config_dir="$1"
  local tools_dir a2a_dir
  a2a_dir="$(agent_a2a_ext_dir "$config_dir")"
  if [[ -f "$a2a_dir/node_modules/@rodit/rodit-auth-be/package.json" \
    && -f "$a2a_dir/dist/auth/identyclaw-api-client.js" ]]; then
    echo "$a2a_dir"
    return 0
  fi
  if [[ -f "$a2a_dir/node_modules/@rodit/rodit-auth-be/package.json" ]]; then
    echo "$a2a_dir"
    return 0
  fi
  tools_dir="$(agent_identyclaw_tools_ext_dir "$config_dir")"
  if [[ -f "$tools_dir/node_modules/@rodit/rodit-auth-be/package.json" ]]; then
    echo "$tools_dir"
    return 0
  fi
  return 1
}


a2a_api_probe_ext_dir_container() {
  local container="$1"
  local tools_dir a2a_dir
  [[ -n "$container" ]] && _agent_container_name_running "$container" || return 1
  a2a_dir="$(agent_a2a_ext_dir_container)"
  if podman exec "$container" test -f "$a2a_dir/node_modules/@rodit/rodit-auth-be/package.json" \
    -a -f "$a2a_dir/dist/auth/identyclaw-api-client.js" 2>/dev/null; then
    echo "$a2a_dir"
    return 0
  fi
  if podman exec "$container" test -f "$a2a_dir/node_modules/@rodit/rodit-auth-be/package.json" 2>/dev/null; then
    echo "$a2a_dir"
    return 0
  fi
  tools_dir="$(agent_identyclaw_tools_ext_dir_container)"
  if podman exec "$container" test -f "$tools_dir/node_modules/@rodit/rodit-auth-be/package.json" 2>/dev/null; then
    echo "$tools_dir"
    return 0
  fi
  return 1
}


probe_identyclaw_peer_public_base_url_in_container() {
  local container="$1"
  local token_id="$2"
  local cred ext_dir probed
  [[ -n "$container" && -n "$token_id" ]] || return 1
  _agent_container_name_running "$container" || return 1
  is_passport_token_id "$token_id" || return 1
  a2a_resolve_peers_by_token_id_enabled || return 1
  cred="$(podman exec "$container" sh -c 'ls /home/node/.openclaw/secrets/near-credentials/*.json 2>/dev/null | head -1' || true)"
  [[ -n "$cred" ]] || return 1
  ext_dir="$(a2a_api_probe_ext_dir_container "$container")" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-gateway-url.mjs" \
    "$container:/tmp/lib-peer-gateway-url.mjs" >/dev/null 2>&1 || return 1
  podman_cp_lib_rodit_env "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/probe-identyclaw-peer-base-url.mjs" \
    "$container:/tmp/probe-identyclaw-peer-base-url.mjs" >/dev/null 2>&1 || return 1
  load_env
  probed="$(
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
      -e NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
      "$container" \
      node /tmp/probe-identyclaw-peer-base-url.mjs "$ext_dir" "$cred" "$token_id" 2>/dev/null || true
  )"
  probed="${probed//$'\n'/}"
  probed="${probed//$'\r'/}"
  [[ -n "$probed" && "$probed" == https://* ]] || return 1
  echo "$probed"
}

# Public base from persisted A2A plugin registry (resolvePeersByTokenId / inbound JWT).

# Public base from persisted A2A plugin registry (resolvePeersByTokenId / inbound JWT).
a2a_peer_public_base_from_registry() {
  local token_id="$1"
  local config_dir="${2:-}"
  [[ -n "$token_id" && -n "$config_dir" ]] || return 1
  local registry="$config_dir/a2a/outbound/peers.json"
  [[ -f "$registry" ]] || return 1
  A2A_PEER_TOKEN_ID="$token_id" A2A_PEER_REGISTRY_PATH="$registry" python3 - <<'PY'
import json, os, sys
from pathlib import Path
from urllib.parse import urlparse

token_id = os.environ["A2A_PEER_TOKEN_ID"]
path = Path(os.environ["A2A_PEER_REGISTRY_PATH"])
try:
    registry = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(1)

entry = registry.get(token_id)
card_url = ""
if isinstance(entry, dict):
    card_url = str(entry.get("url") or entry.get("loginBaseUrl") or "").strip()
else:
    card_url = str(entry or "").strip()
if not card_url:
    sys.exit(1)
if card_url.endswith("/.well-known/agent-card.json"):
    base = card_url[: -len("/.well-known/agent-card.json")].rstrip("/")
elif "://" in card_url:
    parsed = urlparse(card_url)
    base = f"{parsed.scheme}://{parsed.netloc}".rstrip("/") if parsed.netloc else card_url.rstrip("/")
else:
    base = card_url.rstrip("/")
if base:
    print(base)
PY
}

# IdentyClaw API /full metadata.webhook_url, then on-chain RODiT fallback (NEAR creds + rodit-auth-be).

# IdentyClaw API /full metadata.webhook_url, then on-chain RODiT fallback (NEAR creds + rodit-auth-be).
probe_identyclaw_peer_public_base_url() {
  local config_dir="$1"
  local token_id="$2"
  local cred_file ext_dir probed deploy_id container
  [[ -n "$config_dir" && -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  a2a_resolve_peers_by_token_id_enabled || return 1
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  ext_dir="$(a2a_api_probe_ext_dir "$config_dir" 2>/dev/null || true)"
  if [[ -n "$cred_file" && -f "$cred_file" && -n "$ext_dir" ]] && command -v node >/dev/null 2>&1; then
    load_env
    probed="$(
      NEAR_CONTRACT_ID="${IDENTYCLAW_NEAR_CONTRACT_ID:-genaaaa-identyclaw-com.near}" \
        node "${IDENTYCLAW_ROOT}/scripts/probe-identyclaw-peer-base-url.mjs" \
        "$ext_dir" "$cred_file" "$token_id" 2>/dev/null || true
    )"
    probed="${probed//$'\n'/}"
    probed="${probed//$'\r'/}"
    if [[ -n "$probed" && "$probed" == https://* ]]; then
      echo "$probed"
      return 0
    fi
  fi
  deploy_id="$(find_deploy_id_for_config_dir "$config_dir" 2>/dev/null || true)"
  if [[ -n "$deploy_id" ]]; then
    container="$(agent_container "$deploy_id" 2>/dev/null || true)"
    probe_identyclaw_peer_public_base_url_in_container "$container" "$token_id" 2>/dev/null || true
  fi
}


a2a_peer_public_base_url_from_env_map() {
  local token_id="$1"
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

# Peer ingress from AGENT_{letter}_* when that letter is not in AGENT_IDS (split-host layout).

# Peer ingress from AGENT_{letter}_* when that letter is not in AGENT_IDS (split-host layout).
a2a_peer_public_base_from_env_slot() {
  local token_id="$1"
  local peer_ref="" p letter id url host port
  load_env
  [[ -n "$token_id" ]] || return 1
  peer_ref="${IDENTYCLAW_PEER_TOKEN_ID:-}"
  if [[ -z "$peer_ref" ]]; then
    for p in $A2A_PEER_AGENTS; do
      is_passport_token_id "$p" || continue
      peer_ref="$p"
      break
    done
  fi
  [[ "$token_id" == "$peer_ref" ]] || return 1
  for letter in a b c d e f g h; do
    id="agent-${letter}"
    agent_is_local "$id" && continue
    url="$(agent_env_value "$id" A2A_PUBLIC_BASE_URL "")"
    if [[ -n "$url" ]]; then
      echo "${url%/}"
      return 0
    fi
    host="$(agent_env_value "$id" PUBLIC_HOST "")"
    port="$(agent_env_value "$id" INGRESS_PORT "")"
    [[ -z "$port" ]] && port="${IDENTYCLAW_INGRESS_PORT:-}"
    if [[ -n "$host" && -n "$port" ]]; then
      echo "https://${host}:${port}"
      return 0
    fi
  done
  return 1
}

# Fast peer URL sources only (no IdentyClaw API /full, no per-peer Passport RPC).
# Used at deploy/bootstrap. Full discovery belongs in tests / discover-a2a-peers.

# Fast peer URL sources only (no IdentyClaw API /full, no per-peer Passport RPC).
# Used at deploy/bootstrap. Full discovery belongs in tests / discover-a2a-peers.
a2a_peer_public_base_url_static() {
  local token_id="$1"
  local resolver_config_dir="${2:-}"
  local public_base
  [[ -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  public_base="$(a2a_peer_public_base_url_from_env_map "$token_id" 2>/dev/null || true)"
  [[ -n "$public_base" ]] && { echo "$public_base"; return 0; }
  if [[ -n "$resolver_config_dir" ]]; then
    public_base="$(a2a_peer_public_base_from_registry "$token_id" "$resolver_config_dir" 2>/dev/null || true)"
    [[ -n "$public_base" ]] && { echo "$public_base"; return 0; }
  fi
  public_base="$(a2a_peer_public_base_from_env_slot "$token_id" 2>/dev/null || true)"
  [[ -n "$public_base" ]] && { echo "$public_base"; return 0; }
  return 1
}

# Public HTTPS base for a peer token_id (static → local deploy → API /full).
# Prefer a2a_peer_public_base_url_static at deploy; use this from tests / discover-a2a-peers.

# Public HTTPS base for a peer token_id (static → local deploy → API /full).
# Prefer a2a_peer_public_base_url_static at deploy; use this from tests / discover-a2a-peers.
a2a_peer_public_base_url() {
  local token_id="$1"
  local resolver_config_dir="${2:-}"
  local deploy_id public_base
  [[ -n "$token_id" ]] || return 1
  is_passport_token_id "$token_id" || return 1
  public_base="$(a2a_peer_public_base_url_static "$token_id" "$resolver_config_dir" 2>/dev/null || true)"
  [[ -n "$public_base" ]] && { echo "$public_base"; return 0; }
  deploy_id="$(find_deploy_id_for_token_id "$token_id" 2>/dev/null || true)"
  if [[ -n "$deploy_id" ]]; then
    public_base="$(agent_env_value "$deploy_id" A2A_PUBLIC_BASE_URL "")"
    if [[ -z "$public_base" && "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]]; then
      public_base="$(agent_public_base_url "$deploy_id" 2>/dev/null || true)"
    fi
    [[ -z "$public_base" ]] && public_base="$(agent_a2a_public_base_url "$deploy_id" 2>/dev/null || true)"
    [[ -n "$public_base" ]] && { echo "${public_base%/}"; return 0; }
  fi
  if [[ -n "$resolver_config_dir" ]]; then
    public_base="$(probe_identyclaw_peer_public_base_url "$resolver_config_dir" "$token_id" 2>/dev/null || true)"
    [[ -n "$public_base" ]] && { echo "$public_base"; return 0; }
  fi
  return 1
}

# Retry transient API /full lookups during constitution runs (same peer often resolves on next attempt).

# Retry transient API /full lookups during constitution runs (same peer often resolves on next attempt).
a2a_peer_public_base_url_with_retry() {
  local token_id="$1"
  local resolver_config_dir="${2:-}"
  local attempts="${A2A_PEER_URL_LOOKUP_RETRIES:-3}"
  local delay_sec="${A2A_PEER_URL_LOOKUP_RETRY_SEC:-2}"
  local try=1 base=""
  while [[ $try -le $attempts ]]; do
    base="$(a2a_peer_public_base_url "$token_id" "$resolver_config_dir" 2>/dev/null || true)"
    [[ -n "$base" ]] && { echo "$base"; return 0; }
    [[ $try -lt $attempts ]] && sleep "$delay_sec"
    try=$((try + 1))
  done
  return 1
}


a2a_resolve_peers_by_token_id_enabled() {
  a2a_dynamic_peers_from_jwt_enabled
}


a2a_peer_agent_card_url() {
  local token_id="$1"
  local resolver_config_dir="${2:-}"
  local public_base
  public_base="$(a2a_peer_public_base_url "$token_id" "$resolver_config_dir")"
  [[ -n "$public_base" ]] || return 1
  echo "${public_base%/}/.well-known/agent-card.json"
}


a2a_peer_a2a_endpoint_url() {
  local token_id="$1"
  local resolver_config_dir="${2:-}"
  local public_base
  public_base="$(a2a_peer_public_base_url "$token_id" "$resolver_config_dir")"
  [[ -n "$public_base" ]] || return 1
  echo "${public_base%/}/a2a"
}

# Passport token_ids listed in A2A_PEER_AGENTS (invalid entries omitted with warning).

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

# Outbound peer registry persisted by the A2A plugin (API discovery + inbound JWT).

# Outbound peer registry persisted by the A2A plugin (API discovery + inbound JWT).
a2a_outbound_peer_registry_json() {
  local config_dir="$1"
  local registry="$config_dir/a2a/outbound/peers.json"
  [[ -f "$registry" ]] || {
    echo "{}"
    return 0
  }
  python3 - "$registry" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    print(json.dumps(data if isinstance(data, dict) else {}))
except Exception:
    print("{}")
PY
}

# Replace deprecated A2A_PEER_AGENTS token_ids with GET /api/agents registrations at
# the same gateway (e.g. Andrew lmsfckzncdbw → cfbkbhzdzflk). Configured ids still
# win when they appear in the public agent registry.

# Replace deprecated A2A_PEER_AGENTS token_ids with GET /api/agents registrations at
# the same gateway (e.g. Andrew lmsfckzncdbw → cfbkbhzdzflk). Configured ids still
# win when they appear in the public agent registry.
a2a_reconcile_peer_token_id_list() {
  local token_id_list="$1"
  local local_deploy_id="${2:-$(resolve_local_agent_id)}"
  local config_dir tid bases_json registry_json api_json
  [[ -n "$token_id_list" ]] || return 0
  load_env
  config_dir="$(agent_home "$local_deploy_id")"
  registry_json="$(a2a_outbound_peer_registry_json "$config_dir")"
  api_json="$(fetch_identyclaw_api_peer_token_ids 2>/dev/null || true)"
  [[ -n "$api_json" && "$api_json" == \{* ]] || api_json='{"tokenIds":[]}'

  local first=1 api_tid
  bases_json="{"
  for tid in $token_id_list; do
    is_passport_token_id "$tid" || continue
    local base
    base="$(a2a_peer_public_base_url "$tid" "$config_dir" 2>/dev/null || true)"
    [[ -n "$base" ]] || continue
    base="${base%/}"
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      bases_json+=","
    fi
    bases_json+="\"${tid}\":\"${base}\""
  done
  while IFS= read -r api_tid; do
    [[ -n "$api_tid" ]] || continue
    is_passport_token_id "$api_tid" || continue
    base="$(a2a_peer_public_base_url "$api_tid" "$config_dir" 2>/dev/null || true)"
    [[ -n "$base" ]] || continue
    base="${base%/}"
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      bases_json+=","
    fi
    bases_json+="\"${api_tid}\":\"${base}\""
  done < <(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for tid in d.get('tokenIds') or []:
    print(tid)
" "$api_json")
  bases_json+="}"

  A2A_RECONCILE_TIDS="$token_id_list" \
    A2A_RECONCILE_BASES="$bases_json" \
    A2A_RECONCILE_REGISTRY="$registry_json" \
    A2A_RECONCILE_API="$api_json" \
    A2A_RECONCILE_AGENT="$local_deploy_id" \
    A2A_RECONCILE_LOCAL_TIDS="$(local_host_agent_token_ids 2>/dev/null || true)" \
    python3 <<'PY'
import json, os, sys
from urllib.parse import urlparse

def norm_base(url):
    raw = str(url or "").strip().rstrip("/")
    if not raw:
        return ""
    if raw.endswith("/.well-known/agent-card.json"):
        raw = raw[: -len("/.well-known/agent-card.json")].rstrip("/")
    if "://" in raw:
        parsed = urlparse(raw)
        if parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}".rstrip("/").lower()
    return raw.lower()

def entry_base(entry):
    if isinstance(entry, dict):
        return norm_base(entry.get("loginBaseUrl") or entry.get("url") or "")
    return norm_base(entry)

try:
    bases = json.loads(os.environ.get("A2A_RECONCILE_BASES") or "{}")
except Exception:
    bases = {}
try:
    registry = json.loads(os.environ.get("A2A_RECONCILE_REGISTRY") or "{}")
except Exception:
    registry = {}
try:
    api_data = json.loads(os.environ.get("A2A_RECONCILE_API") or "{}")
except Exception:
    api_data = {}
api_tids = {str(t).lower() for t in (api_data.get("tokenIds") or []) if t}
agent = os.environ.get("A2A_RECONCILE_AGENT") or "agent"
local_live = {
    str(t).lower()
    for t in os.environ.get("A2A_RECONCILE_LOCAL_TIDS", "").split()
    if t
}

base_to_api_tid = {}
for tid, base in bases.items():
    tid = str(tid).lower()
    if tid not in api_tids:
        continue
    norm = norm_base(base)
    if norm:
        # Prefer live Passport on this host over legacy API registrations at the same gateway.
        if norm in base_to_api_tid and tid in local_live:
            base_to_api_tid[norm] = tid
        elif norm not in base_to_api_tid:
            base_to_api_tid[norm] = tid
for tid, entry in registry.items():
    tid = str(tid).lower()
    if tid not in api_tids:
        continue
    base = entry_base(entry)
    if base:
        base_to_api_tid[base] = tid

out = []
seen_bases = set()
for configured in os.environ.get("A2A_RECONCILE_TIDS", "").split():
    configured = str(configured).lower()
    if not configured:
        continue
    base = norm_base(bases.get(configured, ""))
    if configured in local_live:
        canonical = configured
    elif configured in api_tids:
        canonical = configured
    elif base and base in base_to_api_tid:
        canonical = base_to_api_tid[base]
        if canonical != configured:
            print(
                f"    ({agent}: A2A_PEER_AGENTS lists {configured} but GET /api/agents "
                f"registers {canonical} at the same gateway — using discovered token_id)",
                file=sys.stderr,
            )
    else:
        canonical = configured

    if base:
        if base in seen_bases:
            continue
        seen_bases.add(base)
    if canonical not in out:
        out.append(canonical)

print(" ".join(out))
PY
}

# Drop configured outbound.agents entries superseded by API discovery at the same gateway.

# Drop configured outbound.agents entries superseded by API discovery at the same gateway.
a2a_filter_superseded_configured_peer_map_json() {
  local api_json="$1"
  local configured_json="$2"
  A2A_FILTER_API_JSON="$api_json" A2A_FILTER_CFG_JSON="$configured_json" python3 <<'PY'
import json, os, sys
from urllib.parse import urlparse

def norm_base(url):
    raw = str(url or "").strip().rstrip("/")
    if not raw:
        return ""
    if raw.endswith("/.well-known/agent-card.json"):
        raw = raw[: -len("/.well-known/agent-card.json")].rstrip("/")
    if "://" in raw:
        parsed = urlparse(raw)
        if parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}".rstrip("/").lower()
    return raw.lower()

def peer_base(entry):
    if not isinstance(entry, dict):
        return norm_base(entry)
    return norm_base(entry.get("loginBaseUrl") or entry.get("url") or "")

try:
    api_map = json.loads(os.environ.get("A2A_FILTER_API_JSON") or "{}")
except Exception:
    api_map = {}
try:
    cfg_map = json.loads(os.environ.get("A2A_FILTER_CFG_JSON") or "{}")
except Exception:
    cfg_map = {}

api_bases = {peer_base(v): k for k, v in api_map.items() if peer_base(v)}
filtered = {}
for tid, entry in cfg_map.items():
    base = peer_base(entry)
    api_tid = api_bases.get(base)
    if api_tid and str(api_tid).lower() != str(tid).lower():
        continue
    filtered[tid] = entry
print(json.dumps(filtered, separators=(",", ":")))
PY
}


warn_invalid_a2a_peer_agents() {
  local ref
  load_env
  for ref in $A2A_PEER_AGENTS; do
    is_passport_token_id "$ref" && continue
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "    (A2A_PEER_AGENTS: \"${ref}\" is not a Passport token_id — ignored)" >&2
    else
      echo "    (A2A_PEER_AGENTS: \"${ref}\" is not a Passport token_id — ignored; set A2A_PEER_URLS for each peer)" >&2
    fi
  done
}


sync_rodit_token_id_env() {
  local config_dir="$1"
  local container="${2:-}"
  local env_file use_container_env token_id
  token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  [[ -n "$token_id" ]] || return 0
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  read -r use_container_env env_file <<<"$(agent_env_write_context "$config_dir" "$container" | tr '\t' ' ')"
  _agent_env_python "$config_dir" "$container" "$use_container_env" "$env_file" "$token_id" <<'PY'
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
  if _agent_container_name_running "$container"; then
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
  local peers_tmp agents_tmp registry_tmp peers_json
  peers_tmp="$(mktemp)"
  agents_tmp="$(mktemp)"
  registry_tmp="$(mktemp)"
  printf '%s' "$logs" >"$peers_tmp"
  printf '%s' "$agents_json" >"$agents_tmp"
  printf '%s' "$registry_json" >"$registry_tmp"
  peers_json="$(python3 - "$agents_tmp" "$registry_tmp" "$peers_tmp" "${self_token_id:-}" <<'PY'
import json, re, sys
from pathlib import Path

agents_file, registry_file, logs_file, self_token_id = sys.argv[1:5]
peers = {}
try:
    peers.update(json.loads(Path(agents_file).read_text(encoding="utf-8") or "{}"))
except Exception:
    pass

logs = Path(logs_file).read_text(encoding="utf-8")
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
    registry = json.loads(Path(registry_file).read_text(encoding="utf-8") or "{}")
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

self_token_id = self_token_id.strip()
if self_token_id:
    peers.pop(self_token_id, None)
peers = {k: v for k, v in peers.items() if k}
print(json.dumps(peers, sort_keys=True))
PY
)"
  rm -f "$peers_tmp" "$agents_tmp" "$registry_tmp"
  echo "$peers_json"
}

# Merge harvested peers into env.local (A2A_PEER_AGENTS + A2A_PEER_URLS).

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

# Harvest inbound P2P peer logins and persist to env.local.
sync_a2a_peers_from_logs() {
  local id="${1:-}"
  local peers_json updated=0
  load_env
  if [[ -z "$id" ]]; then
    for id in $(configured_agent_ids); do
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

# Passport metadata via RoditClient.getConfigOwnRodit() — webhook_url, api_base, owner_id, host, port.
probe_rodit_passport_urls_json() {
  local config_dir="$1"
  local cred_file ext_dir cache cred_stat probed cached_key cached_json
  cred_file="$(find "$config_dir/secrets/near-credentials" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$cred_file" && -f "$cred_file" ]] || return 1
  ext_dir="$(agent_a2a_ext_dir "$config_dir")"
  [[ -f "$ext_dir/node_modules/@rodit/rodit-auth-be/package.json" ]] || return 1

  load_env
  sync_quiet_plugin_env "$config_dir" "$(agent_container "${config_dir##*/}")"

  cache="$config_dir/.rodit-passport-urls.json"
  # Use mtime:size (no spaces) — space-delimited keys break read(1) cache hits.
  cred_stat="$(stat -c '%Y:%s' "$cred_file" 2>/dev/null || stat -f '%m:%z' "$cred_file" 2>/dev/null || true)"
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

# In-container path for RODiT file credentials (agent state mounted at /home/node/.openclaw).
near_credentials_container_path() {
  local account_id="$1"
  echo "/home/node/.openclaw/secrets/near-credentials/${account_id}.json"
}

# Peer NEAR creds for cross-host P2P webhook tests (private key signs, remote agent verifies).
# Accepts Passport token_id — resolves to a local agents/<deploy-id>/ dir when present.

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
  _agent_near_cred_path_in_container "$container"
}

# In-container path to the active (or first) NEAR passport JSON (empty if none / container down).

# In-container path to the active (or first) NEAR passport JSON (empty if none / container down).
_agent_near_cred_path_in_container() {
  local container="$1"
  [[ -n "$container" ]] || return 0
  _agent_container_name_running "$container" || return 0
  podman exec "$container" sh -c '
dir=/home/node/.openclaw/secrets/near-credentials
if [ -f "$dir/.active" ]; then
  active=$(tr -d "[:space:]" <"$dir/.active")
  if [ -n "$active" ] && [ -f "$dir/${active}.json" ]; then
    echo "$dir/${active}.json"
    exit 0
  fi
fi
find "$dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | head -1
' 2>/dev/null || true
}

# Constitution/test harness: in-container path when the agent is up, else readable host path.

# Constitution/test harness: in-container path when the agent is up, else readable host path.
agent_near_credentials_for_tests() {
  local id="$1"
  local config_dir container cred=""
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if _agent_container_name_running "$container"; then
    cred="$(_agent_near_cred_path_in_container "$container")"
    [[ -n "$cred" ]] && { printf '%s\n' "$cred"; return 0; }
  fi
  cred="$(resolve_near_credentials_file "$config_dir" "$container" 2>/dev/null || true)"
  [[ -n "$cred" ]] && printf '%s\n' "$cred"
}

# Prefer secrets/near-credentials/.active when present; else first *.json.
# Writes .active when exactly one credential file exists and .active is missing.

# Prefer secrets/near-credentials/.active when present; else first *.json.
# Writes .active when exactly one credential file exists and .active is missing.
ensure_near_credentials_active() {
  local config_dir="$1"
  local agent_cred_dir active_file active_id candidate count=0 sole=""
  agent_cred_dir="$config_dir/secrets/near-credentials"
  active_file="$agent_cred_dir/.active"
  [[ -d "$agent_cred_dir" ]] || return 0
  if [[ -f "$active_file" ]]; then
    active_id="$(tr -d '[:space:]' <"$active_file" 2>/dev/null || true)"
    if [[ -n "$active_id" && -f "$agent_cred_dir/${active_id}.json" ]]; then
      return 0
    fi
  fi
  for candidate in "$agent_cred_dir"/*.json; do
    [[ -f "$candidate" ]] || continue
    count=$((count + 1))
    sole="$candidate"
  done
  if [[ "$count" -eq 1 && -n "$sole" ]]; then
    printf '%s\n' "$(basename "$sole" .json)" >"$active_file" 2>/dev/null || true
    chmod 600 "$active_file" 2>/dev/null || true
  fi
}

# Resolve NEAR passport JSON for an agent (canonical: agents/<id>/secrets/near-credentials/).

# Resolve NEAR passport JSON for an agent (canonical: agents/<id>/secrets/near-credentials/).
resolve_near_credentials_file() {
  local config_dir="$1"
  local container="${2:-}"
  local agent_cred_dir candidate legacy_dir legacy_app_secrets agent_count active_file active_id
  load_env
  agent_cred_dir="$config_dir/secrets/near-credentials"
  mkdir -p "$agent_cred_dir" 2>/dev/null || true
  ensure_near_credentials_active "$config_dir"

  active_file="$agent_cred_dir/.active"
  if [[ -f "$active_file" ]]; then
    active_id="$(tr -d '[:space:]' <"$active_file" 2>/dev/null || true)"
    if [[ -n "$active_id" && -f "$agent_cred_dir/${active_id}.json" && -r "$agent_cred_dir/${active_id}.json" ]]; then
      echo "$agent_cred_dir/${active_id}.json"
      return 0
    fi
  fi

  for candidate in "$agent_cred_dir"/*.json; do
    [[ -f "$candidate" && -r "$candidate" ]] || continue
    echo "$candidate"
    return 0
  done

  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  candidate="$(_agent_near_cred_path_in_container "$container")"
  if [[ -n "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  # Legacy: per-agent peer-credentials first (never share app-level secrets across agents).
  legacy_app_secrets="$(identyclaw_app_dir)/secrets"
  legacy_dir="$legacy_app_secrets/peer-credentials/$(basename "$config_dir")"
  candidate="$(find "$legacy_dir" -maxdepth 1 -name '*.json' -type f -readable 2>/dev/null | head -1 || true)"
  if [[ -n "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  agent_count="$(configured_agent_ids | wc -w | tr -d ' ')"
  if [[ "${agent_count:-0}" -le 1 ]]; then
    for candidate in "$legacy_app_secrets"/*.json; do
      [[ -f "$candidate" && -r "$candidate" ]] || continue
      echo "$candidate"
      return 0
    done
  fi

  return 1
}

# Copy resolved creds into agents/<id>/secrets/near-credentials/ (one-way migration from legacy layouts).

# Copy resolved creds into agents/<id>/secrets/near-credentials/ (one-way migration from legacy layouts).
ensure_near_credentials_in_agent() {
  local config_dir="$1"
  local container="${2:-}"
  local cred_file agent_cred_dir account_id dest
  cred_file="$(resolve_near_credentials_file "$config_dir" "$container")" || return 1
  if [[ "$cred_file" == /home/node/* ]]; then
    return 0
  fi
  agent_cred_dir="$config_dir/secrets/near-credentials"
  account_id="$(python3 - "$cred_file" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("implicit_account_id") or data.get("account_id") or Path(sys.argv[1]).stem)
PY
)"
  dest="$agent_cred_dir/${account_id}.json"
  if [[ "$cred_file" == "$dest" ]]; then
    return 0
  fi
  if ! mkdir -p "$agent_cred_dir" 2>/dev/null; then
    [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
    if [[ -n "$(_agent_near_cred_path_in_container "$container")" ]]; then
      return 0
    fi
    return 1
  fi
  chmod 700 "$config_dir/secrets" "$agent_cred_dir" 2>/dev/null || true
  cp -a "$cred_file" "$dest"
  chmod 600 "$dest"
  echo "    ($(basename "$config_dir"): migrated NEAR creds → secrets/near-credentials/${account_id}.json)" >&2
}


agent_has_near_credentials() {
  local config_dir="$1"
  local container="${2:-}"
  resolve_near_credentials_file "$config_dir" "$container" >/dev/null 2>&1
}

# Legacy layouts used secrets/near/*.json — bootstrap expects secrets/near-credentials/.

# Legacy layouts used secrets/near/*.json — bootstrap expects secrets/near-credentials/.
ensure_near_credentials_layout() {
  local config_dir="$1"
  local cred_dir="$config_dir/secrets/near-credentials"
  local legacy_dir="$config_dir/secrets/near"
  agent_has_near_credentials "$config_dir" && {
    ensure_near_credentials_active "$config_dir"
    return 0
  }
  [[ -d "$legacy_dir" ]] || return 0
  local legacy_json
  legacy_json="$(find "$legacy_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null | head -1)"
  [[ -n "$legacy_json" ]] || return 0
  if ! mkdir -p "$cred_dir" 2>/dev/null; then
    local container="${2:-}"
    [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
    if [[ -n "$(_agent_near_cred_path_in_container "$container")" ]]; then
      return 0
    fi
    return 1
  fi
  cp -a "$legacy_dir"/*.json "$cred_dir/" 2>/dev/null || cp "$legacy_json" "$cred_dir/"
  chmod 700 "$cred_dir"
  find "$cred_dir" -maxdepth 1 -name '*.json' -type f -exec chmod 600 {} +
  ensure_near_credentials_active "$config_dir"
  echo "    ($(basename "$config_dir" | sed 's/^\.openclaw-//'): migrated secrets/near → secrets/near-credentials/)" >&2
}

# Webhook ingress uses RODiT origin signatures (@rodit/rodit-auth-be), not hooks.token / HMAC.
rodit_webhook_auth_ready() {
  local id="$1"
  local config_dir
  config_dir="$(agent_home "$id")"
  agent_has_near_credentials "$config_dir"
}


sync_identyclaw_env() {
  local config_dir="$1"
  local container="${2:-}"
  local env_file cred_file contract_id api_base near_rpc_url use_container_env
  load_env
  contract_id="${IDENTYCLAW_NEAR_CONTRACT_ID}"
  near_rpc_url="${NEAR_RPC_URL:-}"
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  ensure_near_credentials_in_agent "$config_dir" "$container" || return 0
  cred_file="$(agent_near_cred_path_for_config_sync "$config_dir" "$container")" || return 0
  [[ -n "$cred_file" ]] || return 0
  read -r use_container_env env_file <<<"$(agent_env_write_context "$config_dir" "$container" | tr '\t' ' ')"
  api_base="$(identyclaw_api_base_url_for_config_dir "$config_dir" 2>/dev/null || true)"
  [[ -n "$api_base" ]] || {
    echo "    (${config_dir##*/}: skip .env sync — no Passport api_base; set IDENTYCLAW_API_BASE_URL to override)" >&2
    return 0
  }
  _agent_env_python "$config_dir" "$container" "$use_container_env" "$cred_file" "$env_file" "$contract_id" "$api_base" "$near_rpc_url" "${IDENTYCLAW_DEPLOY_MODE:-standalone}" "${IDENTYCLAW_API_ENDPOINTS:-}" <<'PY'
import json, os, sys
from pathlib import Path

cred_file, env_file, contract_id, api_base, near_rpc_url, deploy_mode, api_endpoints = (
    Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7] if len(sys.argv) > 7 else ""
)
creds = json.loads(cred_file.read_text(encoding="utf-8"))
account_id = creds.get("implicit_account_id") or creds.get("account_id", "")
private_key = creds.get("private_key", "")
if not account_id or not private_key:
    raise SystemExit(0)

# Pod deploy passes host .env via --env-file; paths must be in-container (/home/node/.openclaw/...).
# Host filesystem paths break RODiT SDK mkdir/init when the gateway loads .env inside the container.
if str(env_file).startswith("/home/node/") or deploy_mode == "pod":
    container_cred_path = f"/home/node/.openclaw/secrets/near-credentials/{account_id}.json"
else:
    container_cred_path = str(cred_file)

strip_prefixes = (
    "IDENTYCLAW_ACCOUNT_ID=",
    "IDENTYCLAW_NEAR_PRIVATE_KEY=",
    "IDENTYCLAW_BASE_URL=",
    "IDENTYCLAW_API_ENDPOINTS=",
    "NEAR_CONTRACT_ID=",
    "NEAR_RPC_URL=",
    "RODIT_NEAR_CREDENTIALS_SOURCE=",
    "NEAR_CREDENTIALS_FILE_PATH=",
    "NEAR_CREDENTIALS_JSON_B64=",
)
lines = []
if env_file.is_file():
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(strip_prefixes)]

lines.append(f"IDENTYCLAW_BASE_URL={api_base.rstrip('/')}\n")
if api_endpoints.strip():
    lines.append(f"IDENTYCLAW_API_ENDPOINTS={api_endpoints.strip()}\n")
lines.append(f"IDENTYCLAW_ACCOUNT_ID={account_id}\n")
lines.append(f"IDENTYCLAW_NEAR_PRIVATE_KEY={private_key}\n")
lines.append(f"NEAR_CONTRACT_ID={contract_id}\n")
if near_rpc_url:
    lines.append(f"NEAR_RPC_URL={near_rpc_url}\n")
lines.append("RODIT_NEAR_CREDENTIALS_SOURCE=file\n")
lines.append(f"NEAR_CREDENTIALS_FILE_PATH={container_cred_path}\n")
env_file.parent.mkdir(parents=True, exist_ok=True)
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}


sync_quiet_plugin_env() {
  local config_dir="$1"
  local container="${2:-}"
  local env_file use_container_env
  load_env
  local fallback_ms="${OPENCLAW_FALLBACK_SKIP_TTL_MS:-1000}"
  local near_rpc_url="${NEAR_RPC_URL:-}"
  container="$(agent_container_for_config_dir "$config_dir" "$container")"
  read -r use_container_env env_file <<<"$(agent_env_write_context "$config_dir" "$container" | tr '\t' ' ')"
  if [[ "$use_container_env" != "1" ]] && [[ ! -f "$env_file" ]] 2>/dev/null && [[ ! -w "$config_dir" ]] 2>/dev/null; then
    return 0
  fi
  _agent_env_python "$config_dir" "$container" "$use_container_env" "$env_file" \
    "$IDENTYCLAW_NEAR_CONTRACT_ID" "$fallback_ms" "$near_rpc_url" <<'PY'
import os, sys
from pathlib import Path

env_file = Path(sys.argv[1])
near_contract_id = sys.argv[2]
fallback_ms = sys.argv[3]
near_rpc_url = sys.argv[4]
desired = {
    "LOG_LEVEL": "error",
    "SUPPRESS_NO_CONFIG_WARNING": "true",
    "SUPPRESS_STRICTNESS_CHECK": "true",
    "NEAR_CONTRACT_ID": near_contract_id,
    "OPENCLAW_FALLBACK_SKIP_TTL_MS": fallback_ms,
}
if near_rpc_url:
    desired["NEAR_RPC_URL"] = near_rpc_url
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


_write_quiet_plugin_env_file() {
  local env_file="$1"
  local near_contract_id="$2"
  local fallback_ms="$3"
  local near_rpc_url="${4:-}"
  python3 - "$env_file" "$near_contract_id" "$fallback_ms" "$near_rpc_url" <<'PY'
import os, sys
from pathlib import Path

env_file = Path(sys.argv[1])
near_contract_id = sys.argv[2]
fallback_ms = sys.argv[3]
near_rpc_url = sys.argv[4]
desired = {
    "LOG_LEVEL": "error",
    "SUPPRESS_NO_CONFIG_WARNING": "true",
    "SUPPRESS_STRICTNESS_CHECK": "true",
    "NEAR_CONTRACT_ID": near_contract_id,
    "OPENCLAW_FALLBACK_SKIP_TTL_MS": fallback_ms,
}
if near_rpc_url:
    desired["NEAR_RPC_URL"] = near_rpc_url
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


identyclaw_skill_installed_in_container() {
  local container="$1"
  podman exec "$container" sh -c \
    'test -f /home/node/.openclaw/workspace/skills/identyclaw/SKILL.md \
      || test -f /home/node/.openclaw/skills/identyclaw/SKILL.md' 2>/dev/null
}


identyclaw_skill_frontmatter_version() {
  local skill_md="$1"
  [[ -f "$skill_md" ]] || return 0
  python3 - "$skill_md" <<'PY' 2>/dev/null || true
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
m = re.search(r"(?m)^version:\s*([^\s#]+)", text)
print(m.group(1) if m else "")
PY
}


identyclaw_skill_version_in_container() {
  local container="$1"
  local text
  text="$(podman exec "$container" sh -c \
    'cat /home/node/.openclaw/workspace/skills/identyclaw/SKILL.md 2>/dev/null \
      || cat /home/node/.openclaw/skills/identyclaw/SKILL.md 2>/dev/null' 2>/dev/null || true)"
  [[ -n "$text" ]] || return 0
  python3 -c 'import re,sys; m=re.search(r"(?m)^version:\s*([^\s#]+)", sys.argv[1]); print(m.group(1) if m else "")' "$text" 2>/dev/null || true
}

# Install workspace skill: plugin-bundled skill/ when present; else ClawHub pin;
# host git checkout only when no IDENTYCLAW_CLAWHUB_SKILL_VERSION is set.

# Install workspace skill: plugin-bundled skill/ when present; else ClawHub pin;
# host git checkout only when no IDENTYCLAW_CLAWHUB_SKILL_VERSION is set.
install_identyclaw_skill() {
  local config_dir="$1"
  local container="${2:-}"
  local force="${3:-0}"
  local skill_spec skill_ver plugin_skill host_skill stage_ctr install_args=()
  load_env
  skill_spec="${IDENTYCLAW_CLAWHUB_SKILL:-identyclaw}"
  skill_ver="${IDENTYCLAW_CLAWHUB_SKILL_VERSION:-}"

  plugin_skill="$(agent_identyclaw_tools_ext_dir_container)/skill"
  host_skill=""
  # A ClawHub version pin is authoritative — skip the host git cache (often stale).
  if [[ -z "$skill_ver" ]]; then
    host_skill="$(agent_identyclaw_tools_ext_dir "$config_dir")/skill"
    if [[ ! -f "$host_skill/SKILL.md" ]]; then
      host_skill="$(identyclaw_app_dir)/repo/openclaw-identyclaw-plugin/skill"
    fi
    [[ -f "$host_skill/SKILL.md" ]] || host_skill=""
  fi

  if [[ "$force" == "1" ]]; then
    install_args+=(--force)
  fi

  if _agent_container_name_running "$container"; then
    if podman exec "$container" test -f "${plugin_skill}/SKILL.md" 2>/dev/null; then
      echo "    (IdentyClaw skill: plugin-bundled ${plugin_skill})" >&2
      openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" "$plugin_skill" >&2
      return $?
    fi
    if [[ -n "$host_skill" ]]; then
      stage_ctr="/tmp/.identyclaw-skill-src"
      echo "    (IdentyClaw skill: host ${host_skill} → container)" >&2
      podman exec "$container" rm -rf "$stage_ctr" 2>/dev/null || true
      podman cp "$host_skill" "$container:$stage_ctr" >/dev/null || return 1
      openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" "$stage_ctr" >&2
      local rc=$?
      podman exec "$container" rm -rf "$stage_ctr" 2>/dev/null || true
      return "$rc"
    fi
  fi

  echo "    (IdentyClaw skill: ClawHub ${skill_spec}${skill_ver:+ @}${skill_ver})" >&2
  [[ -n "$skill_ver" ]] && install_args+=(--version "$skill_ver")
  # Older OpenClaw CLIs required --acknowledge-clawhub-risk for this skill; 2026.6.11+
  # dropped that flag. Only pass it when the installed CLI still advertises it.
  if openclaw_agent_exec "$config_dir" "$container" skills install --help 2>/dev/null \
    | grep -q -- '--acknowledge-clawhub-risk'; then
    install_args+=(--acknowledge-clawhub-risk)
  fi
  openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" "$skill_spec" >&2 \
    || openclaw_agent_exec "$config_dir" "$container" skills install "${install_args[@]}" identyclaw >&2
}


ensure_identyclaw_config() {
  local config_dir="$1"
  local container="${2:-}"
  local config cred_dir has_creds=0 cred_path=""
  config="$config_dir/openclaw.json"
  cred_dir="$config_dir/secrets/near-credentials"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  if agent_has_near_credentials "$config_dir" "$container"; then
    has_creds=1
    cred_path="$(agent_near_cred_path_for_config_sync "$config_dir" "$container")"
    sync_identyclaw_env "$config_dir" "$container"
  fi
  local api_base=""
  local api_endpoints="${IDENTYCLAW_API_ENDPOINTS:-}"
  if [[ "$has_creds" -eq 1 ]]; then
    api_base="$(identyclaw_api_base_url_for_config_dir "$config_dir" 2>/dev/null || true)"
  fi
  load_env
  api_endpoints="${IDENTYCLAW_API_ENDPOINTS:-$api_endpoints}"
  _agent_openclaw_json_python "$config_dir" "$container" "$has_creds" "$cred_path" "$api_base" "$api_endpoints" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
has_creds = sys.argv[2] == "1"
cred_path = sys.argv[3]
api_base = sys.argv[4] if len(sys.argv) > 4 else ""
api_endpoints_raw = sys.argv[5] if len(sys.argv) > 5 else ""
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
if api_base and cfg.get("baseUrl") != api_base:
    cfg["baseUrl"] = api_base
    changed = True

api_endpoints = []
for part in api_endpoints_raw.replace(";", ",").split(","):
    u = part.strip().rstrip("/")
    if u and u not in api_endpoints:
        api_endpoints.append(u)
if api_endpoints and cfg.get("apiEndpoints") != api_endpoints:
    cfg["apiEndpoints"] = api_endpoints
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

# Do not maintain a hard tools.allow. A non-empty allow without "*" is
# deny-by-default and strips runtime tools agents need.
tools = data.setdefault("tools", {})
allow = tools.get("allow")
allow_entries = allow if isinstance(allow, list) else []
if not allow_entries or not any(str(e).strip() == "*" for e in allow_entries):
    tools["allow"] = ["*"]
    changed = True

# Do NOT wire remote MCP servers that need dynamic federated JWTs. OpenClaw
# mcp.servers.headers are static; they cannot use the IdentyClaw plugin's
# per-URL session cache. Drop legacy "slc" entries if present.
mcp_servers = data.get("mcp", {}).get("servers")
if isinstance(mcp_servers, dict) and "slc" in mcp_servers:
    del mcp_servers["slc"]
    changed = True
    if not mcp_servers:
        mcp = data.get("mcp")
        if isinstance(mcp, dict) and "servers" in mcp:
            del mcp["servers"]
        if isinstance(mcp, dict) and not mcp:
            del data["mcp"]

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

  _agent_container_name_running "$container" || return 0
  ensure_openclaw_cli_link "$container"
  link_identyclaw_plugin_deps_in_container "$container"
  podman exec "$container" node /app/openclaw.mjs plugins registry --refresh >&2 || true
  if ! identyclaw_skill_installed_in_container "$container"; then
    install_identyclaw_skill "$config_dir" "$container" 0 \
      || echo "    (${id}: IdentyClaw skill install failed)" >&2
  fi
}


ensure_a2a_plugin_build() {
  local id="$1"
  local config_dir container
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  agent_has_near_credentials "$config_dir" "$container" || return 0
  install_a2a_plugin "$config_dir" 0 "$id"
  install_identyclaw_webhooks_plugin "$config_dir" 0 "$id" || true
  ensure_webhooks_plugin_config "$config_dir" "$container"
}


ensure_bearer_http_packages() {
  local id="$1"
  local config_dir container
  load_env
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  if ! install_bearer_http_plugin "$config_dir" 0 "$id"; then
    echo "    (${id}: bearer-http plugin install skipped — see errors above)" >&2
    return 0
  fi
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    link_bearer_http_plugin_deps_in_container "$container" "$config_dir"
  fi
}


ensure_agent_packages() {
  local id="$1"
  ensure_identyclaw_packages "$id"
  ensure_a2a_packages "$id"
  ensure_bearer_http_packages "$id"
}


ensure_agent_identyclaw_tooling() {
  local id="$1"
  local config_dir="$2"
  write_agent_identyclaw_doc "$id" "$config_dir"
}


build_a2a_peer_map() {
  local self_id="$1"
  local self_config_dir self_token_id configured_json api_json peers_json
  local local_token_ids="" local_tid
  load_env
  warn_invalid_a2a_peer_agents
  self_config_dir="$(agent_home "$self_id")"
  self_token_id="$(probe_rodit_own_token_id "$self_config_dir" 2>/dev/null || true)"
  # Resolve local token_ids once — avoid N peers × M agents of Passport RPC.
  local_token_ids="$(local_host_agent_token_ids 2>/dev/null || true)"

  local peer_token_id public_base card_url skip_local
  local first=1
  configured_json="{"
  for peer_token_id in $A2A_PEER_AGENTS; do
    is_passport_token_id "$peer_token_id" || continue
    [[ -n "$self_token_id" && "$peer_token_id" == "$self_token_id" ]] && continue
    skip_local=0
    for local_tid in $local_token_ids; do
      [[ "$local_tid" == "$peer_token_id" ]] && { skip_local=1; break; }
    done
    [[ "$skip_local" -eq 1 ]] && continue

    # Deploy/bootstrap: static URLs only. API /full + agent-card probes belong in
    # discover-a2a-peers / constitution tests (see a2a_peer_public_base_url_with_retry).
    public_base="$(a2a_peer_public_base_url_static "$peer_token_id" "$self_config_dir")"
    if [[ -z "$public_base" ]]; then
      if a2a_resolve_peers_by_token_id_enabled; then
        echo "    (${self_id}: peer ${peer_token_id} — no static URL; resolvePeersByTokenId at runtime)" >&2
      else
        echo "    (${self_id}: skip peer ${peer_token_id} — no URL in A2A_PEER_URLS)" >&2
      fi
      continue
    fi
    card_url="${public_base%/}/.well-known/agent-card.json"
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      configured_json+=","
    fi
    configured_json+="\"${peer_token_id}\":{\"url\":\"${card_url}\""
    configured_json+=",\"loginBaseUrl\":\"${public_base}\""
    configured_json+="}"
  done
  configured_json+="}"

  # Same-host AGENT_IDS peers are excluded from GET /api/agents seeding (avoid
  # self-fleet noise). Seed them explicitly from deploy PUBLIC_HOST+INGRESS_PORT
  # so local A2A works even when a peer's on-chain Passport webhook_url is stale
  # (e.g. andrew.dihola.io:88 while ingress is :8443).
  # Prefer iterating AGENT_IDS + agent_token_id (container probe) over
  # find_deploy_id_for_token_id, which only hits host-readable Passport caches.
  local local_peers_json="{" local_first=1 local_peer_tid local_deploy_id peer_tid
  for local_deploy_id in $AGENT_IDS; do
    [[ "$local_deploy_id" == "$self_id" ]] && continue
    local_peer_tid="$(agent_token_id "$local_deploy_id" 2>/dev/null || true)"
    is_passport_token_id "$local_peer_tid" || continue
    [[ -n "$self_token_id" && "$local_peer_tid" == "$self_token_id" ]] && continue
    public_base="$(agent_public_base_url "$local_deploy_id" 2>/dev/null || true)"
    [[ -z "$public_base" ]] && public_base="$(agent_a2a_public_base_url "$local_deploy_id" 2>/dev/null || true)"
    [[ -z "$public_base" ]] && public_base="$(a2a_peer_public_base_url_static "$local_peer_tid" "$self_config_dir" 2>/dev/null || true)"
    [[ -n "$public_base" ]] || {
      echo "    (${self_id}: skip same-host ${local_deploy_id}/${local_peer_tid} — no public base)" >&2
      continue
    }
    public_base="${public_base%/}"
    card_url="${public_base}/.well-known/agent-card.json"
    if [[ "$local_first" -eq 1 ]]; then
      local_first=0
    else
      local_peers_json+=","
    fi
    local_peers_json+="\"${local_peer_tid}\":{\"url\":\"${card_url}\""
    local_peers_json+=",\"loginBaseUrl\":\"${public_base}\""
    local_peers_json+="}"
  done
  local_peers_json+="}"
  if [[ "$local_peers_json" != "{}" ]]; then
    echo "    (${self_id}: seeding same-host A2A peers from deploy ingress)" >&2
  fi

  api_json="{}"
  # Opt-in (IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1). First caller on this host does
  # GET /api/agents + parallel agent-card probes; later AGENT_IDS reuse the file cache.
  if a2a_discover_peers_from_api_enabled; then
    echo "    (${self_id}: API peer discovery — GET /api/agents + parallel agent-card probe)" >&2
    api_json="$(discover_live_api_peers_json_for_agent "$self_id")"
    [[ -n "$api_json" && "$api_json" == \{* ]] || api_json="{}"
    if [[ "$configured_json" != "{}" ]]; then
      configured_json="$(a2a_filter_superseded_configured_peer_map_json "$api_json" "$configured_json")"
    fi
  fi

  local api_file cfg_file local_file peers_json merged_remote
  api_file="$(mktemp)"
  cfg_file="$(mktemp)"
  local_file="$(mktemp)"
  printf '%s' "$api_json" > "$api_file"
  printf '%s' "$configured_json" > "$cfg_file"
  printf '%s' "$local_peers_json" > "$local_file"
  # Remote (API + A2A_PEER_AGENTS) first; same-host deploy URLs win on collision.
  merged_remote="$(merge_a2a_peer_json_maps_files "$api_file" "$cfg_file")"
  printf '%s' "$merged_remote" > "$api_file"
  peers_json="$(merge_a2a_peer_json_maps_files "$api_file" "$local_file")"
  rm -f "$api_file" "$cfg_file" "$local_file"
  echo "$peers_json"
}


ensure_a2a_config() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  agent_has_near_credentials "$config_dir" "$container" || return 0

  load_env
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  sync_identyclaw_env "$config_dir" "$container"

  a2a_warn_legacy_auth_mode_env "$id"

  local audience display_name card_name card_description public_base_url peers_json dynamic_peers_from_jwt own_token_id api_base
  audience="$(agent_a2a_audience "$id" "$config_dir" "$container")"
  display_name="$(agent_display_name "$id")"
  card_name="$(agent_card_name "$id")"
  card_description="$(agent_card_description "$id")"
  public_base_url="$(agent_a2a_public_base_url "$id")"
  own_token_id="$(probe_rodit_own_token_id "$config_dir" 2>/dev/null || true)"
  api_base="$(identyclaw_api_base_url_for_config_dir "$config_dir" 2>/dev/null || true)"
  sync_rodit_token_id_env "$config_dir" "$container"
  peers_json="$(build_a2a_peer_map "$id")"
  dynamic_peers_from_jwt="0"
  if a2a_dynamic_peers_from_jwt_enabled; then
    dynamic_peers_from_jwt="1"
  fi

  # Pass peers as base64 in argv — avoids host/container temp-file path races during
  # pod restart (openclaw.json ownership can flip between mktemp staging and python).
  local peers_b64
  peers_b64="$(printf '%s' "$peers_json" | base64 -w0 2>/dev/null || printf '%s' "$peers_json" | base64)"

  _agent_openclaw_json_python "$config_dir" "$container" \
    "$audience" "$display_name" "$public_base_url" "$peers_b64" \
    "$api_base" "$dynamic_peers_from_jwt" "$own_token_id" \
    "$card_name" "$card_description" <<'PY'
import base64, json, sys
from pathlib import Path

path = Path(sys.argv[1])
audience = sys.argv[2]
display_name = sys.argv[3]
public_base_url = sys.argv[4]
peers = json.loads(base64.standard_b64decode(sys.argv[5]))
issuer = sys.argv[6]
dynamic_peers_from_jwt = sys.argv[7] == "1"
own_token_id = sys.argv[8] if len(sys.argv) > 8 else ""
card_name = sys.argv[9] if len(sys.argv) > 9 else display_name
card_description = sys.argv[10] if len(sys.argv) > 10 else display_name

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
existing_audience = (auth.get("audience") or "").strip()
resolved_audience = (audience or "").strip()
# Never wipe a previously synced owner_id when the probe is unavailable (e.g. host
# cannot read container-owned NEAR creds during sync).
if not resolved_audience and existing_audience:
    resolved_audience = existing_audience
existing_issuer = (auth.get("issuer") or "").strip()
resolved_issuer = (issuer or "").strip()
# Same for API base used as JWT issuer — empty resolve must not clear a working issuer
# (Invalid issuer / Error 005 on POST /a2a with P2P JWT).
if not resolved_issuer and existing_issuer:
    resolved_issuer = existing_issuer
desired_auth = {
    "provider": "rodit",
    "issuer": resolved_issuer,
    "audience": resolved_audience,
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
if card.get("name") != card_name:
    card["name"] = card_name
    changed = True
if card.get("description") != card_description:
    card["description"] = card_description
    changed = True

# Agent Card skills[] — required by A2A discovery (plugin reads inbound.agentCard.skills only).
KNOWN_SKILLS = {
    "identyclaw": {
        "id": "identyclaw",
        "name": "IdentyClaw",
        "description": "Portable, verifiable agent identity — HOLA create/verify, Passport lookup, DID resolution, and peer discovery",
        "tags": ["identity", "hola", "passport"],
    },
    "himalaya": {
        "id": "himalaya",
        "name": "Email",
        "description": "Email concierge — receive and reply to inbound mail via Himalaya (Migadu IMAP/SMTP)",
        "tags": ["email", "smtp", "imap", "concierge"],
    },
    "bird-twitter": {
        "id": "bird-twitter",
        "name": "Twitter / X",
        "description": "Post and search on Twitter/X via bird CLI",
        "tags": ["twitter", "social"],
    },
}
A2A_SKILL = {
    "id": "a2a-messaging",
    "name": "A2A Peer Messaging",
    "description": "Agent-to-agent messaging, tasks, and file exchange with RODiT JWT — verify peers before sharing data",
    "tags": ["a2a", "messaging", "tasks"],
}
skill_entries = data.get("skills", {}).get("entries", {})
advertised = []
seen_ids = set()
for slug, entry in skill_entries.items():
    if not isinstance(entry, dict) or entry.get("enabled") is not True:
        continue
    meta = KNOWN_SKILLS.get(slug)
    if meta and meta["id"] not in seen_ids:
        advertised.append(meta)
        seen_ids.add(meta["id"])
if A2A_SKILL["id"] not in seen_ids:
    advertised.append(A2A_SKILL)
    seen_ids.add(A2A_SKILL["id"])
if not advertised:
    advertised.append({
        "id": "default",
        "name": card_name,
        "description": card_description,
    })
if json.dumps(card.get("skills"), sort_keys=True) != json.dumps(advertised, sort_keys=True):
    card["skills"] = advertised
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

# Do not append A2A tool names onto tools.allow (hard allowlists strip MCP tools).
# Unrestricted policy is ["*"] — see ensure_identyclaw_config.

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY

  if [[ -n "$peers_json" && "$peers_json" != "{}" ]]; then
    sync_a2a_tls_env "$config_dir" "$container"
  elif a2a_resolve_peers_by_token_id_enabled && [[ -n "$(a2a_configured_peer_token_ids)" ]]; then
    sync_a2a_tls_env "$config_dir" "$container"
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

# Parse openclaw git:github.com/owner/repo[@ref] → https URL + optional ref.

# Parse openclaw git:github.com/owner/repo[@ref] → https URL + optional ref.
parse_openclaw_git_plugin_spec() {
  local spec="$1"
  local body ref=""
  [[ "$spec" == git:* ]] || return 1
  body="${spec#git:}"
  case "$body" in
    https://*|http://*) body="${body#*://}" ;;
    ssh://git@*) body="${body#ssh://git@}" ;;
    ssh://*) body="${body#ssh://}" ;;
    git@*) body="${body#git@}"; body="${body/:/\/}" ;;
  esac
  if [[ "$body" == *@* ]]; then
    ref="${body##*@}"
    body="${body%@*}"
  fi
  body="${body%.git}"
  body="${body#github.com/}"
  [[ "$body" =~ ^[^/]+/[^/]+$ ]] || return 1
  printf '%s\n' "https://github.com/${body}.git" "$ref"
}


build_git_plugin() {
  local repo="$1"
  local build_dir="$2"
  local build_cmd="${3:-build}"
  local ref="${4:-}"

  command -v git >/dev/null 2>&1 || {
    echo "    (plugin: git required to clone ${repo})" >&2
    return 1
  }
  command -v npm >/dev/null 2>&1 || {
    echo "    (plugin: npm required to build ${repo})" >&2
    return 1
  }

  rm -rf "$build_dir"
  mkdir -p "$(dirname "$build_dir")"
  if [[ -n "$ref" ]]; then
    if ! git clone --depth 1 --branch "$ref" "$repo" "$build_dir" >&2; then
      git clone "$repo" "$build_dir" >&2 || return 1
      git -C "$build_dir" checkout "$ref" >&2 || return 1
    fi
  else
    git clone --depth 1 "$repo" "$build_dir" >&2 || return 1
  fi
  (
    cd "$build_dir"
    npm install >&2
    npm run "$build_cmd" >&2
  ) || return 1
  [[ -f "$build_dir/dist/index.js" ]] || {
    echo "    (plugin: build produced no dist/index.js in ${build_dir})" >&2
    return 1
  }
}

# Host-side clone+build cache for git: IdentyClaw tools plugin (OpenClaw git: install skips tsc).

# Host-side clone+build cache for git: IdentyClaw tools plugin (OpenClaw git: install skips tsc).
ensure_identyclaw_git_plugin_build() {
  local plugin_spec="$1"
  local force="${2:-0}"
  local parsed repo ref build_dir marker head
  load_env
  mapfile -t parsed < <(parse_openclaw_git_plugin_spec "$plugin_spec") || return 1
  repo="${parsed[0]}"
  ref="${parsed[1]:-}"
  build_dir="$(identyclaw_app_dir)/repo/openclaw-identyclaw-plugin"
  marker="${build_dir}/.identyclaw-git-build"

  if [[ "$force" != "1" && -f "$build_dir/dist/index.js" && -f "$marker" ]]; then
    if [[ "$(cat "$marker" 2>/dev/null || true)" == "${repo}@${ref:-HEAD}" ]]; then
      printf '%s' "$build_dir"
      return 0
    fi
  fi

  echo "    (building IdentyClaw plugin from ${repo}${ref:+ @}${ref}…)" >&2
  build_git_plugin "$repo" "$build_dir" build "$ref" || return 1
  printf '%s\n' "${repo}@${ref:-HEAD}" >"$marker"
  head="$(git -C "$build_dir" rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "$head" ]] && echo "    (built ${build_dir} @ ${head})" >&2
  printf '%s' "$build_dir"
}

# Remove legacy dynamicPeersFromJwt so ClawHub install can validate config (0.4.0+ schema).

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


install_identyclaw_webhooks_plugin() {
  local config_dir="$1"
  local force="${2:-0}"
  local id="${3:-}"
  local container ext_dir plugin_spec desired_ver installed_ver
  ext_dir="$(agent_webhooks_ext_dir "$config_dir")"
  load_env
  plugin_spec="${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN}"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""
  agent_has_near_credentials "$config_dir" "$container" || return 0

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(webhooks_plugin_installed_version "$config_dir" "$container")"

  if [[ "$force" != "1" && -n "$desired_ver" && "$installed_ver" == "$desired_ver" ]] \
    && webhooks_ext_ready "$config_dir" "$container"; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
    else
      link_identyclaw_webhooks_plugin_deps "$ext_dir"
    fi
    return 0
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf \
        "$(agent_webhooks_ext_dir_container)" \
        /home/node/.openclaw/.identyclaw-webhooks-plugin-build 2>/dev/null || true
    else
      rm -rf "$ext_dir" "$config_dir/.identyclaw-webhooks-plugin-build" 2>/dev/null || true
    fi
  fi

  echo "    (installing IdentyClaw webhooks plugin from ${plugin_spec}…)" >&2
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=(--accept-capabilities)
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

  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
  else
    link_identyclaw_webhooks_plugin_deps "$ext_dir"
  fi
}


ensure_webhooks_plugin_config() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  agent_has_near_credentials "$config_dir" "$container" || return 0

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

# Do not append send_rodit_webhook onto tools.allow (hard allowlists strip MCP tools).

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
  agent_has_near_credentials "$config_dir" "$container" || return 0

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(a2a_plugin_installed_version "$config_dir" "$container")"

  if [[ "$force" != "1" && -n "$desired_ver" && "$installed_ver" == "$desired_ver" ]] \
    && a2a_ext_ready "$config_dir" "$container"; then
    migrate_legacy_a2a_extension "$config_dir" "$container"
    [[ -n "$id" ]] && ensure_a2a_config "$id" "$config_dir" "$container" || true
    return 0
  fi

  migrate_legacy_a2a_extension "$config_dir" "$container"
  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf "$(agent_a2a_ext_dir_container)" 2>/dev/null || true
    else
      rm -rf "$ext_dir" 2>/dev/null || true
    fi
  fi

  echo "    (installing A2A plugin from ${plugin_spec}…)" >&2
  strip_a2a_dynamic_peers_config_for_install "$config_dir" "$container"
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=(--accept-capabilities)
  if [[ "$force" == "1" || ( -n "$desired_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    install_args+=(--force)
  fi
  if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
    return 1
  fi
  a2a_ext_ready "$config_dir" "$container" || {
    echo "    (identyclaw-a2a: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    link_identyclaw_webhooks_plugin_deps_in_container "$container" 2>/dev/null || true
  fi

  [[ -n "$id" ]] && ensure_a2a_config "$id" "$config_dir" "$container" || true
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
  apply_identyclaw_request_body_patch_in_container "$container" || true
}


# Resolve patch-identyclaw-request-body.mjs from the active CLI tree or APP_DIR/repo.
# Operators often rebuild via openclaw-agents-app/repo/identyclaw.sh; keep that copy in sync.
identyclaw_request_body_patch_src() {
  local candidate
  for candidate in \
    "${IDENTYCLAW_ROOT}/scripts/patch-identyclaw-request-body.mjs" \
    "$(identyclaw_app_dir)/repo/scripts/patch-identyclaw-request-body.mjs"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}


# Coerce LLM-stringified JSON bodies in identyclaw_request (avoids INVALID_JSON).
apply_identyclaw_request_body_patch_in_container() {
  local container="$1"
  local patch_src=""
  [[ -n "$container" ]] || return 0
  # Prefer image-baked copy when present (survives rebuilds without host script sync).
  if _agent_container_name_running "$container" \
    && podman exec "$container" test -f /opt/identyclaw/patch-identyclaw-request-body.mjs 2>/dev/null; then
    podman exec "$container" node /opt/identyclaw/patch-identyclaw-request-body.mjs \
      --root /home/node/.openclaw >/dev/null 2>&1 || return 1
    return 0
  fi
  patch_src="$(identyclaw_request_body_patch_src)" || return 0
  _agent_container_name_running "$container" || return 0
  podman cp "$patch_src" "${container}:/tmp/patch-identyclaw-request-body.mjs" >/dev/null 2>&1 || return 1
  podman exec "$container" node /tmp/patch-identyclaw-request-body.mjs \
    --root /home/node/.openclaw >/dev/null 2>&1 || return 1
}


ensure_identyclaw_request_body_patch() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  apply_identyclaw_request_body_patch_in_container "$container" || {
    echo "    (${id}: identyclaw_request body patch failed)" >&2
    return 1
  }
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  local container ext_dir plugin_spec desired_ver installed_ver build_dir stage_dir
  ext_dir="$(agent_identyclaw_tools_ext_dir "$config_dir")"
  load_env
  plugin_spec="${IDENTYCLAW_CLAWHUB_PLUGIN}"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""

  desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec")"
  installed_ver="$(identyclaw_plugin_installed_version "$config_dir" "$container")"

  # Semver pin: skip when version matches. git:/unpinned: skip when tree is ready unless forced.
  if [[ "$force" != "1" ]] && identyclaw_tools_ext_ready "$config_dir" "$container"; then
    if [[ -z "$desired_ver" || "$installed_ver" == "$desired_ver" ]]; then
      return 0
    fi
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf \
        "$(agent_identyclaw_tools_ext_dir_container)" \
        /home/node/.openclaw/.identyclaw-plugin-build 2>/dev/null || true
    else
      rm -rf "$ext_dir" "$config_dir/.identyclaw-plugin-build" 2>/dev/null || true
    fi
  fi

  echo "    (installing IdentyClaw plugin from ${plugin_spec}…)" >&2
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  local install_args=(--accept-capabilities)
  if [[ "$force" == "1" || ( -n "$desired_ver" && "$installed_ver" != "$desired_ver" ) || "$plugin_spec" == git:* ]]; then
    install_args+=(--force)
  fi

  # OpenClaw git: install clones source but does not run tsc — build then install from path.
  if [[ "$plugin_spec" == git:* ]]; then
    # Host build cached under app/repo; upgrade-plugins clears the marker to refresh once.
    build_dir="$(ensure_identyclaw_git_plugin_build "$plugin_spec" 0)" || return 1
    stage_dir="/tmp/.identyclaw-tools-plugin-src"
    local host_stage="${config_dir}/.identyclaw-plugin-build"
    local container_stage="/home/node/.openclaw/.identyclaw-plugin-build"
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf "$stage_dir" 2>/dev/null || true
      podman cp "$build_dir" "$container:$stage_dir" >/dev/null || return 1
      if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$stage_dir" >&2; then
        return 1
      fi
      podman exec "$container" rm -rf "$stage_dir" 2>/dev/null || true
    else
      # One-shot openclaw_agent_exec only mounts config_dir — stage build there so the
      # container path resolves (host app/repo path is invisible inside the image).
      rm -rf "$host_stage"
      cp -a "$build_dir" "$host_stage" || return 1
      if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$container_stage" >&2; then
        rm -rf "$host_stage"
        return 1
      fi
      rm -rf "$host_stage"
    fi
  else
    if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
      return 1
    fi
  fi
  identyclaw_tools_ext_ready "$config_dir" "$container" || {
    echo "    (identyclaw-tools: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
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
  local config_dir container
  load_env
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  install_identyclaw_skill "$config_dir" "$container" 1 \
    || echo "    (${id}: IdentyClaw skill install failed)" >&2
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
  install_a2a_plugin "$config_dir" 0 "$id" || {
    echo "A2A plugin install failed for ${id}" >&2
    return 1
  }

  echo "    (IdentyClaw: ${IDENTYCLAW_CLAWHUB_PLUGIN})"
  # Force refresh for git: pins (no semver skip) and when switching off ClawHub.
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
  install_identyclaw_webhooks_plugin "$config_dir" 0 "$id" || {
    echo "IdentyClaw webhooks plugin install failed for ${id}" >&2
    return 1
  }
  ensure_webhooks_plugin_config "$config_dir" "$container" || return 1

  echo "    (bearer-http: ${BEARER_HTTP_CLAWHUB_PLUGIN:-$(bearer_http_default_git_url)})"
  install_bearer_http_plugin "$config_dir" 1 "$id" || {
    echo "bearer-http plugin install failed for ${id}" >&2
    return 1
  }

  upgrade_agent_skill "$id"

  if _agent_container_name_running "$container"; then
    link_identyclaw_plugin_deps_in_container "$container"
    link_bearer_http_plugin_deps_in_container "$container" "$config_dir"
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
  agent_has_near_credentials "$config_dir" "$container" || return 0
  if ! install_a2a_plugin "$config_dir" 0 "$id"; then
    return 0
  fi
  install_identyclaw_webhooks_plugin "$config_dir" 0 "$id" || true
  ensure_webhooks_plugin_config "$config_dir" "$container" || true
  ensure_a2a_config "$id" "$config_dir" "$container" || true
  _agent_container_name_running "$container" || return 0
  ensure_openclaw_cli_link "$container"
  podman exec "$container" node /app/openclaw.mjs plugins registry --refresh >&2 || true
}
