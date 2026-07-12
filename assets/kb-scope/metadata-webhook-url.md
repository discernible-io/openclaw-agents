# Passport metadata — webhook_url

**Keywords:** webhook_url, metadata, passport metadata, set webhook, update webhook, gateway URL, redeploy

## Quick answer

Set `webhook_url` in Passport metadata to your OpenClaw gateway **base URL** (scheme + host + port, **no** `/hooks/agent` path). Peers resolve it via `GET /api/identity/token/{tokenId}/full` → `metadata.webhook_url`.

```text
Passport metadata webhook_url:  https://my-agent.example.com:9443
IdentyClaw POST target:         https://my-agent.example.com:9443/hooks/agent
```

IdentyClaw appends hook paths when sending — do **not** embed `/hooks/agent` in metadata unless your deployment expects a full URL without path appending.

## When to set it

| Situation | What to do |
|-----------|------------|
| **New Passport (mint)** | Enter **Webhook URL** in the purchase form at **https://purchase.identyclaw.com** (under Additional Passport Fields). Highly recommended for OpenClaw deployments. |
| **Redeploy on new host** | Update `webhook_url` to the new gateway base URL so peers resolving by `tokenId` reach the live ingress. Same 12-letter `tokenId`; only the published URL changes. |
| **Inbound HOLA webhooks** | Set base URL + enable `@identyclaw/openclaw-identyclaw-webhooks-plugin` on `/hooks/agent` (and optionally `/hooks/wake`). See `openclaw-integration-guide.md`. |

## Example metadata

```json
{
  "webhook_url": "https://my-openclaw.example.com:9443",
  "webhook_cidr": "203.0.113.0/24"
}
```

Optional `webhook_cidr` restricts accepted source IPs when your gateway has a stable egress range.

## Verify after setting

1. API login (`POST /api/login`) with your Passport key.
2. Check your identity:

```bash
curl -sS -H "Authorization: Bearer $JWT" \
  https://api.identyclaw.com/api/me/identity | jq '.metadata.webhook_url'
```

Or use the OpenClaw plugin tool `identyclaw_get_my_identity`.

3. In development, test inbound delivery with `POST /api/testhola` (requires `WEBHOOK_TEST_ENABLED` on the API host). See `openclaw-integration-guide.md`.

## OpenClaw identyclaw-agents deployments

- Public HTTPS ingress is typically `https://<AGENT_*_PUBLIC_HOST>:9443` (nginx TLS sidecar).
- Register that **base URL** in Passport metadata — not the internal Podman port.
- After deploy, run `./identyclaw.sh test <agent-id>` to validate A2A, webhooks, and identity.

## Related fields

Full metadata reference: `token-metadata.md`. Contact routing alternative: `ContactURI` in the Distinguished Name (DN) — useful when HTTP ingress is unavailable; HOLA can travel on email or messaging instead.

## Full guides

- `openclaw-integration-guide.md` — wire webhooks and test flows
- `openclaw-passport-value.md` — why stable `tokenId` + updatable `webhook_url` beats hardcoded peer URLs
- `enrollment.md` — mint form fields including Webhook URL at purchase
