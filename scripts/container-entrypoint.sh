#!/bin/sh
# Seed bundled channel plugins into the mounted OpenClaw home.
# Re-copy when the image seed or gateway version drifts (survives redeploy).
set -eu

BUNDLED="${IDENTYCLAW_PLUGIN_SEED:-/opt/identyclaw/plugin-seed}/npm"
TARGET="/home/node/.openclaw/npm"
DISCORD_PKG="${TARGET}/node_modules/@openclaw/discord/package.json"
GATEWAY_VER="$(node -e "process.stdout.write(require('/app/package.json').version)")"
# Correction gateways (2026.7.1-2) ship Discord 2026.7.1 when npm has no matching tag.
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

# Keep nested OpenRouter model ids (openrouter/openai/…) on OpenRouter.
# Reads primary/fallbacks from bind-mounted openclaw.json — no host env.local.
# Re-applies catalog + disables native openai/anthropic/google plugins + clears
# sticky sqlite session pins that would otherwise 401 at api.openai.com.
if [ -f /opt/identyclaw/patch-openclaw-model-routing.py ] \
  && [ -f /home/node/.openclaw/openclaw.json ]; then
  python3 /opt/identyclaw/patch-openclaw-model-routing.py \
    /home/node/.openclaw/openclaw.json \
    || echo "[identyclaw] model-routing patch skipped" >&2
fi

# Leftover exec-approvals.json lives on the bind-mounted OpenClaw home, so it
# survives image rebuilds. Newer OpenClaw stores approvals in SQLite and fails
# closed with ExecApprovalsMigrationRequiredError while this file exists.
if [ -f /home/node/.openclaw/exec-approvals.json ]; then
  mv -f /home/node/.openclaw/exec-approvals.json \
    /home/node/.openclaw/exec-approvals.json.identyclaw-retired \
    || rm -f /home/node/.openclaw/exec-approvals.json || true
fi

exec tini -s -- "$@"
