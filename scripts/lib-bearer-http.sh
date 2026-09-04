#!/usr/bin/env bash
# Fleet install + config for @identyclaw/openclaw-identyclaw-httpbearer-plugin
# (guest bearer storage + http_request).
#
# Default source until ClawHub publish:
#   git:github.com/discernible-io/openclaw-identyclaw-httpbearer-plugin
# Then switch BEARER_HTTP_CLAWHUB_PLUGIN to clawhub:@identyclaw/...@x.y.z
# Raw https://…git specs are normalized to git: (OpenClaw rejects bare URLs).

bearer_http_plugin_id() {
  echo "bearer-http"
}

bearer_http_default_git_url() {
  # OpenClaw rejects raw https:// plugin specs ("URLs are not allowed").
  echo "git:github.com/discernible-io/openclaw-identyclaw-httpbearer-plugin"
}

# Normalize https://github.com/owner/repo(.git) → git:github.com/owner/repo
bearer_http_normalize_spec() {
  local spec="$1"
  local body
  case "$spec" in
    https://github.com/*|http://github.com/*)
      body="${spec#*://github.com/}"
      body="${body%.git}"
      printf 'git:github.com/%s\n' "$body"
      ;;
    *)
      printf '%s\n' "$spec"
      ;;
  esac
}

# Resolution order:
#   1. BEARER_HTTP_PLUGIN_PATH (local checkout)
#   2. BEARER_HTTP_CLAWHUB_PLUGIN (clawhub: / git: / https://…git)
#   3. GitHub default (until ClawHub is the fleet pin)
bearer_http_plugin_spec() {
  load_env
  if [[ -n "${BEARER_HTTP_PLUGIN_PATH:-}" ]]; then
    printf '%s\n' "$BEARER_HTTP_PLUGIN_PATH"
    return 0
  fi
  if [[ -n "${BEARER_HTTP_CLAWHUB_PLUGIN:-}" ]]; then
    bearer_http_normalize_spec "$BEARER_HTTP_CLAWHUB_PLUGIN"
    return 0
  fi
  bearer_http_default_git_url
}

bearer_http_spec_is_remote() {
  local spec="$1"
  case "$spec" in
    clawhub:*|npm:*|git:*|https://*|http://*) return 0 ;;
    *) return 1 ;;
  esac
}

agent_bearer_http_ext_dir() {
  echo "$1/extensions/$(bearer_http_plugin_id)"
}

agent_bearer_http_ext_dir_container() {
  echo "/home/node/.openclaw/extensions/$(bearer_http_plugin_id)"
}

# Resolve install root: extensions/bearer-http (path/clawhub) or git/*/repo (git: installs).
bearer_http_resolve_install_dir_container() {
  local container="$1"
  podman exec "$container" bash -c '
    set -euo pipefail
    ext="/home/node/.openclaw/extensions/bearer-http"
    if [[ -f "$ext/openclaw.plugin.json" ]] && [[ -f "$ext/index.mjs" || -f "$ext/dist/index.js" ]]; then
      printf "%s\n" "$ext"
      exit 0
    fi
    shopt -s nullglob
    for dir in /home/node/.openclaw/git/*/repo; do
      if [[ -f "$dir/openclaw.plugin.json" ]] && grep -q "\"id\"[[:space:]]*:[[:space:]]*\"bearer-http\"" "$dir/openclaw.plugin.json" 2>/dev/null; then
        if [[ -f "$dir/index.mjs" || -f "$dir/dist/index.js" ]]; then
          printf "%s\n" "$dir"
          exit 0
        fi
      fi
    done
    exit 1
  ' 2>/dev/null
}

bearer_http_resolve_install_dir_host() {
  local config_dir="$1"
  local ext_dir dir
  ext_dir="$(agent_bearer_http_ext_dir "$config_dir")"
  if [[ -f "$ext_dir/openclaw.plugin.json" ]] && [[ -f "$ext_dir/index.mjs" || -f "$ext_dir/dist/index.js" ]]; then
    printf '%s\n' "$ext_dir"
    return 0
  fi
  shopt -s nullglob
  for dir in "$config_dir"/git/*/repo; do
    if [[ -f "$dir/openclaw.plugin.json" ]] \
      && grep -q '"id"[[:space:]]*:[[:space:]]*"bearer-http"' "$dir/openclaw.plugin.json" 2>/dev/null \
      && [[ -f "$dir/index.mjs" || -f "$dir/dist/index.js" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

bearer_http_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local pkg pkg_json install_dir
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    install_dir="$(bearer_http_resolve_install_dir_container "$container" || true)"
    [[ -n "$install_dir" ]] || return 0
    pkg_json="$(podman exec "$container" cat "${install_dir}/package.json" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  install_dir="$(bearer_http_resolve_install_dir_host "$config_dir" || true)"
  [[ -n "$install_dir" ]] || return 0
  pkg="${install_dir}/package.json"
  [[ -f "$pkg" ]] || return 0
  python3 - "$pkg" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
print(json.loads(path.read_text(encoding="utf-8")).get("version", ""))
PY
}

bearer_http_ext_ready() {
  local config_dir="$1"
  local container="${2:-}"
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    bearer_http_resolve_install_dir_container "$container" >/dev/null
    return $?
  fi
  bearer_http_resolve_install_dir_host "$config_dir" >/dev/null
}

link_bearer_http_plugin_deps() {
  local target="$1"
  mkdir -p "${target}/node_modules"
  rm -rf "${target}/node_modules/openclaw"
  ln -sf /app "${target}/node_modules/openclaw"
}

link_bearer_http_plugin_deps_in_container() {
  local container="$1"
  local install_dir
  install_dir="$(bearer_http_resolve_install_dir_container "$container" || true)"
  [[ -n "$install_dir" ]] || return 0
  podman exec "$container" bash -c '
    set -euo pipefail
    ext="$1"
    mkdir -p "$ext/node_modules"
    rm -rf "$ext/node_modules/openclaw"
    ln -sf /app "$ext/node_modules/openclaw"
  ' bash "$install_dir" 2>/dev/null || true
}

ensure_bearer_http_plugin_config() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  load_env
  local hosts_raw="${BEARER_HTTP_ALLOWED_HOSTNAMES:-api.lastcradle.io}"
  _agent_openclaw_json_python "$config_dir" "$container" "$hosts_raw" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
hosts_raw = sys.argv[2] if len(sys.argv) > 2 else "api.lastcradle.io"
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

plugins = data.setdefault("plugins", {}).setdefault("entries", {})
entry = plugins.setdefault("bearer-http", {})
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True

cfg = entry.setdefault("config", {})
allowed = []
for part in hosts_raw.replace(";", ",").split(","):
    h = part.strip().lower()
    if h and h not in allowed:
        allowed.append(h)
if not allowed:
    allowed = ["api.lastcradle.io"]

desired_cfg = {
    "allowedHostnames": allowed,
    "defaultNamespace": "lastcradle",
    "maxResponseBytes": 1048576,
    "timeoutMs": 30000,
}
for key, value in desired_cfg.items():
    if cfg.get(key) != value:
        cfg[key] = value
        changed = True

tools = data.setdefault("tools", {})
allow = tools.get("allow")
allow_entries = allow if isinstance(allow, list) else []
if not allow_entries or not any(str(e).strip() == "*" for e in allow_entries):
    tools["allow"] = ["*"]
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

# Install from GitHub / ClawHub / local path.
install_bearer_http_plugin() {
  local config_dir="$1"
  local force="${2:-0}"
  local id="${3:-}"
  local container="" plugin_spec desired_ver installed_ver install_args=(--accept-capabilities)
  local host_stage container_stage install_dir

  load_env
  plugin_spec="$(bearer_http_plugin_spec)"
  [[ -n "$id" ]] && container="$(agent_container "$id")" || container=""

  desired_ver=""
  if [[ "$plugin_spec" == clawhub:* || "$plugin_spec" == npm:* ]]; then
    desired_ver="$(clawhub_plugin_pinned_version "$plugin_spec" || true)"
  fi
  installed_ver="$(bearer_http_plugin_installed_version "$config_dir" "$container")"

  # Git / https tips: reinstall when forced; otherwise keep a ready tree.
  if [[ "$force" != "1" ]] && bearer_http_ext_ready "$config_dir" "$container"; then
    if [[ -z "$desired_ver" || "$installed_ver" == "$desired_ver" ]]; then
      ensure_bearer_http_plugin_config "$config_dir" "$container" || return 1
      if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
        link_bearer_http_plugin_deps_in_container "$container"
      else
        install_dir="$(bearer_http_resolve_install_dir_host "$config_dir" || true)"
        [[ -n "$install_dir" ]] && link_bearer_http_plugin_deps "$install_dir"
      fi
      return 0
    fi
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      install_dir="$(bearer_http_resolve_install_dir_container "$container" || true)"
      [[ -n "$install_dir" ]] && podman exec "$container" rm -rf "$install_dir" 2>/dev/null || true
      podman exec "$container" rm -rf "$(agent_bearer_http_ext_dir_container)" 2>/dev/null || true
    else
      install_dir="$(bearer_http_resolve_install_dir_host "$config_dir" || true)"
      [[ -n "$install_dir" ]] && rm -rf "$install_dir" 2>/dev/null || true
      rm -rf "$(agent_bearer_http_ext_dir "$config_dir")" 2>/dev/null || true
    fi
  fi

  echo "    (installing bearer-http plugin from ${plugin_spec}…)" >&2
  openclaw_agent_exec "$config_dir" "$container" plugins registry --refresh >&2 || true
  if [[ "$force" == "1" || ( -n "$desired_ver" && "$installed_ver" != "$desired_ver" ) || "$plugin_spec" == git:* || "$plugin_spec" == https://* || "$plugin_spec" == http://* ]]; then
    install_args+=(--force)
  fi

  if bearer_http_spec_is_remote "$plugin_spec"; then
    if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$plugin_spec" >&2; then
      return 1
    fi
  else
    # Local path: stage into mounted OpenClaw home so the container can see it.
    [[ -f "${plugin_spec}/openclaw.plugin.json" ]] || {
      echo "    (bearer-http: local plugin missing openclaw.plugin.json at ${plugin_spec})" >&2
      return 1
    }
    host_stage="${config_dir}/.bearer-http-plugin-build"
    container_stage="/home/node/.openclaw/.bearer-http-plugin-build"
    rm -rf "$host_stage"
    cp -a "$plugin_spec" "$host_stage" || return 1
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf "$container_stage" 2>/dev/null || true
      podman cp "$host_stage" "${container}:${container_stage}" >/dev/null || {
        rm -rf "$host_stage"
        return 1
      }
    fi
    if ! openclaw_agent_exec "$config_dir" "$container" plugins install "${install_args[@]}" "$container_stage" >&2; then
      rm -rf "$host_stage"
      return 1
    fi
    rm -rf "$host_stage"
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf "$container_stage" 2>/dev/null || true
    fi
  fi

  bearer_http_ext_ready "$config_dir" "$container" || {
    echo "    (bearer-http: install finished but extension tree is missing)" >&2
    return 1
  }

  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    link_bearer_http_plugin_deps_in_container "$container"
  else
    install_dir="$(bearer_http_resolve_install_dir_host "$config_dir" || true)"
    [[ -n "$install_dir" ]] && link_bearer_http_plugin_deps "$install_dir"
  fi
  ensure_bearer_http_plugin_config "$config_dir" "$container" || return 1
}

install_bearer_http_for_agent() {
  local id="$1"
  local force="${2:-0}"
  local config_dir container
  config_dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  echo "==> Installing bearer-http plugin for ${id}"
  install_bearer_http_plugin "$config_dir" "$force" "$id"
}
