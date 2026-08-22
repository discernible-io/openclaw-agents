# Browser tool (pod / container deploy)

This gateway runs Chromium **inside the agent container** (host browser). The isolated **sandbox browser** sidecar is **not** enabled here — do not use `target="sandbox"` or `targetId="sandbox"`.

## Correct usage

1. Omit `target` (defaults to host) or set `target="host"`.
2. Open: `action="open"`, `url="https://…"`, optional `label="my-tab"`.
3. Snapshot: use `action="tabs"` first, then `action="snapshot"` with `targetId` from the tab list (e.g. `t1`) or the same `label`.
4. Profile: default managed profile is `openclaw` (cookies under `browser/openclaw/user-data/`).

## If browser times out on first use

Chromium cold-start can take ~30s. Retry `open`, or run inside the container:

`node /app/openclaw.mjs browser doctor`
