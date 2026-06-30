#!/usr/bin/env bash
# Render nginx.conf with AGENT_*_PUBLIC_HOST aliases for agents in AGENT_IDS.
# Usage: render-nginx-conf.sh <development|main> <output-path>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

tier="${1:?tier required (development|main)}"
out="${2:?output path required}"

case "$tier" in
  development|main) ;;
  *)
    echo "tier must be development or main (got: $tier)" >&2
    exit 1
    ;;
esac

load_env
AGENT_IDS="${AGENT_IDS:-agent-b}"

template="${REPO_ROOT}/nginx/nginx.${tier}.conf"
[[ -f "$template" ]] || { echo "missing template: $template" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
cp "$template" "$out"

agent_default_host() {
  local id="$1"
  case "$tier:$id" in
    development:agent-b) echo "agent-b.dev.identyclaw.com" ;;
    development:agent-d) echo "agent-d.dev.identyclaw.com" ;;
    development:agent-f) echo "agent-f.dev.identyclaw.com" ;;
    main:agent-b) echo "agent-b.identyclaw.com" ;;
    main:agent-d) echo "agent-d.identyclaw.com" ;;
    main:agent-f) echo "agent-f.identyclaw.com" ;;
    *) return 1 ;;
  esac
}

for id in $AGENT_IDS; do
  default="$(agent_default_host "$id")" || continue
  host="$(agent_public_host "$id")"
  [[ -n "$host" && "$host" != "$default" ]] || continue
  if grep -q "server_name ${default} ${host};" "$out"; then
    continue
  fi
  sed -i "s/server_name ${default};/server_name ${default} ${host};/" "$out"
done

echo "Rendered ${out} (tier=${tier}, AGENT_IDS=${AGENT_IDS})"
