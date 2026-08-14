#!/usr/bin/env bash
# Local Podman deploy — mirrors .github/workflows/deploy.yml on this host.
#
# Tier defaults match deploy.yml: main branch -> main tier; development (or any
# other branch) -> development tier. Override with TARGET=main|development.
#
# Usage (repo root):
#   ./scripts/deploy-local-podman.sh
#   TARGET=main ./scripts/deploy-local-podman.sh
#   ./scripts/deploy-local-podman.sh --skip-build
#
# Env:
#   APP_DIR                  Default: ../openclaw-agents-app (sibling of repo)
#   APP_PORT                 Default: 88 (all tiers) via deploy_tier_app_port
#   TARGET                   Override tier (default: from current git branch)
#   GITHUB_SHA               Image tag (default: git HEAD)
#   PULL_FROM_GHCR=1         Pull images instead of local build
#   USE_LOCAL_RESOLVE=1      curl --resolve for health check on loopback
#   SKIP_PLUGIN_UPDATE=1     Skip cloning/building GitHub plugins (deploy-pod.sh)
#
# Requires git + npm (Node 22+) on the host — plugins are built during deploy.

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '1,22p' "$0"
      exit 0
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

APP_DIR="${APP_DIR:-$(identyclaw_app_dir)}"
APP_DIR="${APP_DIR/#\~/$HOME}"
REGISTRY="${REGISTRY:-ghcr.io}"
USE_LOCAL_RESOLVE="${USE_LOCAL_RESOLVE:-0}"
PULL_FROM_GHCR="${PULL_FROM_GHCR:-0}"
HEALTH_CHECK_MAX_ATTEMPTS="${HEALTH_CHECK_MAX_ATTEMPTS:-5}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-5}"

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  DEPLOY_SHA="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
else
  DEPLOY_SHA="${GITHUB_SHA:-local}"
fi

DEPLOY_TIER="$(resolve_deploy_tier "$REPO_ROOT")"
case "$DEPLOY_TIER" in
  development|main) ;;
  *)
    echo "TARGET must be development or main (got: $DEPLOY_TIER)" >&2
    exit 1
    ;;
esac

APP_PORT="${APP_PORT:-$(deploy_tier_app_port "$DEPLOY_TIER")}"
POD_LISTEN_PORT="${POD_LISTEN_PORT:-$APP_PORT}"
POD_HOST_PORT="${POD_HOST_PORT:-$APP_PORT}"
NGINX_BUILD_ENV="$(deploy_tier_nginx_build_env "$DEPLOY_TIER")"

github_repository_from_origin() {
  local url origin
  origin="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)" || return 1
  case "$origin" in
    git@github.com:*.git) url="${origin#git@github.com:}"; url="${url%.git}" ;;
    https://github.com/*.git) url="${origin#https://github.com/}"; url="${url%.git}" ;;
    *) return 1 ;;
  esac
  printf '%s' "$url"
}
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(github_repository_from_origin || echo discernible-io/openclaw-agents)}"
OPENCLAW_IMAGE_NAME="${OPENCLAW_IMAGE_NAME:-${GITHUB_REPOSITORY}/openclaw-agent}"
NGINX_IMAGE_NAME="${NGINX_IMAGE_NAME:-${GITHUB_REPOSITORY}/identyclaw-nginx}"
IMAGE_TAG="${DEPLOY_SHA}-${DEPLOY_TIER}"
OPENCLAW_IMAGE="${REGISTRY}/${OPENCLAW_IMAGE_NAME}:${IMAGE_TAG}"
NGINX_IMAGE="${REGISTRY}/${NGINX_IMAGE_NAME}:${IMAGE_TAG}"

cd "$REPO_ROOT"

build_images() {
  local arch bundled_plugins
  load_env
  bundled_plugins="$(resolve_openclaw_bundled_plugins)"
  arch="$(uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')"
  echo "==> Building ${OPENCLAW_IMAGE} (gateway ${OPENCLAW_GATEWAY_VERSION})"
  local near_target
  near_target="$(uname -m | sed 's/x86_64/x86_64-unknown-linux-gnu/;s/aarch64/aarch64-unknown-linux-gnu/')"
  podman build -f "$REPO_ROOT/Containerfile.agent" -t "$OPENCLAW_IMAGE" "$REPO_ROOT" \
    --build-arg "OPENCLAW_BASE_IMAGE=${OPENCLAW_BASE_IMAGE}" \
    --build-arg "OPENCLAW_GATEWAY_VERSION=${OPENCLAW_GATEWAY_VERSION}" \
    --build-arg "OPENCLAW_BUNDLED_PLUGINS=${bundled_plugins}" \
    --build-arg "HIMALAYA_VERSION=${HIMALAYA_VERSION}" \
    --build-arg "HIMALAYA_ARCH=${arch}" \
    --build-arg "NEAR_CLI_RS_VERSION=${NEAR_CLI_RS_VERSION:-v0.29.0}" \
    --build-arg "NEAR_CLI_RS_TARGET=${near_target}"
  echo "==> Building ${NGINX_IMAGE} (NODE_ENV=${NGINX_BUILD_ENV}, INGRESS_PORT=${APP_PORT})"
  podman build -f "$REPO_ROOT/nginx.Dockerfile" -t "$NGINX_IMAGE" "$REPO_ROOT" \
    --build-arg "NODE_ENV=${NGINX_BUILD_ENV}" \
    --build-arg "INGRESS_PORT=${APP_PORT}"
}

if [[ "$PULL_FROM_GHCR" == 1 ]]; then
  podman pull "$OPENCLAW_IMAGE"
  podman pull "$NGINX_IMAGE"
elif [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_images
fi

"$REPO_ROOT/scripts/ensure-podman-linger.sh"

echo "==> Sync deploy scripts to ${APP_DIR}/repo (matches CI deploy.yml)"
sync_deploy_scripts_to_app_dir "$REPO_ROOT" "$APP_DIR"

IDENTYCLAW_APP_DIR="$APP_DIR" \
APP_DIR="$APP_DIR" \
OPENCLAW_IMAGE="$OPENCLAW_IMAGE" \
NGINX_IMAGE="$NGINX_IMAGE" \
APP_PORT="$APP_PORT" \
POD_LISTEN_PORT="$POD_LISTEN_PORT" \
POD_HOST_PORT="$POD_HOST_PORT" \
DEPLOY_TIER="$DEPLOY_TIER" \
REPO_ROOT="$REPO_ROOT" \
SKIP_PULL=1 \
bash "$REPO_ROOT/scripts/deploy-pod.sh"

echo "==> Operator CLI (pod restart / status): ${APP_DIR}/repo/identyclaw.sh"

read -r HEALTH_HOST HEALTH_PORT < <(IDENTYCLAW_APP_DIR="$APP_DIR" deploy_health_ingress)
HEALTH_URL="https://${HEALTH_HOST}:${HEALTH_PORT}/health"
echo "==> Health check: ${HEALTH_URL} (tier=${DEPLOY_TIER}, tag=${IMAGE_TAG})"
attempt=0
while [[ $attempt -lt $HEALTH_CHECK_MAX_ATTEMPTS ]]; do
  if [[ "$USE_LOCAL_RESOLVE" == 1 ]]; then
    if curl -sk --resolve "${HEALTH_HOST}:${HEALTH_PORT}:127.0.0.1" "$HEALTH_URL" | grep -q healthy; then
      echo "healthy"
      exit 0
    fi
  elif curl -sk "$HEALTH_URL" | grep -q healthy; then
    echo "healthy"
    exit 0
  fi
  attempt=$((attempt + 1))
  echo "Health check attempt ${attempt}/${HEALTH_CHECK_MAX_ATTEMPTS}"
  if [[ $attempt -lt $HEALTH_CHECK_MAX_ATTEMPTS ]]; then
    sleep "$HEALTH_CHECK_INTERVAL"
  fi
done
if [[ "$USE_LOCAL_RESOLVE" != 1 ]]; then
  echo "health check failed (use USE_LOCAL_RESOLVE=1 if DNS is not pointed here yet)" >&2
else
  echo "health check failed (nginx may still be starting)" >&2
fi
exit 1
