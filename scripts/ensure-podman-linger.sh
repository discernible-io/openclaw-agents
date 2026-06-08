#!/usr/bin/env bash
# Keep rootless Podman containers running after SSH/Cursor sessions end.
#
# Usage: ./scripts/ensure-podman-linger.sh
#   DEPLOY_USER   User to enable (default: current user)
#   SKIP_LINGER=1 Skip (for hosts that use rootful Podman or systemd quadlets)

set -euo pipefail

if [[ "${SKIP_LINGER:-0}" == 1 ]]; then
  echo "SKIP_LINGER=1; not enabling logind linger"
  exit 0
fi

DEPLOY_USER="${DEPLOY_USER:-$(id -un)}"

if ! command -v loginctl >/dev/null 2>&1; then
  echo "::error::loginctl not found; cannot enable linger for rootless Podman" >&2
  exit 1
fi

linger_state() {
  loginctl show-user "$DEPLOY_USER" -p Linger --value 2>/dev/null || echo "no"
}

if [[ "$(linger_state)" == "yes" ]]; then
  echo "Linger already enabled for ${DEPLOY_USER}"
  exit 0
fi

echo "Enabling linger for ${DEPLOY_USER} (rootless Podman survives session logout)..."
if loginctl enable-linger "$DEPLOY_USER" 2>/dev/null; then
  :
elif sudo -n loginctl enable-linger "$DEPLOY_USER" 2>/dev/null; then
  echo "Enabled via sudo"
else
  echo "::error::Failed to enable linger for ${DEPLOY_USER}. On the host run: sudo loginctl enable-linger ${DEPLOY_USER}" >&2
  exit 1
fi

if [[ "$(linger_state)" != "yes" ]]; then
  echo "::error::linger is still not enabled for ${DEPLOY_USER}" >&2
  exit 1
fi

echo "Linger enabled for ${DEPLOY_USER}"
