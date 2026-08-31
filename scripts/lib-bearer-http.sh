#!/usr/bin/env bash
# Fleet install + config for @identyclaw/openclaw-identyclaw-httpbearer-plugin
# (guest bearer storage + http_request).
#
# Default source until ClawHub publish: GitHub
#   https://github.com/discernible-io/openclaw-identyclaw-httpbearer-plugin
# Then switch BEARER_HTTP_CLAWHUB_PLUGIN to clawhub:@identyclaw/...@x.y.z

bearer_http_plugin_id() {
  echo "bearer-http"
}

bearer_http_default_git_url() {
  # OpenClaw accepts git:github.com/owner/repo — not raw https://…git URLs.
  echo "git:github.com/discernible-io/openclaw-identyclaw-httpbearer-plugin"
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
    printf '%s\n' "$BEARER_HTTP_CLAWHUB_PLUGIN"
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

# Resolve install root: extensions/bearer-http (path) or ~/.openclaw/git/*/repo (git:).
bearer_http_resolve_install_dir() {
  local config_dir="$1"
  local container="${2:-}"
  local ext_dir candidate id_line
  ext_dir="$(agent_bearer_http_ext_dir "$config_dir")"
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    if podman exec "$container" test -f "$(agent_bearer_http_ext_dir_container)/openclaw.plugin.json" 2>/dev/null; then
      printf '%s\n' "$(agent_bearer_http_ext_dir_container)"
      return 0
    fi
    candidate="$(podman exec "$container" sh -c '
      for d in /home/node/.openclaw/git/*/repo; do
        [ -f "$d/openclaw.plugin.json" ] || continue
        grep -q "\"id\"[[:space:]]*:[[:space:]]*\"bearer-http\"" "$d/openclaw.plugin.json" 2>/dev/null || continue
        echo "$d"
        exit 0
      done
      exit 1
    ' 2>/dev/null || true)"
    [[ -n "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  if [[ -f "$ext_dir/openclaw.plugin.json" ]]; then
    printf '%s\n' "$ext_dir"
    return 0
  fi
  for candidate in "$config_dir"/git/*/repo; do
    [[ -f "$candidate/openclaw.plugin.json" ]] || continue
    if grep -q '"id"[[:space:]]*:[[:space:]]*"bearer-http"' "$candidate/openclaw.plugin.json" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

bearer_http_plugin_installed_version() {
  local config_dir="$1"
  local container="${2:-}"
  local root pkg pkg_json
  root="$(bearer_http_resolve_install_dir "$config_dir" "$container")" || return 0
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    pkg_json="$(podman exec "$container" cat "${root}/package.json" 2>/dev/null || true)"
    [[ -n "$pkg_json" ]] || return 0
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version",""))' "$pkg_json" 2>/dev/null || true
    return 0
  fi
  pkg="${root}/package.json"
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
  local root
  root="$(bearer_http_resolve_install_dir "$config_dir" "$container")" || return 1
  if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
    podman exec "$container" test \
      -f "${root}/openclaw.plugin.json" \
      -a \( -f "${root}/index.mjs" -o -f "${root}/dist/index.js" \)
    return $?
  fi
  [[ -f "$root/openclaw.plugin.json" ]] || return 1
  [[ -f "$root/index.mjs" || -f "$root/dist/index.js" ]]
}

link_bearer_http_plugin_deps() {
  local target="$1"
  [[ -d "$target" ]] || return 0
  mkdir -p "${target}/node_modules"
  rm -rf "${target}/node_modules/openclaw"
  ln -sf /app "${target}/node_modules/openclaw"
}

link_bearer_http_plugin_deps_in_container() {
  local container="$1"
  local config_dir="${2:-}"
  local root
  [[ -n "$container" ]] || return 0
  root="$(bearer_http_resolve_install_dir "${config_dir:-}" "$container")" || return 0
  podman exec "$container" bash -c "
    set -euo pipefail
    ext=$(printf '%q' "$root")
    [[ -d \"\$ext\" ]] || exit 0
    mkdir -p \"\$ext/node_modules\"
    rm -rf \"\$ext/node_modules/openclaw\"
    ln -sf /app \"\$ext/node_modules/openclaw\"
  " 2>/dev/null || true
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
  local host_stage container_stage

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
        link_bearer_http_plugin_deps_in_container "$container" "$config_dir"
      else
        link_bearer_http_plugin_deps "$(bearer_http_resolve_install_dir "$config_dir" || true)"
      fi
      return 0
    fi
  fi

  if [[ "$force" == "1" || ( -n "$desired_ver" && -n "$installed_ver" && "$installed_ver" != "$desired_ver" ) ]]; then
    if [[ -n "$container" ]] && _agent_container_name_running "$container"; then
      podman exec "$container" rm -rf "$(agent_bearer_http_ext_dir_container)" 2>/dev/null || true
    else
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
    link_bearer_http_plugin_deps_in_container "$container" "$config_dir"
  else
    link_bearer_http_plugin_deps "$(bearer_http_resolve_install_dir "$config_dir" || true)"
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
