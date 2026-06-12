#!/usr/bin/env bash
# Patch identyclaw-webhooks: resolve outbound peers from identyclaw-a2a (fallback: legacy a2a).
set -euo pipefail

target="${1:?usage: patch-webhooks-a2a-config-key.sh <path-to-send-rodit-webhook.js-or-index.js>}"
[[ -f "$target" ]] || exit 0

if grep -q 'function a2aOutboundConfig' "$target" 2>/dev/null; then
  exit 0
fi

python3 - "$target" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_resolve = """function resolveOutboundPeerBase(config, peerId) {
  const peer = config.plugins?.entries?.a2a?.config?.outbound?.agents?.[peerId];
  const cardUrl = peer?.url?.trim();
  const loginBase = peer?.loginBaseUrl?.trim();
  if (cardUrl) return agentCardUrlToBase(cardUrl);
  if (loginBase) return loginBase.replace(/\\/$/, "");
  const known = Object.keys(config.plugins?.entries?.a2a?.config?.outbound?.agents ?? {});
  throw new Error(
    `Peer '${peerId}' not found in plugins.entries.a2a.config.outbound.agents` + (known.length ? ` (configured: ${known.join(", ")})` : "")
  );
}"""

new_resolve = """function a2aOutboundConfig(config) {
  const entries = config.plugins?.entries ?? {};
  const pluginKey = entries["identyclaw-a2a"] ? "identyclaw-a2a" : "a2a";
  return entries[pluginKey]?.config?.outbound;
}
function resolveOutboundPeerBase(config, peerId) {
  const outbound = a2aOutboundConfig(config);
  const peer = outbound?.agents?.[peerId];
  const cardUrl = peer?.url?.trim();
  const loginBase = peer?.loginBaseUrl?.trim();
  if (cardUrl) return agentCardUrlToBase(cardUrl);
  if (loginBase) return loginBase.replace(/\\/$/, "");
  const known = Object.keys(outbound?.agents ?? {});
  throw new Error(
    `Peer '${peerId}' not found in plugins.entries.(identyclaw-a2a|a2a).config.outbound.agents` + (known.length ? ` (configured: ${known.join(", ")})` : "")
  );
}"""

old_tls = """function outboundTlsSkipVerify(config) {
  return config.plugins?.entries?.a2a?.config?.outbound?.tlsSkipVerify === true;
}"""

new_tls = """function outboundTlsSkipVerify(config) {
  return a2aOutboundConfig(config)?.tlsSkipVerify === true;
}"""

if old_resolve not in text:
    sys.stderr.write(f"patch-webhooks-a2a-config-key: resolveOutboundPeerBase block not found in {path}\n")
    sys.exit(1)
if old_tls not in text:
    sys.stderr.write(f"patch-webhooks-a2a-config-key: outboundTlsSkipVerify block not found in {path}\n")
    sys.exit(1)

text = text.replace(old_resolve, new_resolve, 1)
text = text.replace(old_tls, new_tls, 1)
text = text.replace(
    "Resolves the peer base URL from plugins.entries.a2a.config.outbound.agents.",
    "Resolves the peer base URL from plugins.entries.identyclaw-a2a.config.outbound.agents (fallback: a2a).",
)

path.write_text(text, encoding="utf-8")
PY
