#!/bin/sh
# Seed bundled channel plugins into the mounted OpenClaw home.
# Re-copy when the image seed or gateway version drifts (survives redeploy).
set -eu

BUNDLED="${IDENTYCLAW_PLUGIN_SEED:-/opt/identyclaw/plugin-seed}/npm"
TARGET="/home/node/.openclaw/npm"
DISCORD_PKG="${TARGET}/node_modules/@openclaw/discord/package.json"
GATEWAY_VER="$(node -e "process.stdout.write(require('/app/package.json').version)")"

needs_seed=0
if [ ! -f "$DISCORD_PKG" ]; then
  needs_seed=1
elif [ -d "$BUNDLED" ] && [ -f "${BUNDLED}/node_modules/@openclaw/discord/package.json" ]; then
  bundled_ver="$(node -e "process.stdout.write(require('${BUNDLED}/node_modules/@openclaw/discord/package.json').version)")"
  installed_ver="$(node -e "process.stdout.write(require('${DISCORD_PKG}').version)")"
  if [ "$bundled_ver" != "$installed_ver" ] || [ "$installed_ver" != "$GATEWAY_VER" ]; then
    needs_seed=1
  fi
fi

if [ "$needs_seed" = 1 ] && [ -d "$BUNDLED" ]; then
  mkdir -p "$TARGET"
  rm -rf "${TARGET}/node_modules/@openclaw/discord"
  cp -a "${BUNDLED}/." "${TARGET}/"
fi

exec tini -s -- "$@"
