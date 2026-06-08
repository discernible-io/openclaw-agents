#!/usr/bin/env bash
# Local Podman deploy — mirrors .github/workflows/deploy.yml on this host.
#
# Usage (repo root):
#   ./scripts/deploy-local-podman.sh
#   TARGET=main ./scripts/deploy-local-podman.sh
#   ./scripts/deploy-local-podman.sh --skip-build
#
# Env:
#   APP_DIR                  Default: ~/identyclaw-agents-app
#   APP_PORT                 Default: 9443 (main) or 4443 (development)
#   TARGET                   development (default) or main
#   GITHUB_SHA               Image tag (default: git HEAD)
#   PULL_FROM_GHCR=1         Pull images instead of local build
#   USE_LOCAL_RESOLVE=1      curl --resolve for health check on loopback

set -euo pipefail
[[ "${TRACE:-0}" == 1 ]] && set -x

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
  esac
done

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_DIR="${APP_DIR:-$HOME/identyclaw-agents-app}"
APP_DIR="${APP_DIR/#\~/$HOME}"
DEPLOY_TIER="${TARGET:-main}"
APP_PORT="${APP_PORT:-}"
REGISTRY="${REGISTRY:-ghcr.io}"
USE_LOCAL_RESOLVE="${USE_LOCAL_RESOLVE:-0}"
PULL_FROM_GHCR="${PULL_FROM_GHCR:-0}"

DOMAIN_MAIN="agent-a.identyclaw.com"
DOMAIN_DEVELOPMENT="agent-a.dihola.io"

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  DEPLOY_SHA="${GITHUB_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
else
  DEPLOY_SHA="${GITHUB_SHA:-local}"
fi

case "$DEPLOY_TIER" in
  development)
    NGINX_BUILD_ENV="development"
    DOMAIN="$DOMAIN_DEVELOPMENT"
    APP_PORT="${APP_PORT:-4443}"
    INGRESS_PORT="${INGRESS_PORT:-4443}"
    ;;
  main)
    NGINX_BUILD_ENV="main"
    DOMAIN="$DOMAIN_MAIN"
    APP_PORT="${APP_PORT:-9443}"
    INGRESS_PORT="${INGRESS_PORT:-9443}"
    ;;
  *)
    echo "TARGET must be development or main (got: $DEPLOY_TIER)" >&2
    exit 1
    ;;
esac

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
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$(github_repository_from_origin || echo discernible-io/identyclaw-agents)}"
OPENCLAW_IMAGE_NAME="${OPENCLAW_IMAGE_NAME:-${GITHUB_REPOSITORY}/openclaw-himalaya}"
NGINX_IMAGE_NAME="${NGINX_IMAGE_NAME:-${GITHUB_REPOSITORY}/identyclaw-nginx}"
IMAGE_TAG="${DEPLOY_SHA}-${DEPLOY_TIER}"
OPENCLAW_IMAGE="${REGISTRY}/${OPENCLAW_IMAGE_NAME}:${IMAGE_TAG}"
NGINX_IMAGE="${REGISTRY}/${NGINX_IMAGE_NAME}:${IMAGE_TAG}"

cd "$REPO_ROOT"

build_images() {
  local arch
  arch="$(uname -m | sed 's/x86_64/x86_64-linux/;s/aarch64/aarch64-linux/')"
  echo "==> Building ${OPENCLAW_IMAGE}"
  podman build -f "$REPO_ROOT/Containerfile.himalaya" -t "$OPENCLAW_IMAGE" "$REPO_ROOT" \
    --build-arg "OPENCLAW_BASE_IMAGE=ghcr.io/openclaw/openclaw:2026.5.27-slim" \
    --build-arg "HIMALAYA_VERSION=v1.2.0" \
    --build-arg "HIMALAYA_ARCH=${arch}"
  echo "==> Building ${NGINX_IMAGE} (NODE_ENV=${NGINX_BUILD_ENV}, INGRESS_PORT=${INGRESS_PORT})"
  podman build -f "$REPO_ROOT/nginx.Dockerfile" -t "$NGINX_IMAGE" "$REPO_ROOT" \
    --build-arg "NODE_ENV=${NGINX_BUILD_ENV}" \
    --build-arg "INGRESS_PORT=${INGRESS_PORT}"
}

if [[ "$PULL_FROM_GHCR" == 1 ]]; then
  podman pull "$OPENCLAW_IMAGE"
  podman pull "$NGINX_IMAGE"
elif [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_images
fi

"$REPO_ROOT/scripts/ensure-podman-linger.sh"

IDENTYCLAW_APP_DIR="$APP_DIR" \
APP_DIR="$APP_DIR" \
OPENCLAW_IMAGE="$OPENCLAW_IMAGE" \
NGINX_IMAGE="$NGINX_IMAGE" \
APP_PORT="$APP_PORT" \
REPO_ROOT="$REPO_ROOT" \
SKIP_PULL=1 \
bash "$REPO_ROOT/scripts/deploy-pod.sh"

HEALTH_URL="https://${DOMAIN}:${APP_PORT}/health"
echo "==> Health check: ${HEALTH_URL} (tier=${DEPLOY_TIER}, tag=${IMAGE_TAG})"
if [[ "$USE_LOCAL_RESOLVE" == 1 ]]; then
  curl -sk --resolve "${DOMAIN}:${APP_PORT}:127.0.0.1" "$HEALTH_URL" | grep -q healthy && echo "healthy" || echo "health check failed (nginx may still be starting)"
else
  curl -sk "$HEALTH_URL" | grep -q healthy && echo "healthy" || echo "health check failed (use USE_LOCAL_RESOLVE=1 if DNS is not pointed here yet)"
fi
