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
AGENT_IDS="${AGENT_IDS:-agent-a agent-c agent-e}"

template="${REPO_ROOT}/nginx/nginx.${tier}.conf"
[[ -f "$template" ]] || { echo "missing template: $template" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
cp "$template" "$out"

agent_default_host() {
  local id="$1"
  case "$tier:$id" in
    development:agent-a) echo "agent-a.dev.identyclaw.com" ;;
    development:agent-c) echo "agent-c.dev.identyclaw.com" ;;
    development:agent-e) echo "agent-e.dev.identyclaw.com" ;;
    main:agent-a) echo "agent-a.identyclaw.com" ;;
    main:agent-c) echo "agent-c.identyclaw.com" ;;
    main:agent-e) echo "agent-e.identyclaw.com" ;;
    *) return 1 ;;
  esac
}

tier_default_ingress_port() {
  case "$tier" in
    development) echo "7443" ;;
    main) echo "9443" ;;
  esac
}

tier_port="$(tier_default_ingress_port)"

for id in $AGENT_IDS; do
  default="$(agent_default_host "$id")" || continue
  host="$(agent_public_host "$id")"
  [[ -n "$host" && "$host" != "$default" ]] || continue
  if grep -q "server_name ${default} ${host};" "$out"; then
    continue
  fi
  sed -i "s/server_name ${default};/server_name ${default} ${host};/" "$out"
done

# Per-agent external A2A/webhook port (AGENT_*_INGRESS_PORT); template defaults to tier port.
for id in agent-a agent-c agent-e; do
  default="$(agent_default_host "$id")" || continue
  port="$(agent_ingress_port "$id")"
  [[ "$port" != "$tier_port" ]] || continue
  sed -i "/# ${id} /,/^    }/ s/listen ${tier_port} ssl;/listen ${port} ssl;/" "$out"
  sed -i "s/@ ${default}:${tier_port}/@ ${default}:${port}/" "$out"
done

echo "Rendered ${out} (tier=${tier}, AGENT_IDS=${AGENT_IDS})"
