#!/usr/bin/env bash
# Constitution helpers and in-container test library copies.
# Sourced from scripts/lib.sh — do not execute directly.

# True when a constitution suite name is listed in CONSTITUTION_SKIP_SUITES (space-separated).
# Suite tokens: a2a, a2a-auth, a2a-messaging, auth-boundaries, webhook, webhook-all, webhook-p2p, mail, mail-hola.
# Legacy: SKIP_MAIL_HOLA=1 also skips mail-hola.
constitution_suite_skipped() {
  local suite="$1" ref
  [[ -n "$suite" ]] || return 1
  load_env
  if [[ "$suite" == mail-hola && "${SKIP_MAIL_HOLA:-0}" == 1 ]]; then
    return 0
  fi
  for ref in ${CONSTITUTION_SKIP_SUITES:-}; do
    [[ "$ref" == "$suite" ]] && return 0
  done
  return 1
}

# True when token_id is listed in A2A_TEST_EXCLUDE_PEERS (still usable for discovery/bootstrap).

# True when token_id is listed in A2A_TEST_EXCLUDE_PEERS (still usable for discovery/bootstrap).
a2a_peer_token_id_excluded_from_tests() {
  local token_id="$1" ref
  [[ -n "$token_id" ]] || return 1
  load_env
  for ref in ${A2A_TEST_EXCLUDE_PEERS:-}; do
    is_passport_token_id "$ref" || continue
    [[ "$ref" == "$token_id" ]] && return 0
  done
  return 1
}

# Passport token_ids for other AGENT_IDS on this host (cross-agent, not self).

# Optional test allowlist: when A2A_TEST_ONLY_PEERS is set, constitution peer
# suites target exactly these Passport token_ids (still deduped/reachability-probed
# and with local-host token_ids skipped). Empty means test all discovered peers.
a2a_test_only_peer_token_ids() {
  local ref out=""
  load_env
  for ref in ${A2A_TEST_ONLY_PEERS:-}; do
    is_passport_token_id "$ref" || continue
    if [[ " $out " != *" $ref "* ]]; then
      out="${out:+$out }$ref"
    fi
  done
  echo "$out"
}

# Constitution / smoke-test peer candidates. Precedence: A2A_TEST_ONLY_PEERS when
# set; else A2A_PEER_AGENTS when it lists valid token_ids (reconciled against GET
# /api/agents so deprecated configured token_ids yield to discovered ones at the
# same gateway); else A2A_PEER_AGENTS + GET /api/agents (merged, deduped). Peer
# gateway URLs and contactUri email are always resolved at run time via GET
# /api/identity/token/{tokenId}/full metadata.webhook_url (+ on-chain fallback)
# when IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1 — independent of this list.

# Constitution / smoke-test peer candidates. Precedence: A2A_TEST_ONLY_PEERS when
# set; else A2A_PEER_AGENTS when it lists valid token_ids (reconciled against GET
# /api/agents so deprecated configured token_ids yield to discovered ones at the
# same gateway); else A2A_PEER_AGENTS + GET /api/agents (merged, deduped). Peer
# gateway URLs and contactUri email are always resolved at run time via GET
# /api/identity/token/{tokenId}/full metadata.webhook_url (+ on-chain fallback)
# when IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1 — independent of this list.
a2a_discovered_test_candidate_token_ids() {
  local only configured local_id
  load_env
  local_id="$(resolve_local_agent_id)"
  only="$(a2a_test_only_peer_token_ids)"
  if [[ -n "$only" ]]; then
    a2a_reconcile_peer_token_id_list "$only" "$local_id"
    return 0
  fi
  configured="$(a2a_configured_peer_token_ids)"
  if [[ -n "$configured" ]]; then
    a2a_reconcile_peer_token_id_list "$configured" "$local_id"
    return 0
  fi
  a2a_merged_remote_peer_token_ids
}

# Process-lifetime cache: start all / restart all exclude every local token_id, so the
# live peer map is identical across AGENT_IDS — avoid N× full GET /api/agents probes.
_IDENTYCLAW_LIVE_API_PEERS_CACHE=""
_IDENTYCLAW_LIVE_API_PEERS_CACHE_KEY=""

# Probe GET /api/agents, resolve /full + chain URLs, keep peers with live agent-card.

# Agents in AGENT_IDS missing secrets/imap.pass (blocks test-mail and email HOLA).
constitution_agents_missing_mail_password() {
  local id out="" dir container
  load_env
  for id in $AGENT_IDS; do
    dir="$(agent_home "$id")"
    if [[ -f "${dir}/secrets/imap.pass" ]]; then
      continue
    fi
    # Pod deploy chowns agent state to the container uid — verify inside a running gateway.
    if [[ "${IDENTYCLAW_DEPLOY_MODE:-}" == "pod" ]] && agent_container_running "$id"; then
      container="$(agent_container "$id")"
      if podman exec "$container" test -f /home/node/.openclaw/secrets/imap.pass 2>/dev/null; then
        continue
      fi
    fi
    out="${out:+$out }${id}"
  done
  echo "$out"
}

# Primary local gateway base (first resolved) — used to detect peers that resolve to our own
# ingress (e.g. an alternate token_id registered to this agent).

# Default peer for smoke tests. Precedence: local cross-agent (same-host webhooks 0.1.5),
# then first remote candidate whose /a2a is auth-gated. Skips A2A_TEST_EXCLUDE_PEERS.
resolve_reachable_peer_token_id() {
  local local_deploy_id="${1:-$(resolve_local_agent_id)}"
  local resolver_config_dir cross
  local p base
  load_env
  resolver_config_dir="$(agent_home "$local_deploy_id")"
  cross="$(resolve_local_cross_agent_peer_token_id "$local_deploy_id" 2>/dev/null || true)"
  if [[ -n "$cross" ]]; then
    echo "$cross"
    return 0
  fi
  for p in $(a2a_discovered_test_candidate_token_ids); do
    is_passport_token_id "$p" || continue
    a2a_peer_token_id_excluded_from_tests "$p" && continue
    a2a_peer_token_id_on_this_host "$p" && continue
    base="$(a2a_peer_public_base_url "$p" "$resolver_config_dir" 2>/dev/null || true)"
    [[ -n "$base" ]] || continue
    if peer_shares_local_gateway_base "$local_deploy_id" "$p"; then
      echo "    (skip peer ${p} — shares gateway with ${local_deploy_id} at ${base%/}; A2A covered by local suites)" >&2
      continue
    fi
    if a2a_probe_endpoint_reachable "$base"; then
      echo "$p"
      return 0
    fi
    echo "    (skip peer ${p} — ${base}/a2a not reachable or not auth-gated)" >&2
  done
  return 1
}

# All live remote peers for constitution suites — one token_id per distinct live gateway
# base URL. "Live" = URL resolved from the registry (API /full metadata.webhook_url, on-chain
# fallback) AND the gateway answers /a2a auth-gated (401/403). Deduped by base because the
# P2P login/auth flow targets the resolved base, so multiple token_ids sharing one gateway
# are the same peer under test (and dead token_ids that resolve to no live host are dropped).
# Peers that share the local agent's gateway remain in the list; A2A suites are skipped per
# peer in cmd_test_constitution_for_agent (webhook/mail may still run).

# All live remote peers for constitution suites — one token_id per distinct live gateway
# base URL. "Live" = URL resolved from the registry (API /full metadata.webhook_url, on-chain
# fallback) AND the gateway answers /a2a auth-gated (401/403). Deduped by base because the
# P2P login/auth flow targets the resolved base, so multiple token_ids sharing one gateway
# are the same peer under test (and dead token_ids that resolve to no live host are dropped).
# Peers that share the local agent's gateway remain in the list; A2A suites are skipped per
# peer in cmd_test_constitution_for_agent (webhook/mail may still run).
resolve_live_peer_token_ids() {
  local local_deploy_id="${1:-$(resolve_local_agent_id)}"
  local resolver_config_dir p base seen_bases="" out="" tid deploy_id
  load_env
  resolver_config_dir="$(agent_home "$local_deploy_id")"
  # Same-host cross-agent peers first — outbound P2P webhooks pass when both run webhooks 0.1.5.
  for tid in $(local_cross_agent_peer_token_ids "$local_deploy_id"); do
    deploy_id="$(find_deploy_id_for_token_id "$tid" 2>/dev/null || true)"
    [[ -n "$deploy_id" ]] || continue
    base="$(agent_container_ingress_base_url "$deploy_id" 2>/dev/null || true)"
    [[ -z "$base" ]] && base="$(agent_a2a_public_base_url "$deploy_id" 2>/dev/null || true)"
    [[ -z "$base" ]] && base="$(agent_ingress_base_url "$deploy_id" 2>/dev/null || true)"
    [[ -n "$base" ]] || continue
    base="${base%/}"
    [[ " $seen_bases " == *" $base "* ]] && continue
    seen_bases="${seen_bases:+$seen_bases }$base"
    out="${out:+$out }$tid"
  done
  for p in $(a2a_discovered_test_candidate_token_ids); do
    is_passport_token_id "$p" || continue
    a2a_peer_token_id_excluded_from_tests "$p" && continue
    a2a_peer_token_id_on_this_host "$p" && continue
    base="$(a2a_peer_public_base_url "$p" "$resolver_config_dir" 2>/dev/null || true)"
    [[ -n "$base" ]] || continue
    base="${base%/}"
    [[ " $seen_bases " == *" $base "* ]] && continue
    if a2a_probe_endpoint_reachable "$base"; then
      seen_bases="${seen_bases:+$seen_bases }$base"
      out="${out:+$out }$p"
    else
      echo "    (skip peer ${p} — ${base}/a2a not reachable or not auth-gated)" >&2
    fi
  done
  [[ -n "$out" ]] || return 1
  echo "$out"
}


print_constitution_agent_preflight() {
  local local_id="$1"
  local config_dir registered own_token expected card_code card_url
  load_env
  is_valid_agent_id "$local_id" || return 1
  config_dir="$(agent_home "$local_id")"
  expected="$(agent_container_ingress_base_url "$local_id" 2>/dev/null || true)"
  [[ -n "$expected" ]] || expected="$(agent_a2a_public_base_url "$local_id" 2>/dev/null || true)"
  [[ -n "$expected" ]] || expected="$(agent_ingress_base_url "$local_id" 2>/dev/null || true)"
  # webhook_url source of truth: IdentyClaw API GET /api/identity/token/{tokenId}/full
  # (metadata.webhook_url), with on-chain RODiT fallback — same resolution the peer path uses.
  # Runs in-container when the host cannot read the mounted NEAR credentials (rootless podman
  # uid mapping), so host filesystem permissions never produce a false "empty webhook_url".
  own_token="$(agent_token_id "$local_id" 2>/dev/null || true)"
  registered=""
  if [[ -n "$own_token" ]]; then
    registered="$(probe_identyclaw_peer_public_base_url "$config_dir" "$own_token" 2>/dev/null || true)"
  fi
  registered="${registered%/}"
  expected="${expected%/}"

  echo "==> Preflight (${local_id})"
  if [[ -z "$own_token" ]]; then
    echo "    webhook_url: not-passed — cannot resolve own Passport token_id (need readable NEAR creds or a running container)"
  elif [[ -z "$registered" ]]; then
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "    webhook_url: not-passed — API /full + on-chain have no metadata.webhook_url for token_id=${own_token}"
    else
      echo "    webhook_url: skipped — token_id=${own_token} (set IDENTYCLAW_A2A_DYNAMIC_PEERS_FROM_JWT=1 to resolve via API /full)"
    fi
  elif [[ "$registered" == "$expected" ]]; then
    echo "    webhook_url: passed — ${registered} (API /full token_id=${own_token})"
  else
    echo "    webhook_url: not-passed — registered=${registered} agent ingress=${expected} (API /full token_id=${own_token})"
  fi

  if [[ -n "$expected" ]]; then
    card_url="${expected}/.well-known/agent-card.json"
    card_code="$(a2a_probe_agent_card_status "$expected" 2>/dev/null || echo "000")"
    if [[ "$card_code" == "200" ]]; then
      echo "    agent-card:  passed — HTTP ${card_code} ${card_url}"
    else
      echo "    agent-card:  not-passed — HTTP ${card_code} ${card_url}"
    fi
    if a2a_probe_endpoint_reachable "$expected"; then
      echo "    POST /a2a:   passed — auth-gated (401/403 without JWT)"
    else
      echo "    POST /a2a:   not-passed — not auth-gated or unreachable ${expected}/a2a"
    fi
  else
    echo "    agent-card:  skipped — no ingress base URL resolved"
  fi

  local container desired_ver installed_ver
  container="$(agent_container "$local_id" 2>/dev/null || true)"
  desired_ver="$(clawhub_plugin_pinned_version "${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN}")"
  installed_ver="$(webhooks_plugin_installed_version "$config_dir" "$container")"
  if ! agent_has_near_credentials "$config_dir"; then
    echo "    webhooks:    skipped — no NEAR credentials (plugin not installed)"
  elif [[ -z "$installed_ver" ]]; then
    echo "    webhooks:    not-passed — identyclaw-webhooks not installed — run ./identyclaw.sh upgrade-plugins ${local_id}"
  elif [[ -n "$desired_ver" && "$installed_ver" != "$desired_ver" ]]; then
    echo "    webhooks:    not-passed — installed=${installed_ver} pinned=${desired_ver} — run ./identyclaw.sh upgrade-plugins ${local_id}"
  else
    echo "    webhooks:    passed — identyclaw-webhooks@${installed_ver} (P2P/API signed ingress; no self-webhook probe)"
  fi
  echo ""
}

# Constitution cross-agent test mode from resolved peer capabilities.
# a2a+email — remote A2A + email HOLA; a2a — A2A/webhooks only; email only — HOLA without A2A base.

# Constitution cross-agent test mode from resolved peer capabilities.
# a2a+email — remote A2A + email HOLA; a2a — A2A/webhooks only; email only — HOLA without A2A base.
classify_constitution_test_mode() {
  local a2a_base="$1" peer_email="$2" local_email="$3"
  local has_a2a=0 has_email=0
  [[ -n "$a2a_base" ]] && has_a2a=1
  [[ -n "$peer_email" && -n "$local_email" && "${SKIP_MAIL_HOLA:-0}" != 1 ]] && has_email=1
  if [[ $has_a2a -eq 1 && $has_email -eq 1 ]]; then
    echo "a2a+email"
  elif [[ $has_a2a -eq 1 ]]; then
    echo "a2a"
  elif [[ $has_email -eq 1 ]]; then
    echo "email only"
  else
    echo "unavailable"
  fi
}

# Probe remote peer A2A base + Passport contactUri email (host paths or running container).

# Probe remote peer A2A base + Passport contactUri email (host paths or running container).
probe_test_candidate_peer_json() {
  local local_id="$1" peer_token_id="$2"
  local config_dir cred ext_dir container probed_json a2a_base
  [[ -n "$local_id" && -n "$peer_token_id" ]] || return 1
  is_passport_token_id "$peer_token_id" || return 1
  config_dir="$(agent_home "$local_id")"
  a2a_base="$(a2a_peer_public_base_url "$peer_token_id" "$config_dir" 2>/dev/null || true)"
  cred="$(agent_near_credentials_host_path "$local_id" 2>/dev/null || true)"
  ext_dir="$(agent_a2a_ext_dir "$config_dir" 2>/dev/null || true)"
  if [[ -z "$cred" || ! -d "$ext_dir" ]]; then
    container="$(agent_container "$local_id")"
    if podman ps --format '{{.Names}}' | grep -qx "$container"; then
      cred="$(agent_near_credentials_in_container "$local_id" 2>/dev/null || true)"
      ext_dir="$(a2a_api_probe_ext_dir_container "$container" 2>/dev/null || true)"
      if [[ -n "$cred" && -n "$ext_dir" ]]; then
        podman_cp_lib_rodit_env "$container" || return 1
        podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-identity.mjs" \
          "$container:/tmp/lib-peer-identity.mjs" >/dev/null 2>&1 || return 1
        podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-gateway-url.mjs" \
          "$container:/tmp/lib-peer-gateway-url.mjs" >/dev/null 2>&1 || return 1
        podman cp "${IDENTYCLAW_ROOT}/scripts/probe-test-candidate-peer.mjs" \
          "$container:/tmp/probe-test-candidate-peer.mjs" >/dev/null 2>&1 || return 1
        local -a probe_args=(node /tmp/probe-test-candidate-peer.mjs "$ext_dir" "$cred" "$peer_token_id")
        [[ -n "$a2a_base" ]] && probe_args+=(--a2a-base "$a2a_base")
        probed_json="$(
          timeout --foreground "${IDENTYCLAW_PROBE_TIMEOUT_SEC:-90}" \
            podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" \
            "${probe_args[@]}" 2>/dev/null || true
        )"
      fi
    fi
  else
    local -a probe_args=(
      node "${IDENTYCLAW_ROOT}/scripts/probe-test-candidate-peer.mjs"
      "$ext_dir" "$cred" "$peer_token_id"
    )
    [[ -n "$a2a_base" ]] && probe_args+=(--a2a-base "$a2a_base")
    probed_json="$(
      timeout "${IDENTYCLAW_PROBE_TIMEOUT_SEC:-90}" "${probe_args[@]}" 2>/dev/null || true
    )"
  fi
  [[ -n "$probed_json" ]] || return 1
  printf '%s' "$probed_json"
}

# curl --resolve for local HTTPS ingress (host + in-container probes; pod nginx on loopback).

# Probe/test .mjs scripts import ./lib-rodit-env.mjs — copy beside them at /tmp in containers.
podman_cp_lib_rodit_env() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-env.mjs" \
    "$container:/tmp/lib-rodit-env.mjs" >/dev/null 2>&1 || return 1
}

# Constitution test reporters import ./lib-test-report.mjs beside /tmp/*.mjs runners.

# Constitution test reporters import ./lib-test-report.mjs beside /tmp/*.mjs runners.
podman_cp_lib_test_report() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-test-report.mjs" \
    "$container:/tmp/lib-test-report.mjs" >/dev/null 2>&1 || return 1
}

# Shared mail HOLA libs (responder + probe) beside /tmp/*.mjs runners.

# Shared mail HOLA libs (responder + probe) beside /tmp/*.mjs runners.
podman_cp_mail_responder_libs() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman_cp_lib_rodit_env "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-hola.mjs" "$container:/tmp/lib-hola.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-identity.mjs" "$container:/tmp/lib-peer-identity.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-himalaya-mail.mjs" "$container:/tmp/lib-himalaya-mail.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-mail-responder.mjs" "$container:/tmp/lib-mail-responder.mjs" >/dev/null 2>&1 || return 1
}


podman_cp_a2a_webhook_smoke_libs() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman_cp_a2a_hola_smoke_libs "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-a2a-webhook-smoke-responder.mjs" \
    "$container:/tmp/lib-a2a-webhook-smoke-responder.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/send-rodit-webhook.mjs" \
    "$container:/tmp/send-rodit-webhook.mjs" >/dev/null 2>&1 || return 1
}


podman_cp_a2a_hola_smoke_libs() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman_cp_mail_responder_libs "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-a2a-hola-smoke-responder.mjs" \
    "$container:/tmp/lib-a2a-hola-smoke-responder.mjs" >/dev/null 2>&1 || return 1
}

# Email HOLA peer probe copies shared libs beside /tmp/test-mail-hola-peer.mjs.
# Includes the responder (inbound direction) and webhook lib (P2P login to drive peer).

# Email HOLA peer probe copies shared libs beside /tmp/test-mail-hola-peer.mjs.
# Includes the responder (inbound direction) and webhook lib (P2P login to drive peer).
podman_cp_mail_hola_test_libs() {
  local container="$1"
  [[ -n "$container" ]] || return 1
  podman_cp_mail_responder_libs "$container" || return 1
  podman_cp_lib_test_report "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-peer-gateway-url.mjs" \
    "$container:/tmp/lib-peer-gateway-url.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-discover-agents.mjs" \
    "$container:/tmp/lib-discover-agents.mjs" >/dev/null 2>&1 || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null 2>&1 || return 1
}

# Chat prompt: discover remote peers via API and exercise A2A + email cross-agent tests.
agent_chat_peer_discovery_test_prompt() {
  local id="$1"
  local self_token email api_base local_tokens
  load_env
  self_token="$(agent_token_id "$id" 2>/dev/null || true)"
  email="$(agent_env_value "$id" EMAIL "")"
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] || api_base="$(identyclaw_api_base_url_for_agent "$id" 2>/dev/null || true)"
  api_base="${api_base:-https://api.identyclaw.com}"
  local_tokens="$(local_host_agent_token_ids)"
  cat <<EOF
Run an IdentyClaw cross-agent peer discovery and test report. Use your tools only — do not invent token_ids or URLs.

Context:
- You are deployment ${id} (Passport token_id: ${self_token:-unknown}, email: ${email:-none})
- IdentyClaw API base: ${api_base}
- Local agents on THIS host (never use as cross-agent test targets): ${AGENT_IDS}
- Local Passport token_ids to exclude: ${local_tokens:-none}

Steps:
1. identyclaw_list_agents — list public agents (GET /api/agents; token_ids only)
2. Exclude your token_id and every local-host token_id above
3. Pick up to 3 remote candidates. For each, identyclaw_get_agent_identity (authenticated GET /full) and record metadata.webhook_url and contactUri email
4. Classify each: a2a+email (both), a2a (webhook_url only), or email only (email, no webhook_url)
5. Best a2a candidate: a2a_send_message with a one-line test ping; report task_id/context_id or error
6. Best email candidate (or same if a2a+email): identyclaw_create_hola then send via himalaya to peer contactUri with HOLA in body; report outcome
7. Final summary table: token_id | mode | webhook_url | peer_email | a2a result | email result

If no remote candidates remain after exclusions, say so and stop.
EOF
}

# Map token_id → local deployment slug when this host runs that Passport (AGENT_IDS / agents/).
