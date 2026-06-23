#!/usr/bin/env bash
# Patch A2A plugin: open P2P — register outbound peers from inbound JWT rodit_webhookurl.
set -euo pipefail

ext_dir="${1:?usage: patch-a2a-dynamic-peers.sh <plugin-ext-dir>}"
[[ -d "$ext_dir/dist" ]] || exit 0

IDENTYCLAW_ROOT="${IDENTYCLAW_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
registry_src="${IDENTYCLAW_ROOT}/scripts/a2a-dynamic-peer-registry.js"
registry_dst="${ext_dir}/dist/auth/a2a-dynamic-peer-registry.js"
if [[ -f "$registry_src" ]]; then
  mkdir -p "$(dirname "$registry_dst")"
  cp "$registry_src" "$registry_dst"
fi

python3 - "$ext_dir" <<'PY'
import json
import sys
from pathlib import Path

ext = Path(sys.argv[1])
manifest = ext / "openclaw.plugin.json"
if manifest.is_file():
    data = json.loads(manifest.read_text(encoding="utf-8"))
    outbound = data.get("configSchema", {}).get("properties", {}).get("outbound", {})
    props = outbound.get("properties", {})
    if "dynamicPeersFromJwt" not in props:
        props["dynamicPeersFromJwt"] = {
            "type": "boolean",
            "description": "Register outbound peers dynamically from inbound JWT rodit_webhookurl",
        }
        manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

ext = Path(sys.argv[1])
inbound = ext / "dist/auth/rodit-inbound.js"
auth = ext / "dist/auth/authenticate-inbound.js"
index = ext / "dist/index.js"

for path in (inbound, auth, index):
    if not path.is_file():
        sys.exit(0)

# --- rodit-inbound.js: expose webhook payload on success ---
in_text = inbound.read_text(encoding="utf-8")
if "webhookPayload" not in in_text:
    old_return = "        return { ok: true, label };"
    new_return = """        return {
            ok: true,
            label,
            webhookPayload: result.payload,
        };"""
    if old_return not in in_text:
        sys.stderr.write(f"patch-a2a-dynamic-peers: success return not found in {inbound}\n")
        sys.exit(0)
    inbound.write_text(in_text.replace(old_return, new_return, 1), encoding="utf-8")

# --- authenticate-inbound.js: call registry after rodit success ---
auth_text = auth.read_text(encoding="utf-8")
if "registerDynamicPeerFromInbound" not in auth_text:
    import_line = 'import { registerDynamicPeerFromInbound } from "./a2a-dynamic-peer-registry.js";\n'
    if import_line.strip() not in auth_text:
        auth_text = import_line + auth_text

    old_ok = """        if (roditResult.ok) {
            return { ok: true, identity: roditResult.label };
        }"""
    new_ok = """        if (roditResult.ok) {
            registerDynamicPeerFromInbound(roditResult);
            return { ok: true, identity: roditResult.label };
        }"""
    if old_ok not in auth_text:
        sys.stderr.write(f"patch-a2a-dynamic-peers: rodit ok block not found in {auth}\n")
        sys.exit(0)
    auth.write_text(auth_text.replace(old_ok, new_ok, 1), encoding="utf-8")

# --- index.js: register outbound tools when dynamicPeersFromJwt even with 0 static peers ---
idx_text = index.read_text(encoding="utf-8")
if "dynamicPeersFromJwt" not in idx_text:
    old_block = """        const configuredOutboundAgentCount = outbound?.agents
            ? Object.keys(outbound.agents).length
            : 0;
        if (outbound?.agents && configuredOutboundAgentCount > 0) {"""
    new_block = """        const configuredOutboundAgentCount = outbound?.agents
            ? Object.keys(outbound.agents).length
            : 0;
        const dynamicPeersFromJwt = outbound?.dynamicPeersFromJwt === true;
        const outboundAgentsConfig = outbound?.agents ?? (dynamicPeersFromJwt ? {} : undefined);
        const shouldRegisterOutbound = outbound?.auth?.provider === "rodit"
            && outboundAgentsConfig !== undefined
            && (configuredOutboundAgentCount > 0 || dynamicPeersFromJwt);
        if (shouldRegisterOutbound) {"""
    if old_block not in idx_text:
        # Newer IDC layout may already differ; try alternate pattern with logWarn.
        alt_old = """        const configuredOutboundAgentCount = outbound?.agents
            ? Object.keys(outbound.agents).length
            : 0;
        if (outbound?.agents && configuredOutboundAgentCount > 0) {
            if (outbound.auth?.provider === "rodit") {
                const authMode = outbound.auth.mode ?? "mediated";
                api.logger.info(`[a2a] Outbound auth enabled with RODiT JWT login (mode=${authMode})`);
            }"""
        if alt_old in idx_text:
            alt_new = """        const configuredOutboundAgentCount = outbound?.agents
            ? Object.keys(outbound.agents).length
            : 0;
        const dynamicPeersFromJwt = outbound?.dynamicPeersFromJwt === true;
        const outboundAgentsConfig = outbound?.agents ?? (dynamicPeersFromJwt ? {} : undefined);
        const shouldRegisterOutbound = outbound?.auth?.provider === "rodit"
            && outboundAgentsConfig !== undefined
            && (configuredOutboundAgentCount > 0 || dynamicPeersFromJwt);
        if (shouldRegisterOutbound) {
            if (outbound.auth?.provider === "rodit") {
                const authMode = outbound.auth.mode ?? "mediated";
                api.logger.info(`[a2a] Outbound auth enabled with RODiT JWT login (mode=${authMode})`);
            }"""
            idx_text = idx_text.replace(alt_old, alt_new, 1)
            old_agents_arg = "                agents: outbound.agents,"
            if old_agents_arg in idx_text:
                idx_text = idx_text.replace(old_agents_arg, "                agents: outboundAgentsConfig,", 1)
        else:
            sys.stderr.write(f"patch-a2a-dynamic-peers: outbound block not found in {index}\n")
            sys.exit(0)
    else:
        idx_text = idx_text.replace(old_block, new_block, 1)
        old_agents_arg = "                agents: outbound.agents,"
        if old_agents_arg in idx_text:
            idx_text = idx_text.replace(old_agents_arg, "                agents: outboundAgentsConfig,", 1)

    # Wire dynamic peer registrar after outboundAgents is assigned.
    registrar_hook = """            outboundAgents = outboundTools.agents;
            if (dynamicPeersFromJwt && outboundAgents) {
                void import("./auth/a2a-dynamic-peer-registry.js").then(({ setDynamicPeerRegistrar }) => {
                    setDynamicPeerRegistrar(async (peerId, baseUrl) => {
                        const cardUrl = `${String(baseUrl).replace(/\\/$/, "")}/.well-known/agent-card.json`;
                        await outboundAgents.addAgent(peerId, cardUrl);
                        api.logger.info(`[a2a] Registered dynamic outbound peer ${peerId} from inbound JWT (baseUrl=${baseUrl})`);
                    });
                });
            }"""
    needle = "            outboundAgents = outboundTools.agents;"
    if needle in idx_text and "setDynamicPeerRegistrar" not in idx_text:
        idx_text = idx_text.replace(needle, registrar_hook, 1)

    index.write_text(idx_text, encoding="utf-8")

# --- rodit-login-routes.js: log successful inbound P2P login for env.local harvest ---
login_routes = ext / "dist/inbound/rodit-login-routes.js"
if login_routes.is_file():
    lr_text = login_routes.read_text(encoding="utf-8")
    if "Inbound P2P login accepted" not in lr_text:
        old_login = """                await client.login_client(expressReq, wrapExpressLikeResponse(res));
            }
            catch (error) {"""
        new_login = """                await client.login_client(expressReq, wrapExpressLikeResponse(res));
                if (res.statusCode === 200) {
                    const user = bodyResult.body?.user ?? bodyResult.body?.data?.user ?? bodyResult.body;
                    const tokenCandidates = [
                        user?.token_id,
                        user?.peerTokenId,
                        user?.rodit_id,
                        bodyResult.body?.token_id,
                        bodyResult.body?.data?.token_id,
                    ];
                    const webhookCandidates = [
                        user?.rodit_webhookurl,
                        user?.rodit_webhook_url,
                        user?.webhook_url,
                    ];
                    let tokenId = "";
                    for (const candidate of tokenCandidates) {
                        const text = String(candidate ?? "").trim();
                        if (/^[A-Za-z][A-Za-z0-9]{11}$/.test(text)) {
                            tokenId = text;
                            break;
                        }
                    }
                    let baseUrl = "";
                    for (const candidate of webhookCandidates) {
                        const raw = String(candidate ?? "").trim().replace(/\\/+$/, "");
                        if (!raw) {
                            continue;
                        }
                        try {
                            const parsed = new URL(raw.includes("://") ? raw : `https://${raw}`);
                            baseUrl = `${parsed.protocol}//${parsed.host}`;
                            break;
                        }
                        catch {
                            baseUrl = raw;
                            break;
                        }
                    }
                    if (tokenId) {
                        const suffix = baseUrl ? ` baseUrl=${baseUrl}` : "";
                        console.log(`[plugins] [a2a] Inbound P2P login accepted token_id=${tokenId}${suffix}`);
                    }
                }
            }
            catch (error) {"""
        if old_login in lr_text:
            login_routes.write_text(lr_text.replace(old_login, new_login, 1), encoding="utf-8")
        else:
            sys.stderr.write(f"patch-a2a-dynamic-peers: login_client block not found in {login_routes}\n")
PY
