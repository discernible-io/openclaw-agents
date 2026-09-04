#!/bin/sh
# Seed bundled channel plugins into the mounted OpenClaw home.
# Re-copy when the image seed or gateway version drifts (survives redeploy).
set -eu

BUNDLED="${IDENTYCLAW_PLUGIN_SEED:-/opt/identyclaw/plugin-seed}/npm"
TARGET="/home/node/.openclaw/npm"
DISCORD_PKG="${TARGET}/node_modules/@openclaw/discord/package.json"
GATEWAY_VER="$(node -e "process.stdout.write(require('/app/package.json').version)")"
# Gateway version from /app/package.json; bundled Discord must match (correction suffix stripped).
DISCORD_LINE_VER="$(node -e "const g=process.argv[1]; const m=String(g).match(/^(\\d+\\.\\d+\\.\\d+)-\\d+$/); process.stdout.write(m?m[1]:g)" -- "$GATEWAY_VER")"

needs_seed=0
installed_ver=""
if [ -f "$DISCORD_PKG" ]; then
  installed_ver="$(node -e "process.stdout.write(require('${DISCORD_PKG}').version)")"
elif [ -d "${TARGET}/projects" ]; then
  for proj in "${TARGET}"/projects/openclaw-discord-*/node_modules/@openclaw/discord/package.json; do
    [ -f "$proj" ] || continue
    installed_ver="$(node -e "process.stdout.write(require('${proj}').version)")"
    break
  done
fi
if [ -z "$installed_ver" ]; then
  needs_seed=1
elif [ -d "$BUNDLED" ] && [ -f "${BUNDLED}/node_modules/@openclaw/discord/package.json" ]; then
  bundled_ver="$(node -e "process.stdout.write(require('${BUNDLED}/node_modules/@openclaw/discord/package.json').version)")"
  if [ "$bundled_ver" != "$installed_ver" ] || { [ "$installed_ver" != "$GATEWAY_VER" ] && [ "$installed_ver" != "$DISCORD_LINE_VER" ]; }; then
    needs_seed=1
  fi
fi

if [ "$needs_seed" = 1 ] && [ -d "$BUNDLED" ]; then
  mkdir -p "$TARGET"
  rm -rf "${TARGET}/node_modules/@openclaw/discord" "${TARGET}/projects/openclaw-discord-"*
  cp -a "${BUNDLED}/." "${TARGET}/"
fi

# Hotfix OpenClaw long-session "(see attached image)" tool-result placeholder
# (aggregate truncation / husk media blocks). Idempotent; no-op when already applied.
if [ -f /opt/identyclaw/patch-openclaw-tool-result-images.mjs ]; then
  node /opt/identyclaw/patch-openclaw-tool-result-images.mjs --root /app \
    || echo "[identyclaw] tool-result image patch skipped" >&2
fi

# Coerce LLM-stringified JSON bodies in identyclaw_request (avoids INVALID_JSON).
# Plugin lives on the bind-mounted OpenClaw home — re-apply on every start so
# image rebuild / podman-restart survive without relying on host APP_DIR/repo sync.
# No-op when the extension is not installed yet (host start/upgrade patches after).
if [ -f /opt/identyclaw/patch-identyclaw-request-body.mjs ]; then
  node /opt/identyclaw/patch-identyclaw-request-body.mjs --root /home/node/.openclaw \
    || echo "[identyclaw] request-body patch skipped" >&2
fi

# Keep nested OpenRouter model ids (openrouter/openai/…) working when OpenClaw
# reparses them onto native vendor providers. Mirror the OpenRouter key into the
# vendor env vars the reparsed providers look for, then patch openclaw.json:
# register OpenRouter catalog + alias openai/anthropic/google/… baseUrl → OpenRouter.
# Reads primary/fallbacks from bind-mounted openclaw.json — no host env.local.
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  # Only fill blanks — never clobber a real native vendor key.
  [ -n "${OPENAI_API_KEY:-}" ] || export OPENAI_API_KEY="$OPENROUTER_API_KEY"
  [ -n "${ANTHROPIC_API_KEY:-}" ] || export ANTHROPIC_API_KEY="$OPENROUTER_API_KEY"
  [ -n "${GOOGLE_API_KEY:-}" ] || export GOOGLE_API_KEY="$OPENROUTER_API_KEY"
  [ -n "${DEEPSEEK_API_KEY:-}" ] || export DEEPSEEK_API_KEY="$OPENROUTER_API_KEY"
fi
if [ -f /opt/identyclaw/patch-openclaw-model-routing.py ] \
  && [ -f /home/node/.openclaw/openclaw.json ]; then
  python3 /opt/identyclaw/patch-openclaw-model-routing.py \
    /home/node/.openclaw/openclaw.json \
    || echo "[identyclaw] model-routing patch skipped" >&2
fi

# Sticky OpenRouter session_id + diagnostics.cacheTrace — always after model-routing,
# which rebuilds agents.defaults.models. Baked into the image so rebuild/restart
# re-applies without waiting for host sync. Defaults match host load_env; override
# via container env OPENCLAW_OPENROUTER_SESSION_ID / OPENCLAW_CACHE_TRACE when set.
if [ -f /opt/identyclaw/patch-openclaw-cache-config.mjs ] \
  && [ -f /home/node/.openclaw/openclaw.json ]; then
  # Enable sticky body/header injection when the configured primary is OpenRouter
  # (matches host ensure_openclaw_model_defaults). Non-OpenRouter fleets get
  # cacheTrace only via --openrouter 0.
  _or=0
  if node -e '
    const fs = require("fs");
    let d = {};
    try { d = JSON.parse(fs.readFileSync("/home/node/.openclaw/openclaw.json", "utf8")); } catch {}
    const p = (((d.agents || {}).defaults || {}).model || {}).primary || "";
    process.exit(String(p).startsWith("openrouter/") ? 0 : 1);
  ' 2>/dev/null; then
    _or=1
  fi
  node /opt/identyclaw/patch-openclaw-cache-config.mjs \
    /home/node/.openclaw/openclaw.json \
    --session-id "${OPENCLAW_OPENROUTER_SESSION_ID:-identyclaw}" \
    --cache-trace "${OPENCLAW_CACHE_TRACE:-1}" \
    --openrouter "$_or" \
    || echo "[identyclaw] cache-config patch skipped" >&2
fi

# Leftover exec-approvals.json lives on the bind-mounted OpenClaw home, so it
# survives image rebuilds. Newer OpenClaw stores approvals in SQLite and fails
# closed with ExecApprovalsMigrationRequiredError while this file exists.
if [ -f /home/node/.openclaw/exec-approvals.json ]; then
  mv -f /home/node/.openclaw/exec-approvals.json \
    /home/node/.openclaw/exec-approvals.json.identyclaw-retired \
    || rm -f /home/node/.openclaw/exec-approvals.json || true
fi

# OpenClaw 2026.8+ rejects channel transcripts that start with /new reset boundaries
# before a v3 session header exists. Repair persisted stores before gateway start.
if [ -f /opt/identyclaw/repair-openclaw-session-headers.py ]; then
  python3 /opt/identyclaw/repair-openclaw-session-headers.py /home/node/.openclaw \
    || echo "[identyclaw] session-header repair skipped" >&2
fi

# Non-canonical session keys fail closed (SessionCanonicalKeyMigrationRequiredError)
# and freeze Telegram/Discord until `openclaw doctor --fix`. Bind-mounted state
# survives image rebuild — re-run on every start while the gateway is down.
# Skip with IDENTYCLAW_SKIP_SESSION_CANONICAL_DOCTOR=1.
if [ -x /opt/identyclaw/repair-openclaw-session-canonical.sh ]; then
  /opt/identyclaw/repair-openclaw-session-canonical.sh /home/node/.openclaw || true
  # Doctor may rewrite openclaw.json (catalog contextWindow, stale plugins).
  # Re-apply host-independent routing/cache patches so rebuilds stay consistent.
  if [ -f /opt/identyclaw/patch-openclaw-model-routing.py ] \
    && [ -f /home/node/.openclaw/openclaw.json ]; then
    python3 /opt/identyclaw/patch-openclaw-model-routing.py \
      /home/node/.openclaw/openclaw.json \
      || echo "[identyclaw] model-routing re-patch skipped" >&2
  fi
  if [ -f /opt/identyclaw/patch-openclaw-cache-config.mjs ] \
    && [ -f /home/node/.openclaw/openclaw.json ]; then
    _or=0
    if node -e '
      const fs = require("fs");
      let d = {};
      try { d = JSON.parse(fs.readFileSync("/home/node/.openclaw/openclaw.json", "utf8")); } catch {}
      const p = (((d.agents || {}).defaults || {}).model || {}).primary || "";
      process.exit(String(p).startsWith("openrouter/") ? 0 : 1);
    ' 2>/dev/null; then
      _or=1
    fi
    node /opt/identyclaw/patch-openclaw-cache-config.mjs \
      /home/node/.openclaw/openclaw.json \
      --session-id "${OPENCLAW_OPENROUTER_SESSION_ID:-identyclaw}" \
      --cache-trace "${OPENCLAW_CACHE_TRACE:-1}" \
      --openrouter "$_or" \
      || echo "[identyclaw] cache-config re-patch skipped" >&2
  fi
fi

exec tini -s -- "$@"
