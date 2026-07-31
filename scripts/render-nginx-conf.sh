#!/usr/bin/env bash
# Render nginx.conf for agents in AGENT_IDS (any agent-{a-z} slug).
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

tier_default_ingress_port() {
  case "$tier" in
    development|main) echo "7443" ;;
  esac
}

tier_port="$(tier_default_ingress_port)"
tier_comment="$([[ "$tier" == development ]] && echo "Development" || echo "Main")"

mkdir -p "$(dirname "$out")"

{
  cat <<HEADER
# TLS sidecar for OpenClaw gateways — primary surfaces:
#   A2A: POST /a2a, GET /.well-known/agent-card.json (RODiT JWT on POST)
#   Webhooks: POST /hooks/wake, POST /hooks/agent, POST /hooks/<name> (RODiT x-signature + x-timestamp)
#   Plugin API: POST /api/login, GET /api/login/timestamp (P2P JWT for A2A)
# nginx terminates TLS and reverse-proxies public API paths only; Control UI stays off the public hostname.
# Gateway token auth still applies on loopback/operator paths inside the pod.
#
# ${tier_comment} ingress — per-agent hosts (AGENT_*_PUBLIC_HOST from env.local).
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
    # ${id} — A2A + webhooks @ ${host}:${ingress_port}
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

        location ^~ /.well-known/ {
            limit_req zone=openclaw_ingress burst=240 nodelay;
            limit_req zone=openclaw_public burst=120 nodelay;
            include /etc/nginx/inc/openclaw-proxy.inc;
            proxy_pass http://${upstream_name};
        }

        location = /a2a {
            limit_req zone=openclaw_ingress burst=240 nodelay;
            limit_req zone=openclaw_public burst=120 nodelay;
            include /etc/nginx/inc/openclaw-proxy.inc;
            proxy_pass http://${upstream_name};
        }

        location ^~ /hooks/ {
            limit_req zone=openclaw_ingress burst=240 nodelay;
            limit_req zone=openclaw_public burst=120 nodelay;
            include /etc/nginx/inc/openclaw-proxy.inc;
            proxy_pass http://${upstream_name};
        }

        location ^~ /api/ {
            limit_req zone=openclaw_ingress burst=240 nodelay;
            limit_req zone=openclaw_public burst=120 nodelay;
            include /etc/nginx/inc/openclaw-proxy.inc;
            proxy_pass http://${upstream_name};
        }

        location / {
            return 404;
        }
    }

SERVER
  done

  echo "}"
} >"$out"

echo "Rendered ${out} (tier=${tier}, AGENT_IDS=${AGENT_IDS})"
