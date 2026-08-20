#!/usr/bin/env bash
# openclaw.json, models, memory, security, LLM keys, export/import.
# Sourced from scripts/lib.sh — do not execute directly.

# Apply sticky OpenRouter session_id + diagnostics.cacheTrace (host or in-container).
_agent_openclaw_cache_config_patch() {
  local config_dir="$1"
  local container="${2:-}"
  local session_id="${3:-identyclaw}"
  local cache_trace="${4:-1}"
  local openrouter_enabled="${5:-1}"
  local patch_js="${IDENTYCLAW_ROOT}/scripts/patch-openclaw-cache-config.mjs"
  local lib_js="${IDENTYCLAW_ROOT}/scripts/lib-openclaw-cache-config.mjs"
  [[ -f "$patch_js" && -f "$lib_js" ]] || {
    echo "    (cache config patch scripts missing under ${IDENTYCLAW_ROOT}/scripts)" >&2
    return 1
  }
  if [[ -r "$config_dir/openclaw.json" && -w "$config_dir/openclaw.json" ]]; then
    node "$patch_js" "$config_dir/openclaw.json" \
      --session-id "$session_id" \
      --cache-trace "$cache_trace" \
      --openrouter "$openrouter_enabled" || return 1
    return 0
  fi
  if ensure_agent_host_config_access "$config_dir" 2>/dev/null \
    && [[ -r "$config_dir/openclaw.json" && -w "$config_dir/openclaw.json" ]]; then
    node "$patch_js" "$config_dir/openclaw.json" \
      --session-id "$session_id" \
      --cache-trace "$cache_trace" \
      --openrouter "$openrouter_enabled" || return 1
    return 0
  fi
  if agent_config_use_container "$config_dir" "$container"; then
    podman cp "$lib_js" "${container}:/tmp/lib-openclaw-cache-config.mjs" >/dev/null || return 1
    podman cp "$patch_js" "${container}:/tmp/patch-openclaw-cache-config.mjs" >/dev/null || return 1
    podman exec "$container" node /tmp/patch-openclaw-cache-config.mjs \
      /home/node/.openclaw/openclaw.json \
      --session-id "$session_id" \
      --cache-trace "$cache_trace" \
      --openrouter "$openrouter_enabled" || return 1
    return 0
  fi
  echo "    (cannot patch cache config — openclaw.json not writable and container ${container:-<none>} unavailable)" >&2
  return 1
}

# Apply OpenClaw tool-result image hotpatch into a running container's /app.
# Returns 0 if already patched / nothing to do, 2 if files changed (caller should
# podman-restart so Node reloads modules), 1 on hard failure.
apply_openclaw_tool_result_image_patch() {
  local id="$1"
  local container patch_src marker before after
  container="$(agent_container "$id")"
  patch_src="${IDENTYCLAW_ROOT}/scripts/patch-openclaw-tool-result-images.mjs"
  marker="identyclaw-tool-result-images-patch-v1"
  podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container" || return 0
  [[ -f "$patch_src" ]] || return 0

  before="$(podman exec "$container" python3 -c \
    "import pathlib; p=pathlib.Path('/app/node_modules/@openclaw/ai/dist/tool-result-text-CTpIRbYd.mjs'); print(1 if p.exists() and '$marker' in p.read_text(encoding='utf-8',errors='replace') else 0)" \
    2>/dev/null || echo 0)"

  podman cp "$patch_src" "$container:/tmp/patch-openclaw-tool-result-images.mjs" >/dev/null 2>&1 || return 1
  if ! podman exec --user root "$container" node /tmp/patch-openclaw-tool-result-images.mjs --root /app >/dev/null 2>&1; then
    echo "==> ${id}: tool-result image patch failed" >&2
    return 1
  fi

  after="$(podman exec "$container" python3 -c \
    "import pathlib; p=pathlib.Path('/app/node_modules/@openclaw/ai/dist/tool-result-text-CTpIRbYd.mjs'); print(1 if p.exists() and '$marker' in p.read_text(encoding='utf-8',errors='replace') else 0)" \
    2>/dev/null || echo 0)"
  if [[ "$before" != "1" && "$after" == "1" ]]; then
    return 2
  fi
  return 0
}


ensure_openclaw_tool_result_image_patch() {
  local id="$1"
  local container rc=0
  container="$(agent_container "$id")"
  apply_openclaw_tool_result_image_patch "$id" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    echo "==> ${id}: applied tool-result image patch — restarting to load modules"
    podman restart "$container" >/dev/null
    wait_for_running_agent_container "$container" || return 1
    # Writable layer persists across podman restart; re-check only.
    apply_openclaw_tool_result_image_patch "$id" || true
  elif [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  return 0
}


# List oversized session keys as "tokens<TAB>key" on stdout.
# mode=legacy → main/tui/heartbeat only (skips cron); mode=all → every session key.
_openclaw_list_oversized_sessions() {
  local container="$1"
  local token_floor="$2"
  local mode="${3:-all}"
  podman exec "$container" node dist/index.js sessions list --json --limit all 2>/dev/null | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"\{[\s\S]*\}\s*$", raw) or re.search(r"\[[\s\S]*\]\s*$", raw)
if not m:
    raise SystemExit(0)
data = json.loads(m.group(0))
sessions = data if isinstance(data, list) else (
    data.get("sessions") or data.get("items") or []
)
if isinstance(data, dict) and not sessions:
    for v in data.values():
        if isinstance(v, list):
            sessions = v
            break
floor = int(sys.argv[1])
mode = sys.argv[2]
for s in sessions:
    key = s.get("key") or s.get("sessionKey") or ""
    if not key:
        continue
    if mode == "legacy":
        if ":cron:" in key:
            continue
        if not (key.endswith(":main") or ":tui-" in key or ":main:heartbeat" in key):
            continue
    toks = s.get("totalTokens") or s.get("inputTokens") or 0
    usage = s.get("usage") or {}
    if not toks:
        toks = usage.get("totalTokens") or usage.get("input") or 0
    try:
        toks = int(toks or 0)
    except (TypeError, ValueError):
        toks = 0
    if toks >= floor:
        print(f"{toks}\t{key}")
' "$token_floor" "$mode"
}

_openclaw_compact_session_keys() {
  local id="$1"
  local container="$2"
  local max_lines="$3"
  local dry_run="${4:-0}"
  local toks key out compacted=0 failed=0
  while IFS=$'\t' read -r toks key; do
    [[ -n "$key" ]] || continue
    if [[ "$dry_run" == "1" ]]; then
      echo "    would compact ${key} (${toks} tokens → last ${max_lines} lines)"
      compacted=$((compacted + 1))
      continue
    fi
    echo "    compact ${key} (${toks} tokens)"
    if ! out="$(podman exec "$container" node dist/index.js sessions compact "$key" \
      --max-lines "$max_lines" --json 2>&1)"; then
      echo "    (${id}: compact failed for ${key}: ${out})" >&2
      failed=$((failed + 1))
      continue
    fi
    if echo "$out" | grep -q '"ok": false'; then
      echo "    (${id}: compact refused for ${key}: ${out})" >&2
      failed=$((failed + 1))
    else
      echo "    ok"
      compacted=$((compacted + 1))
    fi
  done
  echo "    (${id}: compact summary compacted=${compacted} failed=${failed})"
}

fix_openclaw_session_images() {
  local id="$1"
  local container max_lines token_floor
  container="$(agent_container "$id")"
  max_lines="${IDENTYCLAW_SESSION_COMPACT_MAX_LINES:-120}"
  token_floor="${IDENTYCLAW_SESSION_COMPACT_TOKEN_FLOOR:-80000}"

  agent_container_running "$id" || {
    echo "==> ${id}: container not running — skip" >&2
    return 1
  }

  echo "==> ${id}: patching OpenClaw tool-result image placeholder"
  ensure_openclaw_tool_result_image_patch "$id" || return 1
  podman exec --user root "$container" node /tmp/patch-openclaw-tool-result-images.mjs --root /app 2>&1 | tail -5 || true

  echo "==> ${id}: compacting long sessions (>= ${token_floor} tokens → last ${max_lines} lines)"
  _openclaw_list_oversized_sessions "$container" "$token_floor" legacy \
    | _openclaw_compact_session_keys "$id" "$container" "$max_lines" 0

  echo "==> ${id}: done"
}

# Daily / ops cleanup: truncate ALL oversized sessions (telegram, A2A/direct, cron, tui),
# optionally enforce session-store maintenance, and rotate huge cache-trace logs.
# Uses --max-lines (hard truncate) so LLM auto-compaction timeouts cannot block recovery.
cleanup_openclaw_sessions() {
  local id="$1"
  local dry_run="${2:-0}"
  local container max_lines token_floor store_cleanup cache_mb out size_bytes limit_bytes
  container="$(agent_container "$id")"
  max_lines="${IDENTYCLAW_SESSION_CLEANUP_MAX_LINES:-${IDENTYCLAW_SESSION_COMPACT_MAX_LINES:-120}}"
  token_floor="${IDENTYCLAW_SESSION_CLEANUP_TOKEN_FLOOR:-${IDENTYCLAW_SESSION_COMPACT_TOKEN_FLOOR:-50000}}"
  store_cleanup="${IDENTYCLAW_SESSION_CLEANUP_STORE:-1}"
  cache_mb="${IDENTYCLAW_SESSION_CLEANUP_CACHE_TRACE_MB:-200}"

  agent_container_running "$id" || {
    echo "==> ${id}: container not running — skip" >&2
    return 1
  }

  echo "==> ${id}: session cleanup (floor=${token_floor} tokens → last ${max_lines} lines; dry_run=${dry_run})"
  _openclaw_list_oversized_sessions "$container" "$token_floor" all \
    | _openclaw_compact_session_keys "$id" "$container" "$max_lines" "$dry_run"

  if [[ "$store_cleanup" == "1" || "$store_cleanup" == "true" ]]; then
    echo "==> ${id}: session store maintenance"
    if [[ "$dry_run" == "1" ]]; then
      out="$(podman exec "$container" node dist/index.js sessions cleanup --dry-run --json 2>&1 || true)"
      echo "$out" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"\{[\s\S]*\}\s*$", raw)
if not m:
    print(raw[-500:] if raw else "(no output)")
    raise SystemExit(0)
d = json.loads(m.group(0))
print(
    "    would mutate=%s before=%s after=%s pruned=%s capped=%s"
    % (
        d.get("wouldMutate"),
        d.get("beforeCount"),
        d.get("afterCount"),
        d.get("pruned"),
        d.get("capped"),
    )
)
' 2>/dev/null || echo "    (dry-run parse skipped)"
    else
      if ! out="$(podman exec "$container" node dist/index.js sessions cleanup --enforce --json 2>&1)"; then
        echo "    (${id}: sessions cleanup failed: ${out})" >&2
      else
        echo "$out" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"\{[\s\S]*\}\s*$", raw)
if not m:
    print("    ok")
    raise SystemExit(0)
d = json.loads(m.group(0))
print(
    "    before=%s after=%s pruned=%s capped=%s"
    % (
        d.get("beforeCount"),
        d.get("afterCount"),
        d.get("pruned"),
        d.get("capped"),
    )
)
' 2>/dev/null || echo "    ok"
      fi
    fi
  fi

  # Rotate oversized prompt-cache traces (disk only; not chat context).
  if [[ "$cache_mb" != "0" && "$cache_mb" != "off" ]]; then
    limit_bytes=$((cache_mb * 1024 * 1024))
    size_bytes="$(podman exec "$container" sh -c \
      'wc -c </home/node/.openclaw/logs/cache-trace.jsonl 2>/dev/null || echo 0' | tr -d '[:space:]')"
    size_bytes="${size_bytes:-0}"
    if [[ "$size_bytes" =~ ^[0-9]+$ ]] && (( size_bytes > limit_bytes )); then
      if [[ "$dry_run" == "1" ]]; then
        echo "    would rotate cache-trace.jsonl ($((size_bytes / 1024 / 1024))MB > ${cache_mb}MB)"
      else
        echo "==> ${id}: rotating cache-trace.jsonl ($((size_bytes / 1024 / 1024))MB > ${cache_mb}MB)"
        podman exec "$container" sh -c '
          f=/home/node/.openclaw/logs/cache-trace.jsonl
          if [ -f "$f" ]; then
            mv -f "$f" "${f}.1" 2>/dev/null || rm -f "$f"
            : >"$f"
            chmod 600 "$f" 2>/dev/null || true
          fi
        ' || echo "    (${id}: cache-trace rotate failed)" >&2
      fi
    fi
  fi

  echo "==> ${id}: cleanup done"
}


ensure_agent_bootstrap() {
  local id="$1"
  local config_dir="$2"
  local container
  container="$(agent_container "$id")"
  ensure_mail_secrets_from_env "$id" "$config_dir"
  ensure_agent_mail_tooling_refresh "$id" "$config_dir"
  ensure_instagram_secrets_from_env "$id" "$config_dir"
  ensure_twitter_secrets_from_env "$id" "$config_dir"
  ensure_discord_secrets_from_env "$id" "$config_dir"
  ensure_telegram_secrets_from_env "$id" "$config_dir"
  ensure_inbox_heartbeat_from_env "$id" "$config_dir"
  ensure_slc_heartbeat_from_env "$id" "$config_dir"
  ensure_linkedin_clawlink_skill "$id" "$config_dir"
  ensure_near_credentials_layout "$config_dir"
  ensure_idcp_wallet_tooling "$id" "$config_dir" "$container"
  ensure_calendar_reminders "$id" "$config_dir" "$container"
  ensure_discord_guild_channels "$config_dir" "$container"
  ensure_discord_ready "$id" "$config_dir"
  ensure_identyclaw_config "$config_dir" "$container"
  ensure_openclaw_model_defaults "$config_dir" "$container"
  ensure_memory_config "$config_dir" "$container"
  ensure_session_maintenance_config "$config_dir" "$container"
  if agent_has_near_credentials "$config_dir"; then
    ensure_a2a_plugin_build "$id"
  fi
  ensure_a2a_config "$id" "$config_dir" "$container"
  ensure_agent_identyclaw_tooling "$id" "$config_dir"
  if podman ps --format '{{.Names}}' | grep -qx "$container"; then
    ensure_llm_sqlite_auth "$id"
  fi
  write_agent_browser_doc "$config_dir"
  sync_quiet_plugin_env "$config_dir" "$container"
  ensure_main_ingress_config "$id" "$config_dir" "$container"
  ensure_agent_security_hardening "$id" "$config_dir" "$container"
  if [[ ! -f "$config_dir/secrets/imap.pass" ]]; then
    echo "Note: ${id} has no Migadu password yet — run: ./identyclaw.sh set-password ${id}" >&2
  fi
}

# Store Migadu IMAP/SMTP password. Writes on host when secrets/ is writable;
# otherwise falls back to the running container (pod UID ownership).

# Let peer agents reach the other gateway when a bot message @mentions them.
# Keep rootless agents running after logout (linger) and across reboot (podman-restart).
ensure_agent_persistence() {
  local user linger
  user="$(whoami)"
  linger="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
  if [[ "$linger" != "yes" ]]; then
    echo "Note: agents may stop when you log out. Run once: ./identyclaw.sh enable-boot (enables linger; needs sudo)" >&2
    return 0
  fi
  if ! systemctl --user is-enabled podman-restart.service &>/dev/null; then
    echo "Enabling podman-restart.service (starts --restart always containers after reboot)..."
    systemctl --user enable --now podman-restart.service
  fi
}


ensure_internal_gateway_port() {
  local config_dir="$1"
  local host_gateway_port="$2"
  local internal_port="${3:-}"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  load_env
  [[ -n "$internal_port" ]] || internal_port="$(agent_internal_gateway_port "$(agent_id_from_dir "$config_dir")")"
  python3 - "$config" "$host_gateway_port" "$internal_port" <<'PY'
import json, sys
from pathlib import Path

path, host_port, internal_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = json.loads(Path(path).read_text(encoding="utf-8"))
gateway = data.setdefault("gateway", {})
changed = False
if gateway.get("port") != internal_port:
    gateway["port"] = internal_port
    changed = True
origins = gateway.setdefault("controlUi", {}).setdefault("allowedOrigins", [])
for origin in (
    f"http://127.0.0.1:{host_port}",
    f"http://localhost:{host_port}",
    f"http://127.0.0.1:{internal_port}",
    f"http://localhost:{internal_port}",
):
    if origin not in origins:
        origins.append(origin)
        changed = True
if changed:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    Path(path).chmod(0o600)
PY
}


ensure_main_ingress_config() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  load_env
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  local public_url internal_port ingress_port
  public_url="$(agent_ingress_base_url "$id")"
  internal_port="$(agent_internal_gateway_port "$id")"
  ingress_port="$(agent_ingress_port "$id")"
  _agent_openclaw_json_python "$config_dir" "$container" \
    "$public_url" "$internal_port" "$ingress_port" <<'PY'
import json, sys
from pathlib import Path

path, public_url, internal_port, ingress_port = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = json.loads(Path(path).read_text(encoding="utf-8"))
gateway = data.setdefault("gateway", {})
changed = False
if gateway.get("bind") != "lan":
    gateway["bind"] = "lan"
    changed = True
if gateway.get("port") != internal_port:
    gateway["port"] = internal_port
    changed = True
origins = gateway.setdefault("controlUi", {}).setdefault("allowedOrigins", [])
candidates = [
    f"http://127.0.0.1:{internal_port}",
    f"http://localhost:{internal_port}",
]
if public_url:
    candidates.append(public_url)
    candidates.append(public_url.replace(f":{ingress_port}", "", 1))
for origin in candidates:
    if origin and origin not in origins:
        origins.append(origin)
        changed = True
if changed:
    Path(path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    Path(path).chmod(0o600)
PY
}


ensure_agent_security_hardening() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  local env_file="$config_dir/.env"
  if agent_env_use_container "$config_dir" "$container"; then
    env_file="/home/node/.openclaw/.env"
  else
    ensure_agent_env "$config_dir"
  fi
  _agent_openclaw_json_python "$config_dir" "$container" "$env_file" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
env_path = Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
changed = False

token = ""
if env_path.is_file():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("OPENCLAW_GATEWAY_TOKEN="):
            token = line.split("=", 1)[1].strip()
            break
if not token:
    token = (data.get("gateway", {}).get("auth", {}) or {}).get("token") or ""

gateway = data.setdefault("gateway", {})
auth = gateway.setdefault("auth", {})
if token:
    if auth.get("mode") != "token" or auth.get("token") != token:
        auth["mode"] = "token"
        auth["token"] = token
        changed = True
rate = auth.setdefault(
    "rateLimit",
    {"maxAttempts": 10, "windowMs": 60000, "lockoutMs": 300000},
)
desired_rate = {"maxAttempts": 10, "windowMs": 60000, "lockoutMs": 300000}
if rate != desired_rate:
    auth["rateLimit"] = desired_rate
    changed = True

session = data.setdefault("session", {})
if session.get("dmScope") != "per-channel-peer":
    session["dmScope"] = "per-channel-peer"
    changed = True

tools = data.setdefault("tools", {})
exec_cfg = tools.setdefault("exec", {})
# ask on-miss + stream-filter safeBins; sed cannot be a safeBin (OpenClaw denies it)
# so it is allowlisted via exec-approvals. strictInlineEval must stay off for sed -n/-e
# programs or every sed still prompts (TUI can hang with no visible approval card).
# Prefer writing node/python scripts over -e; interpreters are not auto-allowlisted.
exec_defaults = {
    "ask": "on-miss",
    "strictInlineEval": False,
}
for key, val in exec_defaults.items():
    if exec_cfg.get(key) != val:
        exec_cfg[key] = val
        changed = True
for legacy_key in ("mode", "security"):
    if legacy_key in exec_cfg:
        del exec_cfg[legacy_key]
        changed = True
# Default OpenClaw stream filters + keep himalaya path allowlisted separately.
# Do NOT put sh/node in safeBins — unprofiled interpreters are ignored and unsafe.
safe_bins = exec_cfg.setdefault("safeBins", [])
desired_safe = ["cut", "uniq", "head", "tail", "tr", "wc", "himalaya"]
for name in desired_safe:
    if name not in safe_bins:
        safe_bins.append(name)
        changed = True
for legacy_bin in ("sh", "node"):
    if legacy_bin in safe_bins:
        safe_bins.remove(legacy_bin)
        changed = True
profiles = exec_cfg.setdefault("safeBinProfiles", {})
# himalaya is not stdin-only; empty profile opts into doctor scaffolding without
# pretending it is a stream filter. Prefer allowlist path when available.
if "himalaya" not in profiles:
    profiles["himalaya"] = {}
    changed = True

PUBLIC_CHANNEL_TOOLS = [
    "read",
    "group:memory",
    "identyclaw_list_agents",
    "identyclaw_list_resources",
    "identyclaw_get_resource",
    "identyclaw_verify_hola",
    "identyclaw_create_hola",
    "identyclaw_get_nonce",
    "memory_search",
    "memory_get",
]
DANGEROUS_TOOLS = {
    "exec",
    "write",
    "edit",
    "browser",
    "a2a_send_message",
    "send_rodit_webhook",
    "sessions_send",
    "clawlink_call_tool",
    "clawlink_preview_tool",
    "clawlink_start_connection",
}

channels = data.get("channels", {})
tbs = tools.setdefault("toolsBySender", {})
for channel_name, sender_key in (
    ("telegram", "channel:telegram:*"),
    ("discord", "channel:discord:*"),
):
    ch = channels.get(channel_name, {})
    if not isinstance(ch, dict) or not ch.get("enabled"):
        continue
    entry = tbs.setdefault(sender_key, {})
    allow = list(entry.get("allow") or PUBLIC_CHANNEL_TOOLS)
    merged = []
    seen = set()
    for tool in allow + PUBLIC_CHANNEL_TOOLS:
        if tool in DANGEROUS_TOOLS or tool in seen:
            continue
        merged.append(tool)
        seen.add(tool)
    if merged != allow:
        entry["allow"] = merged
        changed = True

owners = (data.get("commands", {}) or {}).get("ownerAllowFrom") or []
telegram_approvers = []
discord_approvers = []
for owner in owners:
    if not isinstance(owner, str):
        continue
    if owner.startswith("telegram:"):
        telegram_approvers.append(owner.split(":", 1)[1])
    elif owner.startswith("discord:"):
        discord_approvers.append(owner.split(":", 1)[1])

if telegram_approvers and channels.get("telegram", {}).get("enabled"):
    tg = channels.setdefault("telegram", {})
    ea = tg.setdefault("execApprovals", {})
    desired = {"enabled": True, "approvers": telegram_approvers, "target": "dm"}
    if ea != desired:
        tg["execApprovals"] = desired
        changed = True

if discord_approvers and channels.get("discord", {}).get("enabled"):
    dc = channels.setdefault("discord", {})
    ea = dc.setdefault("execApprovals", {})
    desired = {"enabled": True, "approvers": discord_approvers, "target": "dm"}
    if ea != desired:
        dc["execApprovals"] = desired
        changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
  ensure_exec_allowlist_harmless_bins "$config_dir" "$container"
}

# sed cannot be a safeBin (OpenClaw always denies it); allowlist resolved paths instead.
# OpenClaw 2026.7.1+ stores approvals in state/openclaw.sqlite. Any leftover
# exec-approvals.json trips ExecApprovalsMigrationRequiredError: doctor keeps the
# canonical SQLite row and will not delete conflicting legacy JSON, so runtimes
# fail closed until the file is gone. Never recreate it; retire leftovers and
# merge sed/head via `approvals allowlist add` when the gateway is up.

# sed cannot be a safeBin (OpenClaw always denies it); allowlist resolved paths instead.
# OpenClaw 2026.7.1+ stores approvals in state/openclaw.sqlite. Any leftover
# exec-approvals.json trips ExecApprovalsMigrationRequiredError: doctor keeps the
# canonical SQLite row and will not delete conflicting legacy JSON, so runtimes
# fail closed until the file is gone. Never recreate it; retire leftovers and
# merge sed/head via `approvals allowlist add` when the gateway is up.
_retire_legacy_exec_approvals_json() {
  local path_arg="$1"
  python3 - "$path_arg" <<'PY' || true
from pathlib import Path
import sys
path = Path(sys.argv[1])
try:
    if not path.is_file():
        raise SystemExit(0)
except OSError:
    raise SystemExit(0)
retired = path.with_name(path.name + ".identyclaw-retired")
try:
    path.replace(retired)
except OSError:
    try:
        path.unlink()
    except OSError:
        pass
PY
}

# Host often cannot stat container-owned agent dirs (EACCES). Always retire
# inside the running container — same path the entrypoint uses on every start.

# Host often cannot stat container-owned agent dirs (EACCES). Always retire
# inside the running container — same path the entrypoint uses on every start.
_retire_legacy_exec_approvals_in_container() {
  local container="$1"
  [[ -n "$container" ]] || return 0
  podman exec "$container" sh -c '
    f=/home/node/.openclaw/exec-approvals.json
    [ -f "$f" ] || exit 0
    mv -f "$f" "${f}.identyclaw-retired" || rm -f "$f" || true
  ' >/dev/null 2>&1 || true
}


ensure_exec_allowlist_harmless_bins() {
  local config_dir="$1"
  local container="${2:-}"
  local approvals="${config_dir}/exec-approvals.json"
  local gw_port=""
  local agent_id=""
  [[ -d "$config_dir" ]] || return 0
  agent_id="$(agent_id_from_dir "$config_dir" 2>/dev/null || true)"
  if [[ -n "$agent_id" ]]; then
    gw_port="$(agent_internal_gateway_port "$agent_id" 2>/dev/null || true)"
  fi
  gw_port="${gw_port:-18789}"
  # Host cannot stat container-owned agent dirs (EACCES traceback). Retire in-container.
  if [[ -n "$container" ]] && podman container exists "$container" >/dev/null 2>&1; then
    _retire_legacy_exec_approvals_in_container "$container"
  else
    _retire_legacy_exec_approvals_json "$approvals"
  fi
  [[ -n "$container" ]] && podman container exists "$container" >/dev/null 2>&1 || return 0
  local token=""
  token="$(podman exec "$container" python3 -c 'import json;print(json.load(open("/home/node/.openclaw/openclaw.json")).get("gateway",{}).get("auth",{}).get("token") or "")' 2>/dev/null || true)"
  [[ -n "$token" ]] || return 0
  for pattern in /usr/bin/sed /bin/sed /usr/bin/head /bin/head; do
    if command -v timeout >/dev/null 2>&1; then
      timeout 8 podman exec -e OPENCLAW_GATEWAY_TOKEN="$token" "$container" \
        node dist/index.js approvals allowlist add --agent main "$pattern" \
        --url "ws://127.0.0.1:${gw_port}" --token "$token" >/dev/null 2>&1 || true
    else
      podman exec -e OPENCLAW_GATEWAY_TOKEN="$token" "$container" \
        node dist/index.js approvals allowlist add --agent main "$pattern" \
        --url "ws://127.0.0.1:${gw_port}" --token "$token" >/dev/null 2>&1 || true
    fi
  done
}

# Retire leftover exec-approvals.json for one agent (running container or host path).

# Retire leftover exec-approvals.json for one agent (running container or host path).
retire_legacy_exec_approvals_one() {
  local id="${1:?}"
  local container dir result=""
  load_env
  container="$(agent_container "$id")"
  dir="$(agent_home "$id")"
  if _agent_container_name_running "$container"; then
    result="$(podman exec "$container" python3 -c '
from pathlib import Path
p = Path("/home/node/.openclaw/exec-approvals.json")
if p.is_file():
    p.replace(p.with_name(p.name + ".identyclaw-retired"))
    print("retired leftover exec-approvals.json")
else:
    print("already gone")
' 2>/dev/null || echo "podman exec failed")"
    ensure_exec_allowlist_harmless_bins "$dir" "$container" || true
    printf '%s: %s\n' "$id" "$result"
    return 0
  fi
  _retire_legacy_exec_approvals_json "${dir}/exec-approvals.json"
  if [[ -e "${dir}/exec-approvals.json" ]]; then
    printf '%s: leftover still present (container not running; host rename failed)\n' "$id"
  elif [[ -e "${dir}/exec-approvals.json.identyclaw-retired" ]]; then
    printf '%s: retired on host (container not running)\n' "$id"
  else
    printf '%s: already gone (container not running)\n' "$id"
  fi
}

# Copy nginx/inc from the current git checkout into APP_DIR and render nginx.conf.
# Sidecar bind mounts must use APP_DIR only — never the clone path — so a repo
# rename/move or CI rebuild cannot leave nginx pointing at a missing directory.


ensure_openclaw_model_defaults() {
  local config_dir="$1"
  local container="${2:-}"
  local providers_csv openrouter_enabled=0
  load_env
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  providers_csv="$(openclaw_model_chain_providers_csv)"
  case ",${providers_csv}," in
    *,openrouter,*) openrouter_enabled=1 ;;
  esac
  _agent_openclaw_json_python "$config_dir" "$container" \
    "$OPENCLAW_MODEL_PRIMARY" "$OPENCLAW_MODEL_FALLBACK_1" "$OPENCLAW_MODEL_FALLBACK_2" \
    "$OPENCLAW_AGENT_TIMEOUT_SECONDS" "$OPENCLAW_MODEL_PROVIDER_TIMEOUT_SECONDS" \
    "$providers_csv" \
    "$OPENCLAW_STUCK_SESSION_WARN_MS" "$OPENCLAW_STUCK_SESSION_ABORT_MS" \
    "$OPENCLAW_THINKING_DEFAULT" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
primary, fb1, fb2 = sys.argv[2:5]
agent_timeout = int(sys.argv[5])
provider_timeout = int(sys.argv[6])
providers_csv = sys.argv[7] if len(sys.argv) > 7 else "openrouter"
stuck_warn_ms = int(sys.argv[8]) if len(sys.argv) > 8 else 300000
stuck_abort_ms = int(sys.argv[9]) if len(sys.argv) > 9 else 900000
thinking_default = (sys.argv[10] if len(sys.argv) > 10 else "off").strip().lower() or "off"
allowed_thinking = {
    "off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max",
}
if thinking_default not in allowed_thinking:
    thinking_default = "off"
provider_ids = [p.strip() for p in providers_csv.split(",") if p.strip()]
fallbacks = [fb1, fb2]
allowlist = {primary: {}, fb1: {}, fb2: {}}
known_llm_plugins = {"openrouter", "opencode", "opencode-go"}

def model_tail(model_id: str) -> str:
    return model_id.split("/", 1)[1] if "/" in model_id else model_id

paid_fallback = model_tail(fb2)

data = json.loads(path.read_text(encoding="utf-8"))
defaults = data.setdefault("agents", {}).setdefault("defaults", {})
defaults.setdefault("workspace", "/home/node/.openclaw/workspace")
defaults["models"] = allowlist
defaults["model"] = {"primary": primary, "fallbacks": fallbacks}
defaults["timeoutSeconds"] = agent_timeout
defaults["thinkingDefault"] = thinking_default

providers = data.setdefault("models", {}).setdefault("providers", {})
plugins = data.setdefault("plugins", {}).setdefault("entries", {})
for pid in provider_ids:
    providers.setdefault(pid, {})["timeoutSeconds"] = provider_timeout
for pid in known_llm_plugins:
    if pid in provider_ids:
        plugins.setdefault(pid, {})["enabled"] = True
    elif pid in plugins:
        plugins[pid]["enabled"] = False

# OpenClaw 2026.7.2+ rejects stuckSessionWarnMs/AbortMs — strip if present from older syncs.
diagnostics = data.get("diagnostics")
if isinstance(diagnostics, dict):
    for k in ("stuckSessionWarnMs", "stuckSessionAbortMs"):
        diagnostics.pop(k, None)
    cache_trace = diagnostics.get("cacheTrace")
    if isinstance(cache_trace, dict):
        for k in ("includeMessages", "includePrompt", "includeSystem"):
            cache_trace.pop(k, None)

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)

sessions_path = path.parent / "agents/main/sessions/sessions.json"
if not sessions_path.is_file():
    raise SystemExit(0)

sessions = json.loads(sessions_path.read_text(encoding="utf-8"))
changed = False
for entry in sessions.values():
    if not isinstance(entry, dict):
        continue
    # Drop sticky /think session overrides so thinkingDefault applies on restart.
    for key in ("thinkingLevel", "thinking", "thinkingDefault"):
        if key in entry:
            entry.pop(key, None)
            changed = True
    # Drop sticky model pins that are outside the configured chain (e.g. former
    # openrouter/auto primary that 400s on tool schemas), plus paid-fallback pins.
    allow_ids = set(allowlist.keys())
    allow_tails = {model_tail(m) for m in allow_ids}
    model = entry.get("model")
    model_s = str(model) if model else ""
    override = entry.get("modelOverride")
    override_s = str(override) if override else ""
    origin = entry.get("modelOverrideFallbackOriginModel")
    origin_s = str(origin) if origin else ""
    stale = False
    if model_s:
        stale = (
            model_s == paid_fallback
            or model_s == fb2
            or model_tail(model_s) == paid_fallback
            or (
                model_s not in allow_ids
                and model_tail(model_s) not in allow_tails
            )
            or model_s.endswith("/auto")
            or model_tail(model_s) == "auto"
        )
    if "openrouter" not in provider_ids and model_s.startswith("openrouter/"):
        stale = True
    if origin_s and (
        origin_s not in allow_ids
        or origin_s.endswith("/auto")
        or model_tail(origin_s) == "auto"
    ):
        for key in (
            "modelOverride",
            "modelOverrideSource",
            "modelOverrideFallbackOriginProvider",
            "modelOverrideFallbackOriginModel",
            "fallbackNoticeSelectedModel",
            "fallbackNoticeActiveModel",
        ):
            if key in entry:
                entry.pop(key, None)
                changed = True
    if override_s and override_s not in allow_ids and model_tail(override_s) not in allow_tails:
        for key in (
            "modelOverride",
            "modelOverrideSource",
            "modelOverrideFallbackOriginProvider",
            "modelOverrideFallbackOriginModel",
            "fallbackNoticeSelectedModel",
            "fallbackNoticeActiveModel",
        ):
            if key in entry:
                entry.pop(key, None)
                changed = True
    if stale:
        entry.pop("model", None)
        entry.pop("modelProvider", None)
        entry.pop("modelOverrideSource", None)
        changed = True

if changed:
    sessions_path.write_text(json.dumps(sessions, indent=2) + "\n", encoding="utf-8")
    sessions_path.chmod(0o600)
PY
  # Sticky OpenRouter session_id (body + x-session-id) + diagnostics.cacheTrace.
  _agent_openclaw_cache_config_patch "$config_dir" "$container" \
    "${OPENCLAW_OPENROUTER_SESSION_ID:-identyclaw}" \
    "${OPENCLAW_CACHE_TRACE:-1}" \
    "$openrouter_enabled" || true
}


ensure_memory_config() {
  local config_dir="$1"
  local container="${2:-}"
  load_env
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" \
    "${IDENTYCLAW_DREAMING_ENABLED:-1}" \
    "${IDENTYCLAW_DREAMING_FREQUENCY:-0 3 * * *}" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
dreaming_enabled = sys.argv[2] == "1"
dreaming_frequency = (sys.argv[3] or "0 3 * * *").strip() or "0 3 * * *"

data = json.loads(path.read_text(encoding="utf-8"))
changed = False

memory = data.setdefault("memory", {})
# Builtin SQLite engine only. QMD is a breaking removal: drop retired keys so
# leftover memory.backend=qmd cannot spawn a missing binary after image rebuild.
if memory.get("backend") != "builtin":
    memory["backend"] = "builtin"
    changed = True
if "qmd" in memory:
    del memory["qmd"]
    changed = True

# OpenClaw 2026.7.1 rejects memory.search (gateway: "memory: Invalid input").
# OpenClaw 2026.7.2+ accepts memory.search and rejects agents.defaults.memorySearch.
# Keep config valid for the image we ship (2026.7.1-2): never write memory.search;
# drop legacy memorySearch / memory.search so restart cannot brick the gateway.
agents = data.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
if "memorySearch" in defaults:
    del defaults["memorySearch"]
    changed = True
if "search" in memory:
    del memory["search"]
    changed = True

# Strip keys rejected by OpenClaw 2026.7.2+ config schema (harmless on 2026.7.1).
meta = data.get("meta")
if isinstance(meta, dict) and "lastTouchedAt" in meta:
    del meta["lastTouchedAt"]
    changed = True
diagnostics = data.get("diagnostics")
if isinstance(diagnostics, dict):
    for k in ("stuckSessionWarnMs", "stuckSessionAbortMs"):
        if k in diagnostics:
            del diagnostics[k]
            changed = True
    cache_trace = diagnostics.get("cacheTrace")
    if isinstance(cache_trace, dict):
        for k in ("includeMessages", "includePrompt", "includeSystem"):
            if k in cache_trace:
                del cache_trace[k]
                changed = True

hooks = data.setdefault("hooks", {}).setdefault("internal", {})
entries = hooks.setdefault("entries", {})
entry = entries.setdefault("session-memory", {})
if hooks.get("enabled") is not True:
    hooks["enabled"] = True
    changed = True
if entry.get("enabled") is not True:
    entry["enabled"] = True
    changed = True

tools = data.setdefault("tools", {})
sessions_tool = tools.setdefault("sessions", {})
if sessions_tool.get("visibility") != "agent":
    sessions_tool["visibility"] = "agent"
    changed = True

# memory-core dreaming: overnight consolidation into MEMORY.md (not per-turn LLM).
# Leave plugins.entries.active-memory unset/off — escalate/always costs latency + tokens.
plugins = data.setdefault("plugins", {})
plugin_entries = plugins.setdefault("entries", {})
memory_core = plugin_entries.setdefault("memory-core", {})
mc_config = memory_core.setdefault("config", {})
dreaming = mc_config.setdefault("dreaming", {})
if dreaming.get("enabled") is not dreaming_enabled:
    dreaming["enabled"] = dreaming_enabled
    changed = True
if dreaming_enabled and dreaming.get("frequency") != dreaming_frequency:
    dreaming["frequency"] = dreaming_frequency
    changed = True
elif not dreaming_enabled and "frequency" in dreaming:
    # Keep frequency when disabling so re-enable restores the same cadence.
    pass

# Do not enable Active Memory here. If present and explicitly enabled, leave operator choice.

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


ensure_session_maintenance_config() {
  local config_dir="$1"
  local container="${2:-}"
  load_env
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" \
    "${IDENTYCLAW_SESSION_MAINTENANCE_MODE:-warn}" \
    "${IDENTYCLAW_SESSION_MAINTENANCE_PRUNE_AFTER:-36500d}" \
    "${IDENTYCLAW_SESSION_MAINTENANCE_MAX_ENTRIES:-100000}" \
    "${IDENTYCLAW_SESSION_MAINTENANCE_MAX_DISK_BYTES:-false}" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
mode = (sys.argv[2] or "warn").strip().lower()
prune_after = (sys.argv[3] or "36500d").strip()
max_entries_raw = (sys.argv[4] or "100000").strip()
max_disk_raw = (sys.argv[5] or "false").strip()

if mode not in ("warn", "enforce"):
    mode = "warn"

try:
    max_entries = int(max_entries_raw)
except ValueError:
    max_entries = 100000
if max_entries < 1:
    max_entries = 100000

if max_disk_raw.lower() in ("", "false", "0", "off", "none", "disable", "disabled"):
    max_disk = False
elif max_disk_raw.isdigit():
    max_disk = int(max_disk_raw)
else:
    max_disk = max_disk_raw

data = json.loads(path.read_text(encoding="utf-8"))
changed = False

session = data.setdefault("session", {})
maintenance = session.setdefault("maintenance", {})
desired = {
    "mode": mode,
    "pruneAfter": prune_after,
    "maxEntries": max_entries,
}
# OpenClaw schema: maxDiskBytes is string|number|omit — boolean false is invalid.
# Omit the key to disable per-agent session disk eviction.
if max_disk is not False:
    desired["maxDiskBytes"] = max_disk
for key, val in desired.items():
    if maintenance.get(key) != val:
        maintenance[key] = val
        changed = True

# highWaterBytes only applies when a disk budget is set.
if max_disk is False:
    for key in ("maxDiskBytes", "highWaterBytes"):
        if key in maintenance:
            del maintenance[key]
            changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}

# Pod agents may own openclaw.json on the host — sync repo-managed settings after the gateway is up.

# Pod agents may own openclaw.json on the host — sync repo-managed settings after the gateway is up.
sync_agent_openclaw_json_when_container_running() {
  local id="$1"
  local restart="${2:-1}"
  local dir container
  load_env
  dir="$(agent_home "$id")"
  container="$(agent_container "$id")"
  wait_for_running_agent_container "$container" || return 1
  ensure_agent_security_hardening "$id" "$dir" "$container"
  ensure_main_ingress_config "$id" "$dir" "$container"
  ensure_openclaw_model_defaults "$dir" "$container"
  ensure_memory_config "$dir" "$container"
  ensure_session_maintenance_config "$dir" "$container"
  sync_quiet_plugin_env "$dir" "$container"
  if [[ "$restart" == "1" ]]; then
    podman restart "$container" >/dev/null
  fi
}


ensure_session_memory_hook() {
  ensure_memory_config "$@"
}


write_openclaw_json() {
  local config_dir="$1"
  local gateway_port="$2"
  if [[ -f "$config_dir/openclaw.json" ]]; then
    return 0
  fi
  load_env
  cat >"$config_dir/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_CONTAINER_GATEWAY_PORT},
    "controlUi": {
      "allowedOrigins": [
        "http://127.0.0.1:${gateway_port}",
        "http://localhost:${gateway_port}"
      ]
    }
  },
  "session": {
    "dmScope": "per-channel-peer",
    "maintenance": {
      "mode": "${IDENTYCLAW_SESSION_MAINTENANCE_MODE:-warn}",
      "pruneAfter": "${IDENTYCLAW_SESSION_MAINTENANCE_PRUNE_AFTER:-36500d}",
      "maxEntries": ${IDENTYCLAW_SESSION_MAINTENANCE_MAX_ENTRIES:-100000}
    }
  },
  "skills": {
    "entries": {
      "himalaya": { "enabled": true },
      "identyclaw": { "enabled": true },
      "calendar-reminders": { "enabled": true }
    }
  },
  "tools": {
    "exec": {
      "ask": "on-miss",
      "strictInlineEval": false,
      "safeBins": ["cut", "uniq", "head", "tail", "tr", "wc", "himalaya"],
      "safeBinProfiles": {
        "himalaya": {}
      }
    },
    "allow": [
      "exec",
      "read",
      "write",
      "edit",
      "message",
      "browser",
      "sessions_list",
      "sessions_history",
      "sessions_send"
    ],
    "sessions": {
      "visibility": "agent"
    }
  },
  "plugins": {
    "entries": {
      "browser": {
        "enabled": true
      },
      "discord": {
        "enabled": true
      },
      "openrouter": {
        "enabled": true
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "timeoutSeconds": ${OPENCLAW_AGENT_TIMEOUT_SECONDS:-600},
      "thinkingDefault": "${OPENCLAW_THINKING_DEFAULT:-off}",
      "models": {
        "${OPENCLAW_MODEL_PRIMARY}": {},
        "${OPENCLAW_MODEL_FALLBACK_1}": {},
        "${OPENCLAW_MODEL_FALLBACK_2}": {}
      },
      "model": {
        "primary": "${OPENCLAW_MODEL_PRIMARY}",
        "fallbacks": [
          "${OPENCLAW_MODEL_FALLBACK_1}",
          "${OPENCLAW_MODEL_FALLBACK_2}"
        ]
      }
    }
  },
  "models": {
    "providers": {
      "openrouter": {
        "timeoutSeconds": ${OPENCLAW_MODEL_PROVIDER_TIMEOUT_SECONDS:-240}
      }
    }
  },
  "memory": {
    "backend": "builtin"
  },
  "hooks": {
    "internal": {
      "enabled": true,
      "entries": {
        "session-memory": { "enabled": true }
      }
    }
  }
}
EOF
  chmod 600 "$config_dir/openclaw.json"
  ensure_openclaw_model_defaults "$config_dir" ""
  ensure_memory_config "$config_dir" ""
  ensure_session_maintenance_config "$config_dir" ""
}


ensure_agent_env() {
  local config_dir="$1"
  local env_file="$config_dir/.env"
  # Pod agents chown state to the container uid (0700). Host cannot create or append
  # .env here — OPENCLAW_GATEWAY_TOKEN is already in the container-mounted .env.
  if [[ ! -w "$config_dir" ]] 2>/dev/null; then
    return 0
  fi
  if [[ -f "$env_file" ]] && grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$env_file" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$env_file" && ! -w "$env_file" ]] 2>/dev/null; then
    return 0
  fi
  local token
  token="$(generate_token)"
  mkdir -p "$config_dir"
  if [[ -f "$env_file" ]]; then
    grep -v '^OPENCLAW_GATEWAY_TOKEN=' "$env_file" >"$env_file.tmp" || true
    mv "$env_file.tmp" "$env_file"
  fi
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$token" >>"$env_file"
  chmod 600 "$env_file"
}


ensure_openclaw_cli_link() {
  local container="$1"
  podman exec -u 0 "$container" ln -sf /app/openclaw.mjs /openclaw.mjs 2>/dev/null || true
}


validate_openrouter_api_key() {
  local key="$1"
  [[ "$key" == sk-or-* ]] || {
    echo "OpenRouter API keys start with sk-or- (got something else — check you did not paste a shell command)." >&2
    return 1
  }
}

# OpenClaw 2026.6+ reads model auth from openclaw-agent.sqlite; legacy auth-profiles.json alone is ignored.

# OpenClaw 2026.6+ reads model auth from openclaw-agent.sqlite; legacy auth-profiles.json alone is ignored.
ensure_openrouter_sqlite_auth() {
  local id="$1" rc=0
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0

  podman exec "$container" node <<'NODE' 2>/dev/null || rc=$?
const { spawnSync } = require("child_process");
const fs = require("fs");

function authList() {
  return spawnSync("node", ["/app/openclaw.mjs", "models", "auth", "list", "--agent", "main"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

const listed = authList();
const out = listed.stdout || "";
if (/openrouter:default/.test(out) || /\[openrouter\/api_key\]/.test(out)) {
  process.exit(0);
}

const path = "/home/node/.openclaw/agents/main/agent/auth-profiles.json";
if (!fs.existsSync(path)) process.exit(0);
const key = JSON.parse(fs.readFileSync(path, "utf8"))?.profiles?.["openrouter:default"]?.key;
if (!key?.startsWith("sk-or-")) process.exit(0);

const r = spawnSync(
  "node",
  [
    "/app/openclaw.mjs",
    "models",
    "auth",
    "paste-api-key",
    "--provider",
    "openrouter",
    "--profile-id",
    "openrouter:default",
  ],
  { input: key, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] },
);
if (r.status !== 0) process.exit(r.status ?? 1);
NODE
  if [[ $rc -ne 0 ]]; then
    echo "    (${id}: OpenRouter sqlite auth sync failed — paste key: openclaw models auth paste-api-key --provider openrouter)" >&2
  fi
}


write_openrouter_api_key() {
  local id="$1"
  local key="$2"
  local config_dir agent_dir
  config_dir="$(agent_home "$id")"
  agent_dir="$config_dir/agents/main/agent"
  validate_openrouter_api_key "$key"
  if mkdir -p "$agent_dir" 2>/dev/null; then
    _write_openrouter_auth_profiles_host "$agent_dir" "$key"
  else
    _write_openrouter_auth_profiles_in_container "$id" "$key"
  fi
}


_write_openrouter_auth_profiles_host() {
  local agent_dir="$1"
  local key="$2"
  python3 - "$agent_dir/auth-profiles.json" "$key" <<'PY'
import json, sys, os
path, key = sys.argv[1], sys.argv[2]
data = {
    "version": 1,
    "profiles": {
        "openrouter:default": {
            "type": "api_key",
            "provider": "openrouter",
            "key": key,
        }
    },
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
  printf '{"version":1,"usageStats":{}}\n' >"$agent_dir/auth-state.json"
  chmod 600 "$agent_dir/auth-state.json"
}


_write_openrouter_auth_profiles_in_container() {
  local id="$1"
  local key="$2"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot store OpenRouter key: no access to agent dir and ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$key" <<'PY'
import json, os, sys
key = sys.argv[1]
root = "/home/node/.openclaw/agents/main/agent"
os.makedirs(root, mode=0o700, exist_ok=True)
path = os.path.join(root, "auth-profiles.json")
data = {
    "version": 1,
    "profiles": {
        "openrouter:default": {
            "type": "api_key",
            "provider": "openrouter",
            "key": key,
        }
    },
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
state = os.path.join(root, "auth-state.json")
with open(state, "w", encoding="utf-8") as f:
    f.write('{"version":1,"usageStats":{}}\n')
os.chmod(state, 0o600)
PY
  ensure_openrouter_sqlite_auth "$id"
}


validate_opencode_api_key() {
  local key="$1"
  if [[ "$key" != sk-* ]]; then
    echo "OpenCode API keys start with sk- (got something else — check you did not paste a shell command)." >&2
    return 1
  fi
  if [[ "$key" == sk-or-* ]]; then
    echo "That looks like an OpenRouter key (sk-or-...). Use set-api-key for OpenRouter." >&2
    return 1
  fi
}


ensure_opencode_sqlite_auth() {
  local id="$1" rc=0
  local container key listed
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0

  key="$(podman exec "$container" python3 -c "
import json
from pathlib import Path
p = Path('/home/node/.openclaw/agents/main/agent/auth-profiles.json')
if not p.is_file():
    raise SystemExit(0)
profiles = json.loads(p.read_text(encoding='utf-8')).get('profiles', {})
k = (profiles.get('opencode:default') or {}).get('key') or (profiles.get('opencode-go:default') or {}).get('key')
if k and k.startswith('sk-') and not k.startswith('sk-or-'):
    print(k, end='')
" 2>/dev/null)" || return 0
  [[ -n "$key" ]] || return 0

  listed="$(podman exec "$container" node /app/openclaw.mjs models auth list 2>/dev/null || true)"
  if ! grep -qE 'opencode:default|\[opencode/api_key\]' <<<"$listed"; then
    podman exec -i "$container" node /app/openclaw.mjs models auth paste-api-key \
      --provider opencode --profile-id opencode:default <<<"$key" >/dev/null 2>&1 || rc=1
  fi
  if ! grep -qE 'opencode-go:default|\[opencode-go/api_key\]' <<<"$listed"; then
    podman exec -i "$container" node /app/openclaw.mjs models auth paste-api-key \
      --provider opencode-go --profile-id opencode-go:default <<<"$key" >/dev/null 2>&1 || rc=1
  fi
  if [[ $rc -ne 0 ]]; then
    echo "    (${id}: OpenCode sqlite auth sync failed — openclaw models auth paste-api-key --provider opencode)" >&2
  fi
}


write_opencode_api_key() {
  local id="$1"
  local key="$2"
  local config_dir agent_dir
  config_dir="$(agent_home "$id")"
  agent_dir="$config_dir/agents/main/agent"
  validate_opencode_api_key "$key"
  if mkdir -p "$agent_dir" 2>/dev/null; then
    _write_opencode_auth_profiles_host "$agent_dir" "$key"
  else
    _write_opencode_auth_profiles_in_container "$id" "$key"
    return $?
  fi
  if agent_container_running "$id"; then
    ensure_opencode_sqlite_auth "$id"
  fi
}


_write_opencode_auth_profiles_host() {
  local agent_dir="$1"
  local key="$2"
  python3 - "$agent_dir/auth-profiles.json" "$key" <<'PY'
import json, sys, os
path, key = sys.argv[1], sys.argv[2]
profile = {"type": "api_key", "key": key}
data = {
    "version": 1,
    "profiles": {
        "opencode:default": {**profile, "provider": "opencode"},
        "opencode-go:default": {**profile, "provider": "opencode-go"},
    },
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
  printf '{"version":1,"usageStats":{}}\n' >"$agent_dir/auth-state.json"
  chmod 600 "$agent_dir/auth-state.json"
}


_write_opencode_auth_profiles_in_container() {
  local id="$1"
  local key="$2"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot store OpenCode key: no access to agent dir and ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$key" <<'PY'
import json, os, sys
key = sys.argv[1]
root = "/home/node/.openclaw/agents/main/agent"
os.makedirs(root, mode=0o700, exist_ok=True)
path = os.path.join(root, "auth-profiles.json")
profile = {"type": "api_key", "key": key}
data = {
    "version": 1,
    "profiles": {
        "opencode:default": {**profile, "provider": "opencode"},
        "opencode-go:default": {**profile, "provider": "opencode-go"},
    },
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
state = os.path.join(root, "auth-state.json")
with open(state, "w", encoding="utf-8") as f:
    f.write('{"version":1,"usageStats":{}}\n')
os.chmod(state, 0o600)
PY
  ensure_opencode_sqlite_auth "$id"
}


ensure_llm_sqlite_auth() {
  local id="$1"
  ensure_openrouter_sqlite_auth "$id"
  ensure_opencode_sqlite_auth "$id"
}


mirror_agent_config() {
  local from_id="$1"
  local to_id="$2"
  local from_dir to_dir gw token
  from_dir="$(agent_home "$from_id")"
  to_dir="$(agent_home "$to_id")"
  [[ -f "$from_dir/openclaw.json" ]] || { echo "Missing source config: $from_dir/openclaw.json" >&2; exit 1; }
  [[ -d "$to_dir" ]] || { echo "Missing target dir: $to_dir (run init)" >&2; exit 1; }
  read -r gw _ < <(agent_ports "$to_id")
  token="$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$to_dir/.env" | cut -d= -f2-)"
  [[ -n "$token" ]] || { echo "Missing OPENCLAW_GATEWAY_TOKEN in $to_dir/.env" >&2; exit 1; }

  if [[ -f "$from_dir/agents/main/agent/auth-profiles.json" ]]; then
    mkdir -p "$to_dir/agents/main/agent"
    cp "$from_dir/agents/main/agent/auth-profiles.json" "$to_dir/agents/main/agent/auth-profiles.json"
    chmod 600 "$to_dir/agents/main/agent/auth-profiles.json"
    printf '{"version":1,"usageStats":{}}\n' >"$to_dir/agents/main/agent/auth-state.json"
    chmod 600 "$to_dir/agents/main/agent/auth-state.json"
  fi

  python3 - "$from_dir/openclaw.json" "$to_dir/openclaw.json" "$gw" "$token" <<'PY'
import json, sys
from pathlib import Path

src_path, dst_path, host_gw_port, token = sys.argv[1:5]
host_gw_port = int(host_gw_port)
internal_gw_port = 18789
data = json.loads(Path(src_path).read_text(encoding="utf-8"))

gateway = data.setdefault("gateway", {})
gateway["port"] = internal_gw_port
gateway.setdefault("auth", {})["mode"] = gateway.get("auth", {}).get("mode", "token")
gateway["auth"]["token"] = token
gateway["bind"] = gateway.get("bind", "loopback")
gateway.setdefault("controlUi", {})["allowedOrigins"] = [
    f"http://127.0.0.1:{host_gw_port}",
    f"http://localhost:{host_gw_port}",
    f"http://127.0.0.1:{internal_gw_port}",
    f"http://localhost:{internal_gw_port}",
]

# Migrate auth profiles from anthropic to openrouter
auth = data.get("auth", {})
profiles = auth.get("profiles", {})
if "anthropic:default" in profiles:
    profiles["openrouter:default"] = {"provider": "openrouter", "mode": "api_key"}
    del profiles["anthropic:default"]
    auth["profiles"] = profiles
    data["auth"] = auth

# Migrate plugins
plugins = data.get("plugins", {}).get("entries", {})
if "anthropic" in plugins:
    plugins["openrouter"] = plugins.pop("anthropic")
    data["plugins"]["entries"] = plugins

# Update model to use openrouter prefix
agents = data.get("agents", {})
defaults = agents.get("defaults", {})
model = defaults.get("model", {})
primary = model.get("primary", "")
if primary.startswith("anthropic/"):
    model["primary"] = "openrouter/" + primary
    defaults["model"] = model
    agents["defaults"] = defaults
    data["agents"] = agents

discord = data.get("channels", {}).get("discord")
if isinstance(discord, dict) and discord.get("enabled"):
    discord["allowBots"] = "mentions"

Path(dst_path).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
Path(dst_path).chmod(0o600)
PY

  echo "Mirrored ${from_id} → ${to_id} (gateway port ${gw}, auth + openclaw.json)"
}

# Paths bundled for migration (secrets + durable config). Ephemeral/runtime dirs excluded.

# Paths bundled for migration (secrets + durable config). Ephemeral/runtime dirs excluded.
agent_export_paths() {
  cat <<'EOF'
openclaw.json
.env
.config
secrets
agents
workspace
identity
extensions
cron
canvas
devices
credentials
exec-approvals.json
plugin-skills
flows
memory
media
discord
telegram
EOF
}


agent_export_excludes() {
  cat <<'EOF'
openclaw.json.bak
openclaw.json.bak.*
openclaw.json.last-good
.reset-backup
.a2a-plugin-build
cache
logs
npm
delivery-queue
tasks
tui
plugins
update-check.json
workspace/node_modules
workspace/.git
EOF
}


sync_agent_secrets_for_export() {
  local id="$1"
  local config_dir="$2"
  sync_discord_env "$config_dir"
  sync_telegram_env "$config_dir"
  sync_identyclaw_env "$config_dir"
  sync_instagram_env "$config_dir"
  sync_twitter_env "$config_dir"
  sync_twitter_bird_env "$id" "$config_dir"
  sync_quiet_plugin_env "$config_dir"
}


write_agent_export_manifest() {
  local id="$1"
  local config_dir="$2"
  local manifest_path="$3"
  local with_browser="$4"
  load_env
  local gw br email display_name repo_rev=""
  read -r gw br < <(agent_ports "$id")
  local mailbox
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  if command -v git >/dev/null 2>&1 && [[ -d "$IDENTYCLAW_ROOT/.git" ]]; then
    repo_rev="$(git -C "$IDENTYCLAW_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  fi
  python3 - "$manifest_path" "$id" "$config_dir" "$gw" "$br" "$email" "$display_name" \
    "$with_browser" "$(hostname -f 2>/dev/null || hostname)" "$repo_rev" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

path, agent_id, config_dir, gw, br, email, display_name, with_browser, source_host, repo_rev = sys.argv[1:11]
manifest = {
    "format": "identyclaw-agent-export",
    "version": 1,
    "agentId": agent_id,
    "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sourceHost": source_host,
    "identyclawRepoRev": repo_rev or None,
    "gatewayPort": int(gw),
    "bridgePort": int(br),
    "email": email,
    "displayName": display_name,
    "includesBrowser": with_browser == "1",
    "stateDirBasename": Path(config_dir).name,
    "importSteps": [
        "Copy identyclaw-agents repo to target host",
        "ensure_app_layout && merge env.local.fragment into openclaw-agents-app/env.local",
        "./identyclaw.sh build-image",
        f"./identyclaw.sh import-agent {agent_id} <this-archive>",
        f"./identyclaw.sh start {agent_id}",
        f"./identyclaw.sh test-mail {agent_id}",
    ],
}
Path(path).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
Path(path).chmod(0o600)
PY
}


write_agent_export_env_fragment() {
  local id="$1"
  local fragment_path="$2"
  load_env
  local gw br email display_name password="" prefix a2a_url="" public_host="" ingress_port=""
  read -r gw br < <(agent_ports "$id")
  local mailbox
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  local prefix
  prefix="$(agent_env_prefix "$id")" || { echo "unknown agent: $id" >&2; return 1; }
  password="$(agent_env_value "$id" PASSWORD "")"
  a2a_url="$(agent_env_value "$id" A2A_PUBLIC_BASE_URL "")"
  [[ -z "$a2a_url" ]] && a2a_url="$(agent_ingress_base_url "$id")"
  public_host="$(agent_env_value "$id" PUBLIC_HOST "")"
  ingress_port="$(agent_env_value "$id" INGRESS_PORT "")"
  [[ -z "$ingress_port" ]] && ingress_port="${IDENTYCLAW_INGRESS_PORT:-8443}"
  cat >"$fragment_path" <<EOF
# Merge into $(identyclaw_app_dir)/env.local on the target host (chmod 600).
# Secrets are inside the archive under secrets/ — passwords here are optional duplicates.
# Public webhook / A2A base must use Telegram-compatible ingress (8443 on this fleet).

${prefix}_EMAIL=${email}
${prefix}_DISPLAY_NAME="${display_name}"
${prefix}_GATEWAY_PORT=${gw}
${prefix}_BRIDGE_PORT=${br}
EOF
  if [[ -n "$password" ]]; then
    printf '%s_PASSWORD=%s\n' "$prefix" "$password" >>"$fragment_path"
  fi
  if [[ -n "$public_host" ]]; then
    printf '%s_PUBLIC_HOST=%s\n' "$prefix" "$public_host" >>"$fragment_path"
  fi
  printf '%s_INGRESS_PORT=%s\n' "$prefix" "$ingress_port" >>"$fragment_path"
  if [[ -n "$a2a_url" ]]; then
    printf '%s_A2A_PUBLIC_BASE_URL=%s\n' "$prefix" "$a2a_url" >>"$fragment_path"
  fi
  chmod 600 "$fragment_path"
}


fix_agent_export_permissions() {
  local config_dir="$1"
  chmod 700 "$config_dir" "$config_dir/secrets" 2>/dev/null || true
  find "$config_dir/secrets" -type f -exec chmod 600 {} + 2>/dev/null || true
  find "$config_dir/secrets" -type f -name '*.sh' -exec chmod 700 {} + 2>/dev/null || true
  chmod 600 "$config_dir/.env" "$config_dir/openclaw.json" 2>/dev/null || true
  find "$config_dir/agents" -type f -exec chmod 600 {} + 2>/dev/null || true
  find "$config_dir/identity" -type f -exec chmod 600 {} + 2>/dev/null || true
}


export_agent_bundle() {
  local id="$1"
  local output="${2:-}"
  local with_browser="${3:-0}"
  local stop_first="${4:-1}"
  local config_dir staging manifest fragment
  config_dir="$(agent_home "$id")"
  [[ -d "$config_dir" ]] || { echo "Missing agent dir: $config_dir (run init first)" >&2; exit 1; }
  [[ -f "$config_dir/openclaw.json" ]] || { echo "Missing openclaw.json in $config_dir" >&2; exit 1; }

  if [[ "$stop_first" == "1" ]] && command -v podman >/dev/null 2>&1; then
    local container
    container="$(agent_container "$id")"
    if podman ps --format '{{.Names}}' | grep -qx "$container"; then
      echo "==> Stopping ${container} for consistent export"
      podman stop "$container" >/dev/null
    fi
  fi

  echo "==> Syncing secrets into .env before export"
  sync_agent_secrets_for_export "$id" "$config_dir"

  if [[ -z "$output" ]]; then
    load_env
    mkdir -p "${IDENTYCLAW_APP_DIR}/exports"
    output="${IDENTYCLAW_APP_DIR}/exports/identyclaw-migrate-${id}-$(date +%Y%m%d-%H%M%S).tar.gz"
  fi
  output="$(readlink -f "$output")"

  staging="$(mktemp -d)"
  local _export_staging="$staging"
  trap 'rm -rf "${_export_staging:-}"' RETURN

  write_agent_export_manifest "$id" "$config_dir" "$staging/MANIFEST.json" "$with_browser"
  write_agent_export_env_fragment "$id" "$staging/env.local.fragment"

  local path
  while IFS= read -r path; do
    [[ -n "$path" && -e "$config_dir/$path" ]] || continue
    mkdir -p "$staging/$(dirname "$path")"
    cp -a "$config_dir/$path" "$staging/$path"
  done < <(agent_export_paths)
  if [[ "$with_browser" == "1" && -d "$config_dir/browser" ]]; then
    cp -a "$config_dir/browser" "$staging/browser"
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rm -rf "$staging/$path" 2>/dev/null || true
  done < <(agent_export_excludes)

  echo "==> Packing ${id} → ${output}"
  tar --create --gzip --file "$output" -C "$staging" .

  chmod 600 "$output"
  local size
  size="$(du -h "$output" | awk '{print $1}')"
  echo ""
  echo "Export ready: ${output} (${size})"
  echo "Contains secrets — store encrypted, transfer over a trusted channel, delete when imported."
  echo "On target: ./identyclaw.sh import-agent ${id} ${output}"
}


import_agent_bundle() {
  local id="$1"
  local archive="${2:?archive required}"
  [[ -f "$archive" ]] || { echo "Archive not found: $archive" >&2; exit 1; }

  local extract staging manifest_id
  staging="$(mktemp -d)"
  local _import_staging="$staging"
  trap 'rm -rf "${_import_staging:-}"' RETURN
  tar -xzf "$archive" -C "$staging"

  [[ -f "$staging/MANIFEST.json" ]] || { echo "Invalid archive: missing MANIFEST.json" >&2; exit 1; }
  manifest_id="$(python3 - "$staging/MANIFEST.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("agentId", ""))
PY
)"
  [[ "$manifest_id" == "$id" ]] || {
    echo "Archive is for ${manifest_id:-unknown}, not ${id}" >&2
    exit 1
  }

  if command -v podman >/dev/null 2>&1; then
    local container
    container="$(agent_container "$id")"
    podman stop "$container" 2>/dev/null || true
    podman rm -f "$container" 2>/dev/null || true
  fi

  local config_dir backup
  config_dir="$(agent_home "$id")"
  if [[ -d "$config_dir" ]]; then
    backup="${config_dir}.pre-import-$(date +%Y%m%d-%H%M%S)"
    echo "==> Backing up existing ${config_dir} → ${backup}"
    mv "$config_dir" "$backup"
  fi
  mkdir -p "$config_dir"

  echo "==> Restoring agent state into ${config_dir}"
  shopt -s dotglob
  for item in "$staging"/*; do
    base="$(basename "$item")"
    [[ "$base" == "MANIFEST.json" || "$base" == "env.local.fragment" ]] && continue
    cp -a "$item" "$config_dir/"
  done
  shopt -u dotglob

  fix_agent_export_permissions "$config_dir"
  load_env
  read -r gw _ < <(agent_ports "$id")
  ensure_internal_gateway_port "$config_dir" "$gw"
  ensure_agent_bootstrap "$id" "$config_dir"

  echo ""
  echo "Imported ${id} into ${config_dir}"
  if [[ -f "$staging/env.local.fragment" ]]; then
    local fragment_dest
    fragment_dest="$(identyclaw_app_dir)/env.local.fragment.${id}"
    cp "$staging/env.local.fragment" "$fragment_dest"
    echo "Merge ${fragment_dest} into $(identyclaw_env_file) on this host."
  fi
  echo "Next: ./identyclaw.sh build-image && ./identyclaw.sh start ${id}"
}
