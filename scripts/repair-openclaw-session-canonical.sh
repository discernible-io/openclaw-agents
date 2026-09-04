#!/bin/sh
# Canonicalize OpenClaw session-store keys while the gateway is down.
#
# Non-canonical / alias session rows fail closed at runtime with
# SessionCanonicalKeyMigrationRequiredError — Telegram (and other channel)
# handlers spool forever and look "dead" until `openclaw doctor --fix`.
# State lives on the bind-mounted OpenClaw home, so image rebuild alone does
# not repair it; this script is meant for the container entrypoint (and the
# host doctor-fix CLI) so every start re-applies the repair.
#
# Usage (gateway must be stopped / not yet started):
#   repair-openclaw-session-canonical.sh [/home/node/.openclaw]
set -eu

HOME_DIR="${1:-/home/node/.openclaw}"
OPENCLAW_JS="${OPENCLAW_JS:-/app/openclaw.mjs}"

if [ "${IDENTYCLAW_SKIP_SESSION_CANONICAL_DOCTOR:-0}" = "1" ]; then
  echo "[identyclaw] session-canonical doctor skipped (IDENTYCLAW_SKIP_SESSION_CANONICAL_DOCTOR=1)" >&2
  exit 0
fi

if [ ! -f "$OPENCLAW_JS" ]; then
  echo "[identyclaw] session-canonical doctor skipped (missing $OPENCLAW_JS)" >&2
  exit 0
fi

# Doctor refuses Session SQLite maintenance while a gateway lock owns state.
# Restart/crash can leave stale lock files on the bind mount.
if [ -d "$HOME_DIR/tmp" ]; then
  find "$HOME_DIR/tmp" -maxdepth 2 \( \
      -name 'gateway.*.lock' \
      -o -name 'gateway.*.lock.sqlite' \
      -o -name 'gateway.*.lock.sqlite-journal' \
      -o -name 'gateway.state.lock' \
      -o -name 'gateway.state.lock.sqlite' \
      -o -name 'gateway.state.lock.sqlite-journal' \
    \) -type f -delete 2>/dev/null || true
fi

# No session store yet (fresh agent) — nothing to canonicalize.
if [ ! -f "$HOME_DIR/state/openclaw.sqlite" ] \
  && [ ! -d "$HOME_DIR/agents" ]; then
  exit 0
fi

export OPENCLAW_HOME="$HOME_DIR"
export HOME="${HOME:-/home/node}"

echo "[identyclaw] session-canonical doctor --fix (OPENCLAW_HOME=$HOME_DIR)" >&2
# --non-interactive/--yes: safe migrations only; no prompts. Config tweaks
# (stale plugins, catalog contextWindow) are expected; entrypoint re-applies
# model-routing / cache-config afterward.
node "$OPENCLAW_JS" doctor --fix --non-interactive --yes \
  || echo "[identyclaw] session-canonical doctor --fix skipped/failed" >&2

exit 0
