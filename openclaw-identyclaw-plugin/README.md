# IdentyClaw OpenClaw Plugin

OpenClaw tool plugin that wraps the IdentyClaw HTTP API.

## Tools

| Tool | Auth |
|------|------|
| `identyclaw_list_agents` | public |
| `identyclaw_list_resources` | public |
| `identyclaw_get_resource` | public |
| `identyclaw_get_my_identity` | JWT (optional in manifest) |
| `identyclaw_get_nonce` | JWT (optional in manifest) |
| `identyclaw_verify_hola` | JWT (optional in manifest) |

Protected tools are optional in `openclaw.plugin.json` so you can allowlist only public tools at first.

## Prerequisites

- **Node.js 22+** on the machine that runs `npm` / `openclaw`
- **OpenClaw gateway** with CLI version **≥ 2026.5.27** (matches `openclaw.compat` in `package.json`)
- For protected tools: NEAR implicit `accountid` + `nearPrivateKey`

### Host has no `npm` (AlmaLinux / RHEL)

Install Node 22 and npm once:

```bash
sudo dnf install -y nodejs nodejs-npm
node -v   # should be v22.x
npm -v
```

`prepare:publish` only needs Node (no install step):

```bash
node ./scripts/prepare-publish.mjs
```

Or use the OpenClaw image (same checks, no host Node):

```bash
podman run --rm -v "$(pwd):/plugin:Z" -w /plugin ghcr.io/openclaw/openclaw:2026.5.27-slim \
  node ./scripts/prepare-publish.mjs
```

`openclaw plugins install` / `openclaw doctor` require the CLI on the host or inside a running gateway container (`podman exec … node /app/openclaw.mjs …`).

## Local validation (no gateway)

```bash
cd openclaw-identyclaw-plugin
npm install
npm run build          # emits dist/index.js (required for install/publish)
npm run prepare:publish
npm run smoke:test
# Optional protected API checks:
IDENTYCLAW_JWT="<jwt>" npm run smoke:test
```

## Install into OpenClaw (local path)

On the gateway host:

```bash
cd /path/to/identyclaw-agents/openclaw-identyclaw-plugin
npm install
npm run build
npm run prepare:publish
openclaw plugins install "$(pwd)"
```

For a bind-mounted dev tree inside the gateway container, use `openclaw plugins install --link "$(pwd)"` instead (allows the mounted source path without copying into `extensions/`).

Install copies the package under `~/.openclaw/extensions/`. Plugins declare `openclaw` as a **peerDependency** (not bundled). Newer OpenClaw builds symlink the host `openclaw` into the extension after install; older builds may only print a peer link warning.

If the gateway logs `Cannot find package 'openclaw'` from the extension:

```bash
openclaw doctor --fix
# or, inside the extension directory:
# cd ~/.openclaw/extensions/<plugin-folder> && npm link openclaw
```

Restart the gateway after install or doctor repair.

## Gateway config + tool allowlist

Plugin manifest id: **`identyclaw-tools`**. Merge `docs/openclaw.sample.json` into your OpenClaw config (e.g. `~/.openclaw/openclaw.json` or agent-specific config). Minimal public-only rollout:

```json
{
  "plugins": {
    "allow": ["identyclaw-tools"],
    "entries": {
      "identyclaw-tools": {
        "enabled": true,
        "config": {
          "baseUrl": "https://api.identyclaw.com"
        }
      }
    }
  },
  "tools": {
    "allow": [
      "identyclaw_list_agents",
      "identyclaw_list_resources",
      "identyclaw_get_resource"
    ]
  }
}
```

Add `accountid`, `nearPrivateKey`, and the three protected tool names when you are ready for JWT-backed tools. Config can also use env vars: `IDENTYCLAW_BASE_URL`, `IDENTYCLAW_ACCOUNT_ID`, `IDENTYCLAW_NEAR_PRIVATE_KEY`.

## Runtime tool checks

After config reload / gateway restart, invoke each allowlisted tool once (Control UI, `openclaw` agent chat, or your automation). Suggested parameters:

| Tool | Example input |
|------|----------------|
| `identyclaw_list_agents` | `{ "limit": 2 }` |
| `identyclaw_list_resources` | `{ "limit": 3 }` |
| `identyclaw_get_resource` | `{ "uri": "openapi:swagger" }` |
| `identyclaw_get_my_identity` | `{}` |
| `identyclaw_get_nonce` | `{}` |
| `identyclaw_verify_hola` | `{ "hello": "<signed-hola-line>" }` |

For `identyclaw_verify_hola`, build the HOLA line from `identyclaw_get_nonce` (`noncetsHex` + `timestamp`, not login `timestamp_iso`).

## Publish to ClawHub

Publisher must own the `@identyclaw` scope (package name `@identyclaw/openclaw-identyclaw-plugin`).

```bash
clawhub login
npm run build
npm run prepare:publish
clawhub package publish . --family code-plugin --dry-run
clawhub package publish . --family code-plugin
```

Post-publish install:

```bash
openclaw plugins install clawhub:@identyclaw/openclaw-identyclaw-plugin
openclaw doctor --fix
```

Use `--dry-run` before the real publish; ClawHub can lock a version slot on failed validation.

## Auth notes

- The plugin auto-logins and caches JWTs until near expiry.
- Login flow: `GET /api/login/timestamp` → sign `accountid + timestamp_iso` (Ed25519) → `POST /api/login`.

## See also

- `IMPLEMENTATION_PLAN.md` — phased validation and hardening checklist
- `docs/openclaw.sample.json` — full config with protected tools allowlisted
