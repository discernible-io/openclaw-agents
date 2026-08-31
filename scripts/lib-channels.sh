#!/usr/bin/env bash
# Telegram, Discord, X/Twitter, and Instagram.
# Sourced from scripts/lib.sh — do not execute directly.

# Discord channel plugin must match gateway core (e.g. parseStrictPositiveInteger export drift).
# Correction gateways (2026.7.1-2) are compatible with Discord 2026.7.1 when no matching npm tag exists.
ensure_discord_plugin_compat() {
  local id="$1"
  local container
  load_env
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0

  if podman exec "$container" node -e "
const fs = require('fs');
const path = require('path');
const gw = require('/app/package.json').version;
function discordPluginVersion(gw) {
  const m = String(gw).match(/^(\\d+\\.\\d+\\.\\d+)-\\d+$/);
  return m ? m[1] : gw;
}
function discordCompatible(discord, gw) {
  return Boolean(discord) && (discord === gw || discord === discordPluginVersion(gw));
}
function discordVersion() {
  const legacy = '/home/node/.openclaw/npm/node_modules/@openclaw/discord/package.json';
  if (fs.existsSync(legacy)) return require(legacy).version;
  const projects = '/home/node/.openclaw/npm/projects';
  if (!fs.existsSync(projects)) return null;
  for (const d of fs.readdirSync(projects)) {
    const pkg = path.join(projects, d, 'node_modules/@openclaw/discord/package.json');
    if (fs.existsSync(pkg)) return require(pkg).version;
  }
  return null;
}
process.exit(discordCompatible(discordVersion(), gw) ? 0 : 1);
" 2>/dev/null; then
    return 0
  fi

  echo "    (${id}: syncing @openclaw/discord to published plugin for this gateway…)" >&2
  podman exec "$container" bash -ce '
    set -euo pipefail
    gw=$(node -e "process.stdout.write(require(\"/app/package.json\").version)")
    discord=$(node -e "const g=process.argv[1]; const m=String(g).match(/^(\\d+\\.\\d+\\.\\d+)-\\d+$/); process.stdout.write(m?m[1]:g)" -- "$gw")
    rm -rf /home/node/.openclaw/npm/node_modules/@openclaw/discord
    rm -rf /home/node/.openclaw/npm/projects/openclaw-discord-*
    OPENCLAW_STATE_DIR=/home/node/.openclaw node /app/openclaw.mjs plugins install "@openclaw/discord@${discord}" --pin --accept-capabilities
  ' >&2
  return 1
}


restart_agent_gateway_if_running() {
  local id="$1"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  echo "    (${id}: restarting gateway to load Discord plugin…)" >&2
  podman restart "$container" >/dev/null
}


ensure_discord_plugin_compat_and_restart() {
  local id="$1"
  ensure_discord_plugin_compat "$id" || restart_agent_gateway_if_running "$id"
}

# Telegram webhook listener is a separate OpenClaw bind (default 8787). In a pod all
# agents share the network namespace, so each agent uses gateway-port + 2.
agent_telegram_webhook_port() {
  local id="$1"
  echo $(( $(agent_internal_gateway_port "$id") + 2 ))
}

# Pod agents chown state to the container uid; token may live in openclaw.json or .env.


ensure_discord_guild_channels() {
  local config_dir="$1"
  local container="${2:-}"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict):
    raise SystemExit(0)

guild_id = "1509561171961708554"
channel_id = "1509561172725334058"
owner_id = "1438122032968634408"
changed = False

guilds = discord.setdefault("guilds", {})
guild = guilds.setdefault(guild_id, {})
if guild.get("requireMention") is not True:
    guild["requireMention"] = True
    changed = True
if guild.get("ignoreOtherMentions") is not True:
    guild["ignoreOtherMentions"] = True
    changed = True
users = guild.setdefault("users", [])
if owner_id not in users:
    users.append(owner_id)
    changed = True
channels = guild.setdefault("channels", {})
ch = channels.setdefault(channel_id, {})
if ch.get("enabled") is not True:
    ch["enabled"] = True
    changed = True
if ch.get("requireMention") is not True:
    ch["requireMention"] = True
    changed = True
if ch.get("ignoreOtherMentions") is not True:
    ch["ignoreOtherMentions"] = True
    changed = True

allow_from = discord.setdefault("allowFrom", [])
if owner_id not in allow_from:
    allow_from.append(owner_id)
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


ensure_discord_ready() {
  local id="$1"
  local config_dir="$2"
  local config="$config_dir/openclaw.json"
  local token_file="$config_dir/secrets/DISCORD_BOT_TOKEN"
  [[ -f "$config" ]] || return 0
  python3 - "$config" "$token_file" <<'PY'
import json, sys
from pathlib import Path

path, token_file = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict):
    raise SystemExit(0)

has_token = token_file.is_file() and token_file.read_text(encoding="utf-8").strip()
enabled = discord.get("enabled", False)
changed = False

if enabled and not has_token:
    discord["enabled"] = False
    changed = True
    print(f"WARNING: {path.parent.name}: Discord enabled but no token — disabled until ./identyclaw.sh set-discord-token {path.parent.name.replace('.openclaw-', '')}", file=sys.stderr)
elif not enabled and has_token:
    discord["enabled"] = True
    changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


write_instagram_secrets() {
  local config_dir="$1"
  local username="$2"
  local password="$3"
  [[ -n "$username" && -n "$password" ]] || { echo "empty Instagram credentials" >&2; return 1; }
  mkdir -p "$config_dir/secrets"
  printf '%s' "$username" >"$config_dir/secrets/instagram.username"
  printf '%s' "$password" >"$config_dir/secrets/instagram.password"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/instagram.username" "$config_dir/secrets/instagram.password"
  sync_instagram_env "$config_dir"
  write_agent_instagram_doc "$config_dir" "$username"
}


sync_instagram_env() {
  local config_dir="$1"
  local user_file="$config_dir/secrets/instagram.username"
  local pass_file="$config_dir/secrets/instagram.password"
  local env_file="$config_dir/.env"
  [[ -f "$user_file" && -f "$pass_file" ]] || return 0
  local username password
  username="$(<"$user_file")"
  password="$(<"$pass_file")"
  [[ -n "$username" && -n "$password" ]] || return 0
  python3 - "$env_file" "$username" "$password" <<'PY'
import os, sys
path, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("INSTAGRAM_USERNAME=", "INSTAGRAM_PASSWORD="))
        ]
lines.append(f"INSTAGRAM_USERNAME={username}\n")
lines.append(f"INSTAGRAM_PASSWORD={password}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}


write_agent_instagram_doc() {
  local config_dir="$1"
  local username="$2"
  mkdir -p "$config_dir/workspace"
  cat >"$config_dir/workspace/INSTAGRAM.md" <<EOF
# Instagram (Mundo En Blanco)

**Credentials are configured.** Do not ask for manual login handoff or user-browser attach until you have tried browser login below and hit captcha / 2FA / suspicious-login.

- **Profile:** https://www.instagram.com/${username}/
- **Username:** \`${username}\` (\`INSTAGRAM_USERNAME\` in env)
- **Password:** \`INSTAGRAM_PASSWORD\` in env (also \`secrets/instagram.*\`)

## First step on any Instagram task

1. Read this file.
2. Log in via the managed \`browser\` tool (browser-automation skill) using env credentials.
3. Open the profile and snapshot posts before suggesting alternatives.

Save learned caption/reel style to \`workspace/instagram/STYLE.md\`.

## Browser login

1. \`action="open"\` → \`https://www.instagram.com/accounts/login/\` with \`label="instagram"\`
2. \`action="snapshot"\` on \`targetId="instagram"\`
3. Fill username/password from env, submit, snapshot again
4. Reuse the \`instagram\` tab for posting, drafts, and reels

Automated container login often hits reCAPTCHA — stop and point Mariia to \`workspace/instagram/Mariia-SETUP.md\` (user Chrome \`profile="user"\` or cookie import).

## Session persistence

Cookies live under \`browser/openclaw/user-data/\`. After a successful login, keep using the same browser profile; do not clear user data unless asked.
EOF
  chmod 644 "$config_dir/workspace/INSTAGRAM.md"
}


agent_twitter_username() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_USERNAME ""
}


agent_twitter_bird_auth_token() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_AUTH_TOKEN ""
}


agent_twitter_bird_ct0() {
  local id="$1"
  load_env
  is_valid_agent_id "$id" || { echo ""; return 0; }
  agent_env_value "$id" TWITTER_CT0 ""
}


twitter_clawhub_skill_slug() {
  load_env
  local spec="${IDENTYCLAW_CLAWHUB_TWITTER_SKILL:-bird-twitter}"
  spec="${spec#clawhub:}"
  spec="${spec##*/}"
  spec="${spec%%@*}"
  echo "$spec"
}


twitter_bird_bin() {
  echo "/home/node/.openclaw/workspace/node_modules/.bin/bird"
}


twitter_clawhub_skill_installed_in_container() {
  local container="$1"
  local slug
  slug="$(twitter_clawhub_skill_slug)"
  podman exec "$container" sh -c "test -f /home/node/.openclaw/workspace/skills/${slug}/SKILL.md" 2>/dev/null
}


sync_twitter_bird_env() {
  local id="$1"
  local config_dir="$2"
  local env_file="$config_dir/.env"
  local auth_token ct0
  auth_token="$(agent_twitter_bird_auth_token "$id")"
  ct0="$(agent_twitter_bird_ct0 "$id")"
  [[ -f "$config_dir/secrets/twitter.auth_token" ]] && [[ -z "$auth_token" ]] && auth_token="$(<"$config_dir/secrets/twitter.auth_token")"
  [[ -f "$config_dir/secrets/twitter.ct0" ]] && [[ -z "$ct0" ]] && ct0="$(<"$config_dir/secrets/twitter.ct0")"
  [[ -n "$auth_token" && -n "$ct0" ]] || return 0
  python3 - "$env_file" "$auth_token" "$ct0" <<'PY'
import os, sys
path, auth_token, ct0 = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("AUTH_TOKEN=", "CT0=", "AISA_API_KEY="))
        ]
lines.append(f"AUTH_TOKEN={auth_token}\n")
lines.append(f"CT0={ct0}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}


write_twitter_bird_cookies() {
  local id="$1"
  local config_dir="$2"
  local auth_token="$3"
  local ct0="$4"
  [[ -n "$auth_token" && -n "$ct0" ]] || { echo "empty Twitter session cookies" >&2; return 1; }
  if ! mkdir -p "$config_dir/secrets" 2>/dev/null; then
    _write_twitter_bird_cookies_in_container "$id" "$auth_token" "$ct0"
    return $?
  fi
  printf '%s' "$auth_token" >"$config_dir/secrets/twitter.auth_token"
  printf '%s' "$ct0" >"$config_dir/secrets/twitter.ct0"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/twitter.auth_token" "$config_dir/secrets/twitter.ct0"
  sync_twitter_bird_env "$id" "$config_dir"
}


_write_twitter_bird_cookies_in_container() {
  local id="$1"
  local auth_token="$2"
  local ct0="$3"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot write Twitter cookies: ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$auth_token" "$ct0" <<'PY'
import os, sys
auth_token, ct0 = sys.argv[1], sys.argv[2]
root = "/home/node/.openclaw"
secrets = os.path.join(root, "secrets")
os.makedirs(secrets, mode=0o700, exist_ok=True)
for name, value in (("twitter.auth_token", auth_token), ("twitter.ct0", ct0)):
    path = os.path.join(secrets, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)
    os.chmod(path, 0o600)
env_file = os.path.join(root, ".env")
lines = []
if os.path.isfile(env_file):
    with open(env_file, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("AUTH_TOKEN=", "CT0=", "AISA_API_KEY="))
        ]
lines.append(f"AUTH_TOKEN={auth_token}\n")
lines.append(f"CT0={ct0}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}


_ensure_twitter_clawhub_skill_openclaw_json() {
  local config_dir="$1"
  local slug old_slug
  slug="$(twitter_clawhub_skill_slug)"
  old_slug="openclaw-aisa-twitter-search"
  python3 - "$config_dir/openclaw.json" "$slug" "$old_slug" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, old_slug = sys.argv[2], sys.argv[3]
if not path.is_file():
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
changed = False
skills = data.setdefault("skills", {}).setdefault("entries", {})
if old_slug in skills:
    del skills[old_slug]
    changed = True
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True
if changed:
    data["skills"]["entries"] = skills
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


_ensure_twitter_clawhub_skill_openclaw_json_in_container() {
  local container="$1"
  local slug old_slug
  slug="$(twitter_clawhub_skill_slug)"
  old_slug="openclaw-aisa-twitter-search"
  podman exec -i "$container" python3 - "$slug" "$old_slug" <<'PY'
import json, sys
from pathlib import Path

slug, old_slug = sys.argv[1], sys.argv[2]
path = Path("/home/node/.openclaw/openclaw.json")
data = json.loads(path.read_text(encoding="utf-8"))
changed = False
skills = data.setdefault("skills", {}).setdefault("entries", {})
if old_slug in skills:
    del skills[old_slug]
    changed = True
if skills.get(slug, {}).get("enabled") is not True:
    skills[slug] = {"enabled": True}
    changed = True
if changed:
    data["skills"]["entries"] = skills
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


ensure_bird_cli_in_container() {
  local container="$1"
  podman exec "$container" sh -c 'test -x /home/node/.openclaw/workspace/node_modules/.bin/bird' 2>/dev/null && return 0
  echo "    (installing bird CLI in workspace…)" >&2
  podman exec "$container" sh -c 'cd /home/node/.openclaw/workspace && npm install --no-save @steipete/bird@0.8.0' >&2 || true
}


ensure_twitter_bird_cookies_from_env() {
  local id="$1"
  local config_dir="$2"
  local auth_token ct0
  auth_token="$(agent_twitter_bird_auth_token "$id")"
  ct0="$(agent_twitter_bird_ct0 "$id")"
  if [[ -n "$auth_token" && -n "$ct0" ]] && [[ ! -f "$config_dir/secrets/twitter.auth_token" ]]; then
    write_twitter_bird_cookies "$id" "$config_dir" "$auth_token" "$ct0"
    echo "    (${id}: Twitter session cookies loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/twitter.auth_token" ]]; then
    sync_twitter_bird_env "$id" "$config_dir"
  fi
}


ensure_twitter_clawhub_skill() {
  local id="$1"
  local config_dir="$2"
  local container skill_spec slug
  load_env
  skill_spec="${IDENTYCLAW_CLAWHUB_TWITTER_SKILL:-bird-twitter}"
  slug="$(twitter_clawhub_skill_slug)"
  container="$(agent_container "$id")"
  ensure_twitter_bird_cookies_from_env "$id" "$config_dir"
  if [[ -f "$config_dir/openclaw.json" ]]; then
    _ensure_twitter_clawhub_skill_openclaw_json "$config_dir"
  fi
  podman ps --format '{{.Names}}' | grep -qx "$container" || return 0
  ensure_openclaw_cli_link "$container"
  podman exec "$container" rm -rf \
    "/home/node/.openclaw/workspace/skills/openclaw-aisa-twitter-search" \
    "/home/node/.openclaw/workspace/skills/twitter-post" 2>/dev/null || true
  if ! twitter_clawhub_skill_installed_in_container "$container"; then
    echo "    (${id}: installing ClawHub Twitter skill ${skill_spec}…)" >&2
    podman exec "$container" node /app/openclaw.mjs skills install "$skill_spec" >&2 \
      || podman exec "$container" node /app/openclaw.mjs skills install "$slug" >&2 || true
  fi
  ensure_bird_cli_in_container "$container"
  _ensure_twitter_clawhub_skill_openclaw_json_in_container "$container"
  sync_twitter_bird_env "$id" "$config_dir"
  if [[ -f "$config_dir/secrets/twitter.auth_token" && -f "$config_dir/secrets/twitter.ct0" ]]; then
    _write_twitter_bird_cookies_in_container "$id" \
      "$(<"$config_dir/secrets/twitter.auth_token")" \
      "$(<"$config_dir/secrets/twitter.ct0")" 2>/dev/null || true
  fi
  local username
  username="$(agent_twitter_username "$id")"
  if [[ -z "$username" ]]; then
    username="$(podman exec "$container" sh -c 'cat /home/node/.openclaw/secrets/twitter.username 2>/dev/null' || true)"
  fi
  if [[ -n "$username" ]]; then
    _write_agent_twitter_doc_in_container "$container" "$username"
    _write_twitter_workspace_guidance_in_container "$container"
    _write_twitter_heartbeat_doc_in_container "$container"
    _ensure_twitter_heartbeat_config_in_container "$container"
  fi
}


write_twitter_secrets() {
  local id="$1"
  local config_dir="$2"
  local username="$3"
  local password="$4"
  [[ -n "$username" && -n "$password" ]] || { echo "empty Twitter credentials" >&2; return 1; }
  if ! mkdir -p "$config_dir/secrets" 2>/dev/null; then
    _write_twitter_secrets_in_container "$id" "$username" "$password"
    return $?
  fi
  printf '%s' "$username" >"$config_dir/secrets/twitter.username"
  printf '%s' "$password" >"$config_dir/secrets/twitter.password"
  chmod 700 "$config_dir/secrets"
  chmod 600 "$config_dir/secrets/twitter.username" "$config_dir/secrets/twitter.password"
  sync_twitter_env "$config_dir"
  write_agent_twitter_doc "$config_dir" "$username"
  write_twitter_heartbeat_doc "$config_dir"
  ensure_twitter_heartbeat_config "$config_dir"
  ensure_twitter_clawhub_skill "$id" "$config_dir"
}


_write_twitter_secrets_in_container() {
  local id="$1"
  local username="$2"
  local password="$3"
  local container
  container="$(agent_container "$id")"
  podman ps --format '{{.Names}}' | grep -qx "$container" || {
    echo "Cannot write Twitter secrets: no access to agent dir and ${container} is not running" >&2
    return 1
  }
  podman exec -i "$container" python3 - "$username" "$password" <<'PY'
import os, sys
username, password = sys.argv[1], sys.argv[2]
root = "/home/node/.openclaw"
secrets = os.path.join(root, "secrets")
os.makedirs(secrets, mode=0o700, exist_ok=True)
for name, value in (("twitter.username", username), ("twitter.password", password)):
    path = os.path.join(secrets, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(value)
    os.chmod(path, 0o600)
PY
  _sync_twitter_env_in_container "$container"
  _write_agent_twitter_doc_in_container "$container" "$username"
  _write_twitter_heartbeat_doc_in_container "$container"
  _ensure_twitter_heartbeat_config_in_container "$container"
  ensure_twitter_clawhub_skill "$id" "$(agent_home "$id")"
}


sync_twitter_env() {
  local config_dir="$1"
  local user_file="$config_dir/secrets/twitter.username"
  local pass_file="$config_dir/secrets/twitter.password"
  local env_file="$config_dir/.env"
  [[ -f "$user_file" && -f "$pass_file" ]] || return 0
  local username password
  username="$(<"$user_file")"
  password="$(<"$pass_file")"
  [[ -n "$username" && -n "$password" ]] || return 0
  python3 - "$env_file" "$username" "$password" <<'PY'
import os, sys
path, username, password = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [
            ln for ln in f
            if not ln.startswith(("TWITTER_USERNAME=", "TWITTER_PASSWORD="))
        ]
lines.append(f"TWITTER_USERNAME={username}\n")
lines.append(f"TWITTER_PASSWORD={password}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}


_sync_twitter_env_in_container() {
  local container="$1"
  podman exec -i "$container" python3 <<'PY'
import os
root = "/home/node/.openclaw"
user_file = os.path.join(root, "secrets", "twitter.username")
pass_file = os.path.join(root, "secrets", "twitter.password")
env_file = os.path.join(root, ".env")
if not (os.path.isfile(user_file) and os.path.isfile(pass_file)):
    raise SystemExit(0)
with open(user_file, encoding="utf-8") as f:
    username = f.read()
with open(pass_file, encoding="utf-8") as f:
    password = f.read()
lines = []
if os.path.isfile(env_file):
    with open(env_file, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith(("TWITTER_USERNAME=", "TWITTER_PASSWORD="))]
lines.append(f"TWITTER_USERNAME={username}\n")
lines.append(f"TWITTER_PASSWORD={password}\n")
with open(env_file, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(env_file, 0o600)
PY
}


write_agent_twitter_doc() {
  local config_dir="$1"
  local username="$2"
  local slug bird_bin agent_id
  slug="$(twitter_clawhub_skill_slug)"
  bird_bin="workspace/node_modules/.bin/bird"
  agent_id="$(basename "$config_dir")"
  mkdir -p "$config_dir/workspace/twitter"/{threads,drafts,posts}
  cat >"$config_dir/workspace/TWITTER.md" <<EOF
# X / Twitter (Discernible)

Account: \`${username}\` — post via **bird** CLI + ClawHub skill \`${slug}\` (free — no paid API).

- **Skill:** [bird-twitter](https://clawhub.ai/cyzi/bird-twitter) (\`workspace/skills/${slug}/SKILL.md\`)
- **Session:** \`AUTH_TOKEN\` + \`CT0\` in env (\`secrets/twitter.auth_token\`, \`secrets/twitter.ct0\`)
- **CLI:** \`${bird_bin}\` (installed in workspace via npm)

## Skills and tools (read this first)

- **You CAN post on X** using **\`${slug}\`** + \`exec\` + \`bird\` (not \`message\`).
- \`message\` is Discord/Slack only — never use it for X.
- **Do not** use browser password login to post (breaks in container). Use session cookies instead.
- If cookies missing, ask operator to run \`./identyclaw.sh set-twitter-cookies ${agent_id}\`.

## Get session cookies (one-time, Firefox)

1. Log in to [x.com](https://x.com) as \`${username}\` in **Firefox**
2. Open Developer Tools: **F12** (or **Menu → More tools → Web Developer Tools**)
3. Open the **Storage** tab
4. Left sidebar: **Cookies** → **https://x.com**
5. In the table, copy the **Value** for \`auth_token\` (paste as \`AUTH_TOKEN\`)
6. Copy the **Value** for \`ct0\` (paste as \`CT0\`)
7. Run \`./identyclaw.sh set-twitter-cookies ${agent_id}\` and paste each value when prompted

**Chrome:** DevTools → **Application** → **Cookies** → **https://x.com** — same cookie names.

## Post a tweet

\`\`\`bash
${bird_bin} check
${bird_bin} whoami
${bird_bin} tweet "HOLA MUNDO"
\`\`\`

1. \`${bird_bin} check\` — verify \`AUTH_TOKEN\` and \`CT0\`
2. \`${bird_bin} tweet "…"\` with the user's exact text
3. Do not claim success until \`bird tweet\` exits 0

## Read / mentions / search

\`\`\`bash
${bird_bin} mentions
${bird_bin} home
${bird_bin} search "query"
\`\`\`

Track posts in \`workspace/twitter/posts/\`.
EOF
  chmod 644 "$config_dir/workspace/TWITTER.md"
  write_twitter_workspace_guidance "$config_dir"
}


write_twitter_workspace_guidance() {
  local config_dir="$1"
  local tools="$config_dir/workspace/TOOLS.md"
  local agents="$config_dir/workspace/AGENTS.md"
  local slug bird_bin agent_id
  slug="$(twitter_clawhub_skill_slug)"
  bird_bin="workspace/node_modules/.bin/bird"
  agent_id="$(basename "$config_dir")"
  [[ -f "$tools" ]] || return 0
  python3 - "$tools" "$slug" "$bird_bin" "$agent_id" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, bird_bin, agent_id = sys.argv[2], sys.argv[3], sys.argv[4]
block = f"""
## X / Twitter ({agent_id})

- **Post on x.com:** `{slug}` + `bird` CLI — read **`TWITTER.md`**
- **Command:** `{bird_bin} tweet "…"`
- **Session:** `AUTH_TOKEN` + `CT0` — `./identyclaw.sh set-twitter-cookies {agent_id}`
- **Not for X:** `message` tool (Discord only). No paid AIsa API.
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
  [[ -f "$agents" ]] || return 0
  python3 - "$agents" "$slug" "$bird_bin" "$agent_id" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
slug, bird_bin, agent_id = sys.argv[2], sys.argv[3], sys.argv[4]
block = f"""
## X / Twitter

- You **can** post on x.com via **`{slug}`** + `{bird_bin} tweet "…"` — read **`TWITTER.md`** first.
- Requires `AUTH_TOKEN` and `CT0` session cookies (not password login in browser).
- If cookies missing, tell operator to run `./identyclaw.sh set-twitter-cookies {agent_id}`.
- **Do not** use `message` for X. Never paste cookies in chat.
"""
text = path.read_text(encoding="utf-8") if path.is_file() else ""
text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
path.write_text(text.rstrip() + block + "\n", encoding="utf-8")
PY
}


_write_agent_twitter_doc_in_container() {
  local container="$1"
  local username="$2"
  local slug agent_id
  slug="$(twitter_clawhub_skill_slug)"
  agent_id="${container#openclaw-}"
  podman exec -i "$container" python3 - "$username" "$slug" "$agent_id" <<'PY'
import os, sys
username, slug, agent_id = sys.argv[1], sys.argv[2], sys.argv[3]
workspace = "/home/node/.openclaw/workspace"
bird_bin = "workspace/node_modules/.bin/bird"
for sub in ("twitter/threads", "twitter/drafts", "twitter/posts"):
    os.makedirs(os.path.join(workspace, sub), exist_ok=True)
content = f"""# X / Twitter (Discernible)

Account: `{username}` — post via **bird** CLI + ClawHub skill `{slug}` (free — no paid API).

- **Skill:** [bird-twitter](https://clawhub.ai/cyzi/bird-twitter) (`workspace/skills/{slug}/SKILL.md`)
- **Session:** `AUTH_TOKEN` + `CT0` in env (`secrets/twitter.auth_token`, `secrets/twitter.ct0`)
- **CLI:** `{bird_bin}` (installed in workspace via npm)

## Skills and tools (read this first)

- **You CAN post on X** using **`{slug}`** + `exec` + `bird` (not `message`).
- `message` is Discord/Slack only — never use it for X.
- **Do not** use browser password login to post (breaks in container). Use session cookies instead.
- If cookies missing, ask operator to run `./identyclaw.sh set-twitter-cookies {agent_id}`.

## Get session cookies (one-time, Firefox)

1. Log in to [x.com](https://x.com) as `{username}` in **Firefox**
2. Open Developer Tools: **F12** (or **Menu → More tools → Web Developer Tools**)
3. Open the **Storage** tab
4. Left sidebar: **Cookies** → **https://x.com**
5. In the table, copy the **Value** for `auth_token` (paste as `AUTH_TOKEN`)
6. Copy the **Value** for `ct0` (paste as `CT0`)
7. Run `./identyclaw.sh set-twitter-cookies {agent_id}` and paste each value when prompted

**Chrome:** DevTools → **Application** → **Cookies** → **https://x.com** — same cookie names.

## Post a tweet

```bash
{bird_bin} check
{bird_bin} whoami
{bird_bin} tweet "HOLA MUNDO"
```

1. `{bird_bin} check` — verify `AUTH_TOKEN` and `CT0`
2. `{bird_bin} tweet "…"` with the user's exact text
3. Do not claim success until `bird tweet` exits 0

## Read / mentions / search

```bash
{bird_bin} mentions
{bird_bin} home
{bird_bin} search "query"
```

Track posts in `workspace/twitter/posts/`.
"""
path = os.path.join(workspace, "TWITTER.md")
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
os.chmod(path, 0o644)
PY
  _write_twitter_workspace_guidance_in_container "$container"
}


_write_twitter_workspace_guidance_in_container() {
  local container="$1"
  local slug agent_id
  slug="$(twitter_clawhub_skill_slug)"
  agent_id="${container#openclaw-}"
  podman exec -i "$container" python3 - "$slug" "$agent_id" <<'PY'
import os, re, sys
slug, agent_id = sys.argv[1], sys.argv[2]
workspace = "/home/node/.openclaw/workspace"
bird_bin = "workspace/node_modules/.bin/bird"
tools_path = os.path.join(workspace, "TOOLS.md")
agents_path = os.path.join(workspace, "AGENTS.md")
tools_block = f"""
## X / Twitter ({agent_id})

- **Post on x.com:** `{slug}` + `bird` CLI — read **`TWITTER.md`**
- **Command:** `{bird_bin} tweet "…"`
- **Session:** `AUTH_TOKEN` + `CT0` — `./identyclaw.sh set-twitter-cookies {agent_id}`
- **Not for X:** `message` tool (Discord only). No paid AIsa API.
"""
agents_block = f"""
## X / Twitter

- You **can** post on x.com via **`{slug}`** + `{bird_bin} tweet "…"` — read **`TWITTER.md`** first.
- Requires `AUTH_TOKEN` and `CT0` session cookies (not password login in browser).
- If cookies missing, tell operator to run `./identyclaw.sh set-twitter-cookies {agent_id}`.
- **Do not** use `message` for X. Never paste cookies in chat.
"""
for path, block in ((tools_path, tools_block), (agents_path, agents_block)):
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"\n## X / Twitter[^\n]*\n.*?(?=\n## |\Z)", "", text, flags=re.S)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.rstrip() + block + "\n")
PY
}


_heartbeat_twitter_mentions_prompt() {
  _heartbeat_prompt_from_template twitter-mentions
}


write_twitter_heartbeat_doc() {
  local config_dir="$1"
  local container="${2:-}"
  local agent_id prompt
  agent_id="$(basename "$config_dir")"
  prompt="$(_heartbeat_twitter_mentions_prompt)"
  apply_workspace_heartbeat_task "$config_dir" "$container" \
    "twitter-mentions" "1h" "$prompt" \
    "# X/Twitter monitoring (hourly) — follow TWITTER.md; if bird check fails (missing/expired cookies), tell the operator to refresh via ./identyclaw.sh set-twitter-cookies ${agent_id}. If nothing needs attention, reply HEARTBEAT_OK."
}


_write_twitter_heartbeat_doc_in_container() {
  local container="$1"
  write_twitter_heartbeat_doc "$(agent_home "${container#openclaw-}")" "$container"
}


ensure_twitter_heartbeat_config() {
  ensure_heartbeat_config "$1" "1h" "${2:-}"
}


_ensure_twitter_heartbeat_config_in_container() {
  _ensure_heartbeat_config_in_container "$1" "1h"
}


ensure_twitter_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local username="" password=""
  load_env
  if is_valid_agent_id "$id"; then
    username="$(agent_env_value "$id" TWITTER_USERNAME "")"
    password="$(agent_env_value "$id" TWITTER_PASSWORD "")"
  fi
  if [[ -n "$username" && -n "$password" ]] && [[ ! -f "$config_dir/secrets/twitter.username" ]]; then
    write_twitter_secrets "$id" "$config_dir" "$username" "$password"
    echo "    (${id}: Twitter credentials loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/twitter.username" ]]; then
    sync_twitter_env "$config_dir"
    write_agent_twitter_doc "$config_dir" "$(<"$config_dir/secrets/twitter.username")"
    write_twitter_workspace_guidance "$config_dir"
    write_twitter_heartbeat_doc "$config_dir"
    ensure_twitter_heartbeat_config "$config_dir"
  fi
  ensure_twitter_bird_cookies_from_env "$id" "$config_dir"
  if [[ -n "$username" || -f "$config_dir/secrets/twitter.username" || -f "$config_dir/secrets/twitter.auth_token" ]]; then
    ensure_twitter_clawhub_skill "$id" "$config_dir"
  fi
}


ensure_instagram_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local username="" password=""
  load_env
  if is_valid_agent_id "$id"; then
    username="$(agent_env_value "$id" INSTAGRAM_USERNAME "")"
    password="$(agent_env_value "$id" INSTAGRAM_PASSWORD "")"
  fi
  if [[ -n "$username" && -n "$password" ]] && [[ ! -f "$config_dir/secrets/instagram.username" ]]; then
    write_instagram_secrets "$config_dir" "$username" "$password"
    echo "    (${id}: Instagram credentials loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/instagram.username" ]]; then
    sync_instagram_env "$config_dir"
    write_agent_instagram_doc "$config_dir" "$(<"$config_dir/secrets/instagram.username")"
  fi
}


write_discord_token() {
  local config_dir="$1"
  local token="$2"
  local container="${3:-}"
  [[ -n "$token" ]] || { echo "empty Discord bot token" >&2; return 1; }
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if mkdir -p "$config_dir/secrets" 2>/dev/null && [[ -w "$config_dir/secrets" ]]; then
    printf '%s' "$token" >"$config_dir/secrets/DISCORD_BOT_TOKEN"
    chmod 600 "$config_dir/secrets/DISCORD_BOT_TOKEN"
  elif _agent_container_name_running "$container"; then
    printf '%s' "$token" | podman exec -i "$container" sh -c '
set -e
mkdir -p /home/node/.openclaw/secrets
chmod 700 /home/node/.openclaw/secrets
cat >/home/node/.openclaw/secrets/DISCORD_BOT_TOKEN
chmod 600 /home/node/.openclaw/secrets/DISCORD_BOT_TOKEN
'
  else
    echo "Cannot store Discord token: host secrets/ not writable and ${container} is not running" >&2
    echo "Run: ./identyclaw.sh restore-host-access $(agent_id_from_dir "$config_dir")" >&2
    return 1
  fi
  sync_discord_env "$config_dir" "$container"
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.setdefault("channels", {}).setdefault("discord", {})
if not discord.get("enabled"):
    discord["enabled"] = True
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


# Gateway reads DISCORD_BOT_TOKEN from --env-file; keep .env in sync with secrets/.

sync_discord_env() {
  local config_dir="$1"
  local container="${2:-}"
  local token="" use_container=0 env_path
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if [[ -r "$config_dir/secrets/DISCORD_BOT_TOKEN" ]]; then
    token="$(<"$config_dir/secrets/DISCORD_BOT_TOKEN")"
  elif _agent_container_name_running "$container"; then
    token="$(podman exec "$container" cat /home/node/.openclaw/secrets/DISCORD_BOT_TOKEN 2>/dev/null || true)"
  fi
  [[ -n "$token" ]] || return 0
  IFS=$'\t' read -r use_container env_path < <(agent_env_write_context "$config_dir" "$container")
  _agent_env_python "$config_dir" "$container" "$use_container" "$env_path" "$token" <<'PY'
import sys, os
path, token = sys.argv[1], sys.argv[2]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith("DISCORD_BOT_TOKEN=")]
lines.append(f"DISCORD_BOT_TOKEN={token}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}


write_telegram_token() {
  local config_dir="$1"
  local token="$2"
  local container="${3:-}"
  [[ -n "$token" ]] || { echo "empty Telegram bot token" >&2; return 1; }
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if mkdir -p "$config_dir/secrets" 2>/dev/null && [[ -w "$config_dir/secrets" ]]; then
    printf '%s' "$token" >"$config_dir/secrets/TELEGRAM_BOT_TOKEN"
    chmod 600 "$config_dir/secrets/TELEGRAM_BOT_TOKEN"
  elif _agent_container_name_running "$container"; then
    printf '%s' "$token" | podman exec -i "$container" sh -c '
set -e
mkdir -p /home/node/.openclaw/secrets
chmod 700 /home/node/.openclaw/secrets
cat >/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN
chmod 600 /home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN
'
  else
    echo "Cannot store Telegram token: host secrets/ not writable and ${container} is not running" >&2
    echo "Run: ./identyclaw.sh restore-host-access $(agent_id_from_dir "$config_dir")" >&2
    return 1
  fi
  sync_telegram_env "$config_dir" "$container"
  _agent_openclaw_json_python "$config_dir" "$container" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
tg = data.setdefault("channels", {}).setdefault("telegram", {})
changed = False
if not tg.get("enabled"):
    tg["enabled"] = True
    changed = True
if tg.get("tokenFile") != "/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN":
    tg["tokenFile"] = "/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN"
    changed = True
if not tg.get("dmPolicy"):
    tg["dmPolicy"] = "pairing"
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


# Gateway reads TELEGRAM_BOT_TOKEN from --env-file; keep .env in sync with secrets/.

sync_telegram_env() {
  local config_dir="$1"
  local container="${2:-}"
  local token="" use_container=0 env_path
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if [[ -r "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]]; then
    token="$(<"$config_dir/secrets/TELEGRAM_BOT_TOKEN")"
  elif _agent_container_name_running "$container"; then
    token="$(podman exec "$container" cat /home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  fi
  [[ -n "$token" ]] || return 0
  IFS=$'\t' read -r use_container env_path < <(agent_env_write_context "$config_dir" "$container")
  _agent_env_python "$config_dir" "$container" "$use_container" "$env_path" "$token" <<'PY'
import sys, os
path, token = sys.argv[1], sys.argv[2]
lines = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        lines = [ln for ln in f if not ln.startswith("TELEGRAM_BOT_TOKEN=")]
lines.append(f"TELEGRAM_BOT_TOKEN={token}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
os.chmod(path, 0o600)
PY
}


ensure_telegram_webhook_secret() {
  local config_dir="$1"
  local container="${2:-}"
  local secret_file="$config_dir/secrets/TELEGRAM_WEBHOOK_SECRET"
  local existing="" secret
  [[ -n "$container" ]] || container="$(agent_container_for_config_dir "$config_dir")"
  if [[ -r "$secret_file" ]]; then
    existing="$(tr -d '\n' <"$secret_file")"
    [[ -n "$existing" ]] && { printf '%s' "$existing"; return 0; }
  elif _agent_container_name_running "$container"; then
    existing="$(podman exec "$container" sh -c 'tr -d "\n" < /home/node/.openclaw/secrets/TELEGRAM_WEBHOOK_SECRET' 2>/dev/null || true)"
    [[ -n "$existing" ]] && { printf '%s' "$existing"; return 0; }
  fi
  secret="$(openssl rand -hex 24 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(24))')"
  if mkdir -p "$config_dir/secrets" 2>/dev/null && [[ -w "$config_dir/secrets" ]]; then
    printf '%s' "$secret" >"$secret_file"
    chmod 600 "$secret_file"
  elif _agent_container_name_running "$container"; then
    printf '%s' "$secret" | podman exec -i "$container" sh -c '
set -e
mkdir -p /home/node/.openclaw/secrets
chmod 700 /home/node/.openclaw/secrets
cat >/home/node/.openclaw/secrets/TELEGRAM_WEBHOOK_SECRET
chmod 600 /home/node/.openclaw/secrets/TELEGRAM_WEBHOOK_SECRET
'
  else
    echo "Cannot store Telegram webhook secret: host secrets/ not writable and ${container} is not running" >&2
    return 1
  fi
  printf '%s' "$secret"
}


ensure_telegram_ready() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  local has_token=0
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  if [[ -r "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]] \
    && [[ -s "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]]; then
    has_token=1
  elif _agent_container_name_running "$container" \
    && podman exec "$container" test -s /home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN 2>/dev/null; then
    has_token=1
  fi
  _agent_openclaw_json_python "$config_dir" "$container" "$has_token" "$id" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
has_token = sys.argv[2] == "1"
agent_id = sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))
tg = data.get("channels", {}).get("telegram")
if not isinstance(tg, dict):
    raise SystemExit(0)

enabled = tg.get("enabled", False)
changed = False

if enabled and not has_token:
    tg["enabled"] = False
    changed = True
    print(
        f"WARNING: {agent_id}: Telegram enabled but no token — disabled until "
        f"./identyclaw.sh set-telegram-token {agent_id}",
        file=sys.stderr,
    )
elif has_token:
    if not enabled:
        tg["enabled"] = True
        changed = True
    if tg.get("tokenFile") != "/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN":
        tg["tokenFile"] = "/home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN"
        changed = True
    if not tg.get("dmPolicy"):
        tg["dmPolicy"] = "pairing"
        changed = True

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


# Pod mode: advertise HTTPS /telegram-webhook and bind a unique local listener.
# Standalone: long-poll (no public Telegram-compatible port).

ensure_telegram_webhook() {
  local id="$1"
  local config_dir="$2"
  local container="${3:-}"
  local token="" webhook_url="" webhook_port="" secret
  [[ -n "$container" ]] || container="$(agent_container "$id")"
  agent_openclaw_json_exists "$config_dir" "$container" || return 0
  if [[ -r "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]]; then
    token="$(tr -d '\n' <"$config_dir/secrets/TELEGRAM_BOT_TOKEN")"
  elif _agent_container_name_running "$container"; then
    token="$(podman exec "$container" sh -c 'tr -d "\n" < /home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN' 2>/dev/null || true)"
  fi
  [[ -n "$token" ]] || return 0
  load_env
  if [[ "${IDENTYCLAW_DEPLOY_MODE:-standalone}" == "pod" ]]; then
    local base
    base="$(agent_ingress_base_url "$id")"
    [[ -n "$base" ]] && webhook_url="${base%/}/telegram-webhook"
    webhook_port="$(agent_telegram_webhook_port "$id")"
  fi
  secret="$(ensure_telegram_webhook_secret "$config_dir" "$container")" || return 1
  _agent_openclaw_json_python "$config_dir" "$container" \
    "${IDENTYCLAW_DEPLOY_MODE:-standalone}" "$webhook_url" "$webhook_port" "$secret" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
mode, webhook_url, webhook_port, secret = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
data = json.loads(path.read_text(encoding="utf-8"))
tg = data.setdefault("channels", {}).setdefault("telegram", {})
changed = False

def set_key(key, value):
    global changed
    if tg.get(key) != value:
        tg[key] = value
        changed = True

def del_key(key):
    global changed
    if key in tg:
        del tg[key]
        changed = True

if mode == "pod" and webhook_url.startswith("http"):
    set_key("webhookUrl", webhook_url)
    set_key("webhookSecret", secret)
    set_key("webhookPath", "/telegram-webhook")
    set_key("webhookHost", "127.0.0.1")
    set_key("webhookPort", int(webhook_port))
else:
    for key in ("webhookUrl", "webhookSecret", "webhookPath", "webhookHost", "webhookPort"):
        del_key(key)

if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)
PY
}


ensure_telegram_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local container
  local token=""
  load_env
  container="$(agent_container "$id")"
  if is_valid_agent_id "$id"; then
    token="$(agent_env_value "$id" TELEGRAM_BOT_TOKEN "")"
  fi
  if [[ -n "$token" ]] && [[ ! -f "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]]; then
    write_telegram_token "$config_dir" "$token" "$container"
    echo "    (${id}: Telegram bot token loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/TELEGRAM_BOT_TOKEN" ]] \
    || { _agent_container_name_running "$container" \
      && podman exec "$container" test -s /home/node/.openclaw/secrets/TELEGRAM_BOT_TOKEN 2>/dev/null; }; then
    sync_telegram_env "$config_dir" "$container"
  fi
  ensure_telegram_ready "$id" "$config_dir" "$container"
  ensure_telegram_webhook "$id" "$config_dir" "$container"
}


ensure_discord_secrets_from_env() {
  local id="$1"
  local config_dir="$2"
  local token=""
  load_env
  if is_valid_agent_id "$id"; then
    token="$(agent_env_value "$id" DISCORD_BOT_TOKEN "")"
  fi
  if [[ -n "$token" && ! -f "$config_dir/secrets/DISCORD_BOT_TOKEN" ]]; then
    write_discord_token "$config_dir" "$token"
    echo "    (${id}: Discord bot token loaded from env.local → secrets/)" >&2
  elif [[ -f "$config_dir/secrets/DISCORD_BOT_TOKEN" ]]; then
    sync_discord_env "$config_dir"
  fi
}


# Let peer agents reach the other gateway when a bot message @mentions them.
# Keep rootless agents running after logout (linger) and across reboot (podman-restart).


ensure_discord_allow_bots_mentions() {
  local config_dir="$1"
  local config="$config_dir/openclaw.json"
  [[ -f "$config" ]] || return 0
  python3 - "$config" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
discord = data.get("channels", {}).get("discord")
if not isinstance(discord, dict) or not discord.get("enabled"):
    raise SystemExit(0)
if discord.get("allowBots") == "mentions":
    raise SystemExit(0)
data.setdefault("channels", {}).setdefault("discord", {})["allowBots"] = "mentions"
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}
