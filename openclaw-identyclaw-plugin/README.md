# IdentyClaw OpenClaw Plugin

OpenClaw tool plugin that wraps the IdentyClaw HTTP API.

## Tools

- `identyclaw_list_agents` (public)
- `identyclaw_get_my_identity` (JWT required)
- `identyclaw_get_nonce` (JWT required)
- `identyclaw_verify_hola` (JWT required)
- `identyclaw_list_resources` (public)
- `identyclaw_get_resource` (public)

## Required config for protected tools

Provide either plugin config values or environment variables:

- `baseUrl` (default: `https://api.identyclaw.com`)
- `accountid` (64-char hex NEAR implicit account id)
- `nearPrivateKey` (NEAR private key, usually `ed25519:...`)

Environment variable fallback:

- `IDENTYCLAW_BASE_URL`
- `IDENTYCLAW_ACCOUNT_ID`
- `IDENTYCLAW_NEAR_PRIVATE_KEY`

## Notes

- The plugin auto-logins and caches JWTs until near expiry.
- Login follows the required flow:
  1. `GET /api/login/timestamp`
  2. Sign `accountid + timestamp_iso` with Ed25519
  3. `POST /api/login` with `accountid`, `timestamp`, and `base64url_signature`

## Optional tools

Protected tools are marked optional in the manifest:

- `identyclaw_get_my_identity`
- `identyclaw_get_nonce`
- `identyclaw_verify_hola`

This allows safer rollout where only public tools are enabled by default.

## Smoke test

Run a basic endpoint smoke test from this plugin folder:

```bash
npm run smoke:test
```

Optional environment variables:

- `IDENTYCLAW_BASE_URL` (defaults to `https://api.identyclaw.com`)
- `IDENTYCLAW_JWT` (if set, protected endpoint checks are included)
