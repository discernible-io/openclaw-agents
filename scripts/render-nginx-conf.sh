#!/usr/bin/env bash
# Render nginx.conf for agents in AGENT_IDS (agent-{slug}, e.g. agent-name-not-set).
# Usage: render-nginx-conf.sh <output-path>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

out="${1:?output path required}"
tier=main
tier_port=9443

load_env

mkdir -p "$(dirname "$out")"

{
  cat <<HEADER
# TLS sidecar for OpenClaw gateways — A2A + RODiT-signed webhooks.
# Rendered from AGENT_*_PUBLIC_HOST in env.local (deploy-pod.sh mounts over nginx image stub).
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/inc/http-common.inc;

HEADER

  for id in $AGENT_IDS; do
    is_valid_agent_id "$id" || continue
    host="$(agent_public_host "$id")"
    [[ -n "$host" ]] || {
      echo "    (render-nginx: skip ${id} — no AGENT_*_PUBLIC_HOST)" >&2
      continue
    }
    gw_port="$(agent_internal_gateway_port "$id")"
    upstream_name="openclaw_${id//-/_}"
    cat <<UPSTREAM
    upstream ${upstream_name} {
        server 127.0.0.1:${gw_port};
    }

UPSTREAM
  done

  for id in $AGENT_IDS; do
    is_valid_agent_id "$id" || continue
    host="$(agent_public_host "$id")"
    [[ -n "$host" ]] || continue
    ingress_port="$(agent_ingress_port "$id")"
    [[ -n "$ingress_port" ]] || ingress_port="$tier_port"
    upstream_name="openclaw_${id//-/_}"
    cat <<SERVER
    # ${id} — ${host}:${ingress_port}
    server {
        listen ${ingress_port} ssl;
        http2 on;
        server_name ${host};
        ssl_certificate /app/certs/fullchain.pem;
        ssl_certificate_key /app/certs/privkey.pem;
        include /etc/nginx/inc/security-headers.inc;

        location @request_error {
            internal;
            default_type text/plain;
            return 400 "request too large\n";
        }

        location = /health {
            limit_req zone=openclaw_health burst=10 nodelay;
            default_type text/plain;
            return 200 "healthy\n";
        }

        location / {
            limit_req zone=openclaw_ingress burst=240 nodelay;
            limit_req zone=openclaw_public burst=120 nodelay;
            include /etc/nginx/inc/openclaw-proxy.inc;
            proxy_pass http://${upstream_name};
        }
    }

SERVER
  done

  echo "}"
} >"$out"

echo "Rendered ${out} (AGENT_IDS=${AGENT_IDS})"
