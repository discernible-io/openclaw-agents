# Public ingress only — A2A, webhooks, Telegram webhook, and plugin API routes.
# Control UI (/, /ws, …) is intentionally not proxied on the public hostname.
# Include inside a server { } block after defining $openclaw_upstream (upstream name).

location ^~ /.well-known/ {
    limit_req zone=openclaw_ingress burst=240 nodelay;
    limit_req zone=openclaw_public burst=120 nodelay;
    include /etc/nginx/inc/openclaw-proxy.inc;
    proxy_pass http://$openclaw_upstream;
}

location = /a2a {
    limit_req zone=openclaw_ingress burst=240 nodelay;
    limit_req zone=openclaw_public burst=120 nodelay;
    include /etc/nginx/inc/openclaw-proxy.inc;
    proxy_pass http://$openclaw_upstream;
}

location ^~ /hooks/ {
    limit_req zone=openclaw_ingress burst=240 nodelay;
    limit_req zone=openclaw_public burst=120 nodelay;
    include /etc/nginx/inc/openclaw-proxy.inc;
    proxy_pass http://$openclaw_upstream;
}

# Telegram Bot API webhook listener is a separate OpenClaw bind (not the gateway).
# Each server block must set $openclaw_telegram_upstream (per-agent unique port).
location = /telegram-webhook {
    limit_req zone=openclaw_ingress burst=240 nodelay;
    limit_req zone=openclaw_public burst=120 nodelay;
    include /etc/nginx/inc/openclaw-proxy.inc;
    proxy_pass http://$openclaw_telegram_upstream;
}

location ^~ /api/ {
    limit_req zone=openclaw_ingress burst=240 nodelay;
    limit_req zone=openclaw_public burst=120 nodelay;
    include /etc/nginx/inc/openclaw-proxy.inc;
    proxy_pass http://$openclaw_upstream;
}

location / {
    return 404;
}
