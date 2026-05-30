#!/bin/sh
# Seed bundled plugins into the mounted OpenClaw home when missing.
set -eu

BUNDLED="${IDENTYCLAW_PLUGIN_SEED:-/opt/identyclaw/plugin-seed}/npm"
TARGET="/home/node/.openclaw/npm"
MARKER="${TARGET}/node_modules/@openclaw/discord/package.json"

if [ -d "$BUNDLED" ] && [ ! -f "$MARKER" ]; then
  mkdir -p "$TARGET"
  cp -a "${BUNDLED}/." "${TARGET}/"
fi

exec tini -s -- "$@"
