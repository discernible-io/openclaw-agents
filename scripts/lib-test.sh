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

# Constitution CLI orchestration (sourced via lib.sh; identyclaw.sh main() keeps the case).

cmd_test_mail() {
  local id="${1:-}"
  load_env
  id="${id:-$(resolve_local_agent_id)}"
  require_podman
  require_agent_running "$id"
  podman exec "$(agent_container "$id")" himalaya --version
  podman exec "$(agent_container "$id")" himalaya folder list
  podman exec "$(agent_container "$id")" himalaya envelope list --folder INBOX
}


cmd_test_mail_hola() {
  local id="" peer_token_id="" container creds ext_dir mailbox email display_name failed=0
  load_env
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    id="$1"
    shift
  fi
  if [[ -n "${1:-}" ]] && is_passport_token_id "$1"; then
    peer_token_id="$1"
  fi
  id="${id:-$(resolve_local_agent_id)}"
  if [[ -z "$peer_token_id" ]]; then
    peer_token_id="$(resolve_peer_token_id "$id" 2>/dev/null || true)"
  fi
  require_podman
  require_agent_running "$id"
  [[ -n "$peer_token_id" ]] || {
    echo "No peer token_id in A2A_PEER_AGENTS (need a peer for email HOLA probe)" >&2
    return 1
  }
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials in ${id} container (secrets/near-credentials/*.json)" >&2
    return 1
  }
  mailbox="$(agent_mailbox "$id")"
  email="${mailbox%%|*}"
  display_name="${mailbox#*|}"
  [[ -n "$email" ]] || {
    echo "No AGENT_*_EMAIL for ${id} in env.local" >&2
    return 1
  }
  container="$(agent_container "$id")"
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_mail_hola_test_libs "$container" || {
    echo "Failed to copy mail HOLA test libs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-mail-hola-peer.mjs" "$container:/tmp/test-mail-hola-peer.mjs" >/dev/null

  echo "==> Email HOLA peer probe (local=${id} → peer token_id=${peer_token_id})"
  echo "    from=${email}"
  if a2a_peer_token_id_on_this_host "$peer_token_id"; then
    echo "    hint: enable ./identyclaw.sh respond-mail on peer agent for INBOX reply checks"
  fi
  local -a hola_args=(
    --ext-dir "$ext_dir"
    --creds "$creds"
    --peer-token-id "$peer_token_id"
    --from-email "$email"
    --from-name "$display_name"
  )
  local api_base poll_sec peer_base
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] && hola_args+=(--api-base "$api_base")
  poll_sec="${MAIL_HOLA_POLL_SECONDS:-180}"
  hola_args+=(--poll-seconds "$poll_sec")
  # Peer A2A gateway lets us drive the reciprocal inbound probe (peer → us).
  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
  local hola_inbound=0
  if [[ -n "$peer_base" ]]; then
    if a2a_peer_token_id_on_this_host "$peer_token_id"; then
      hola_inbound=1
      echo "    inbound reciprocal: same-host peer — deterministic A2A HOLA smoke responder signs with peer NEAR key"
    elif ! peer_mail_hola_ambiguous "$id" "$peer_token_id"; then
      hola_inbound=1
    else
      echo "    skip inbound reciprocal (peer gateway shares this host's pod ingress; peerTokenId binding is ambiguous)"
    fi
  fi
  if [[ $hola_inbound -eq 1 ]]; then
    hola_args+=(--peer-base "$peer_base")
  else
    hola_args+=(--skip-inbound)
  fi
  [[ "${REQUIRE_MAIL_HOLA:-0}" == 1 ]] && hola_args+=(--require)

  local hola_smoke_pids=() smoke_id=""
  if [[ $hola_inbound -eq 1 ]]; then
    for smoke_id in $AGENT_IDS; do
      if agent_container_running "$smoke_id"; then
        echo "    Inbound: polling ${smoke_id} A2A HOLA smoke responder during reciprocal test"
        (
          while true; do
            respond_a2a_hola_smoke_one "$smoke_id" >/dev/null 2>&1 || true
            sleep "${MAIL_HOLA_SMOKE_POLL_SEC:-2}"
          done
        ) &
        hola_smoke_pids+=("$!")
      fi
    done
  fi

  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 -e "REQUIRE_MAIL_HOLA=${REQUIRE_MAIL_HOLA:-0}" \
    "$container" node /tmp/test-mail-hola-peer.mjs \
    "${hola_args[@]}" || failed=1

  if [[ ${#hola_smoke_pids[@]} -gt 0 ]]; then
    local pid
    for pid in "${hola_smoke_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    for smoke_id in $AGENT_IDS; do
      respond_a2a_hola_smoke_one "$smoke_id" >/dev/null 2>&1 || true
    done
  fi

  return "$failed"
}


a2a_fetch_agent_card() {
  local runner_id="$1" target_id="$2"
  local url container resolve=() curl_flags=(-sk) card_json schema_rc=0
  url="$(agent_agent_card_url "$target_id")"
  if agent_is_local "$runner_id" && agent_container_running "$runner_id"; then
    container="$(agent_container "$runner_id")"
    if agent_is_local "$target_id"; then
      mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
    fi
    card_json="$(podman exec "$container" curl "${curl_flags[@]}" "${resolve[@]}" "$url")"
  else
    mapfile -t resolve < <(agent_ingress_curl_resolve_args "$target_id")
    card_json="$(curl -sk "${resolve[@]}" "$url")"
  fi
  echo "$card_json"
  if [[ -f "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" ]]; then
    echo "$card_json" | node "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" --label "${target_id}" || schema_rc=$?
    return "$schema_rc"
  fi
  return 0
}


a2a_fetch_peer_agent_card() {
  local runner_id="$1" peer_token_id="$2"
  local url container curl_flags=(-sk) resolver_dir card_json schema_rc=0
  resolver_dir="$(agent_home "$runner_id")"
  url="$(a2a_peer_agent_card_url "$peer_token_id" "$resolver_dir")"
  [[ -n "$url" ]] || {
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "No agent card URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed (check IDENTYCLAW_BASE_URL, NEAR creds, passport)" >&2
    else
      echo "No agent card URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
    fi
    return 1
  }
  if agent_container_running "$runner_id"; then
    container="$(agent_container "$runner_id")"
    card_json="$(podman exec "$container" curl "${curl_flags[@]}" "$url")"
  else
    card_json="$(curl -sk "$url")"
  fi
  echo "$card_json"
  if [[ -f "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" ]]; then
    echo "$card_json" | node "${IDENTYCLAW_ROOT}/scripts/probe-agent-card-schema.mjs" --label "peer:${peer_token_id}" || schema_rc=$?
    return "$schema_rc"
  fi
  return 0
}


a2a_probe_unauth_post_url() {
  local label="$1" a2a_url="$2"
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$a2a_url" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"tasks/get","params":{"id":"smoke"}}')"
  if [[ "$code" != "401" ]]; then
    echo "not-passed  POST /a2a without Authorization on ${label} — HTTP ${code} (stack requires 401) (${a2a_url})" >&2
    return 1
  fi
  echo "passed  POST /a2a without Authorization on ${label} — HTTP 401"
}


a2a_probe_unauth_post() {
  local id="$1"
  local code a2a_url resolve=()
  a2a_url="$(agent_a2a_endpoint_url "$id")"
  mapfile -t resolve < <(agent_ingress_curl_resolve_args "$id")
  code="$(curl -sk "${resolve[@]}" -o /dev/null -w '%{http_code}' -X POST "$a2a_url" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":"1","method":"tasks/get","params":{"id":"smoke"}}')"
  if [[ "$code" != "401" ]]; then
    echo "not-passed  POST /a2a without Authorization on ${id} — HTTP ${code} (stack requires 401) (${a2a_url})" >&2
    return 1
  fi
  echo "passed  POST /a2a without Authorization on ${id} — HTTP 401"
}


cmd_test_a2a() {
  local from_id peer_token_id self_token_id failed=0
  require_podman
  load_env
  from_id="${1:-$(resolve_local_agent_id)}"
  peer_token_id="${2:-}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  elif [[ -z "$peer_token_id" && "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    peer_token_id="$(resolve_peer_token_id "$from_id" 2>/dev/null || true)"
  fi
  require_agent_running "$from_id"
  self_token_id="$(agent_token_id "$from_id")"

  echo "==> A2A smoke (local=${from_id}, self token_id=${self_token_id:-unknown})"

  if [[ -n "$peer_token_id" ]]; then
    is_passport_token_id "$peer_token_id" || {
      echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
      exit 1
    }
    local peer_resolver_dir peer_base
    peer_resolver_dir="$(agent_home "$from_id")"
    echo "==> Discovery: peer token_id=${peer_token_id}"
    peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$peer_resolver_dir" 2>/dev/null || true)"
    if [[ -n "$peer_base" ]]; then
      if a2a_peer_public_base_url_from_env_map "$peer_token_id" >/dev/null 2>&1; then
        echo "    base=${peer_base} (A2A_PEER_URLS)"
      else
        echo "    base=${peer_base} (API /full metadata.webhook_url / registry / chain fallback)"
      fi
    elif a2a_resolve_peers_by_token_id_enabled; then
      echo "    (API /full and on-chain metadata.webhook_url lookup failed — check IDENTYCLAW_BASE_URL, NEAR creds, passport)" >&2
    fi
    a2a_fetch_peer_agent_card "$from_id" "$peer_token_id" || failed=1
    echo ""
  else
    echo "==> Skip peer discovery (no A2A_PEER_AGENTS / IDENTYCLAW_PEER_TOKEN_ID)"
    echo ""
  fi

  if [[ "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    echo "==> Discovery: local ${from_id}"
    a2a_fetch_agent_card "$from_id" "$from_id" || failed=1
    echo ""

    echo "==> Inbound auth probe: POST /a2a without Authorization"
    a2a_probe_unauth_post "$from_id" || failed=1
  fi
  if [[ -n "$peer_token_id" ]]; then
    local peer_a2a_url peer_resolver_dir
    peer_resolver_dir="$(agent_home "$from_id")"
    peer_a2a_url="$(a2a_peer_a2a_endpoint_url "$peer_token_id" "$peer_resolver_dir")"
    [[ -n "$peer_a2a_url" ]] && a2a_probe_unauth_post_url "peer:${peer_token_id}" "$peer_a2a_url" || failed=1
  fi

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "A2A smoke: passed (discovery + inbound auth probe)."
  else
    echo "A2A smoke: not-passed (see output above)." >&2
    return 1
  fi
  if [[ -n "$peer_token_id" ]]; then
    echo "For end-to-end RODiT messaging, run:"
    echo "  $0 test-a2a-messaging ${from_id} ${peer_token_id}"
  fi
}


cmd_test_a2a_auth() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local target container creds ext_dir failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  else
    peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  fi
  require_agent_running "$local_id"

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || {
    echo "Failed to copy lib-rodit-env.mjs into ${container}" >&2
    return 1
  }
  podman_cp_lib_test_report "$container" || {
    echo "Failed to copy lib-test-report.mjs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-a2a-rodit-auth.mjs" "$container:/tmp/test-a2a-rodit-auth.mjs" >/dev/null

  if [[ -n "$peer_token_id" ]]; then
    target="$(a2a_peer_public_base_url_with_retry "$peer_token_id" "$(agent_home "$local_id")")"
    [[ -n "$target" ]] || {
      if a2a_resolve_peers_by_token_id_enabled; then
        echo "No URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed" >&2
      else
        echo "No URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
      fi
      return 1
    }
    echo "==> A2A RODiT auth (→ peer token_id=${peer_token_id} at ${target})"
    echo "    P2P login at peer /api/login, then POST /a2a"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-rodit-auth.mjs \
      --ext-dir "$ext_dir" --creds "$creds" --target "$target" || failed=1
    echo ""
  fi

  if [[ "${CONSTITUTION_PEER_ONLY:-0}" != 1 ]]; then
    target="$(agent_a2a_public_base_url "$local_id")"
    [[ -n "$target" ]] || target="$(agent_ingress_base_url "$local_id")"
    [[ -n "$target" ]] || {
      echo "No ingress URL for local ${local_id}" >&2
      return 1
    }
    echo "==> A2A RODiT auth (→ local ${local_id} at ${target})"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-rodit-auth.mjs \
      --ext-dir "$ext_dir" --creds "$creds" --target "$target" || failed=1
  fi

  return "$failed"
}


cmd_test_auth_boundaries() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local target peer_target container creds ext_dir failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  if [[ "${CONSTITUTION_LOCAL_ONLY:-0}" == 1 ]]; then
    peer_token_id=""
  else
    peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  fi
  require_agent_running "$local_id"

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || {
    echo "Failed to copy lib-rodit-env.mjs into ${container}" >&2
    return 1
  }
  podman_cp_lib_test_report "$container" || {
    echo "Failed to copy lib-test-report.mjs into ${container}" >&2
    return 1
  }
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-inter-agent-auth-boundaries.mjs" \
    "$container:/tmp/test-inter-agent-auth-boundaries.mjs" >/dev/null

  target="$(agent_a2a_public_base_url "$local_id")"
  [[ -n "$target" ]] || target="$(agent_ingress_base_url "$local_id")"
  [[ -n "$target" ]] || {
    echo "No ingress URL for local ${local_id}" >&2
    return 1
  }

  peer_target=""
  if [[ -n "$peer_token_id" ]]; then
    peer_target="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$local_id")")"
  fi

  echo "==> Inter-agent auth boundaries (channel isolation + mutual P2P binding)"
  echo "    local=${target}${peer_target:+, peer=${peer_target}}"
  local -a boundary_args=(
    --ext-dir "$ext_dir"
    --creds "$creds"
    --local "$target"
  )
  if [[ -n "$peer_target" ]]; then
    boundary_args+=(--peer "$peer_target")
  fi
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-inter-agent-auth-boundaries.mjs \
    "${boundary_args[@]}" || failed=1
  return "$failed"
}


cmd_webhook_url() {
  local id="${1:?Usage: $0 webhook-url agent-b [hooks/wake|hooks/agent|hooks/name]}"
  local path="${2:-hooks/wake}"
  agent_webhook_url "$id" "$path"
}


cmd_test_webhook() {
  local id="${1:-}" failed=0
  load_env
  id="${id:-$(resolve_local_agent_id)}"
  local url code creds container
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
    return 0
  fi
  url="$(agent_webhook_url "$id" hooks/wake)"
  container="$(agent_container "$id")"
  if ! constitution_suite_skipped webhook; then
    echo "==> Webhook ingress probe: POST /hooks/wake without RODiT signature"
    echo "    POST ${url}"
    echo "    Senders sign at origin via @rodit/rodit-auth-be: x-signature + x-timestamp (see clienttest-idc)"
    code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$url" \
      -H 'Content-Type: application/json' \
      -d '{"text":"identyclaw smoke"}')"
    case "$code" in
      400|401) echo "passed  POST /hooks/wake without RODiT signature — HTTP ${code}" ;;
      404)
        echo "not-passed  POST /hooks/wake without RODiT signature — HTTP 404 (route not exposed)" >&2
        exit 1
        ;;
      *)
        echo "not-passed  POST /hooks/wake without RODiT signature — HTTP ${code} (stack requires 400 or 401)" >&2
        exit 1
        ;;
    esac
  else
    echo "==> Skip webhook ingress smoke (CONSTITUTION_SKIP_SUITES includes webhook)"
  fi

  creds="$(agent_near_credentials_for_tests "$id")"
  if ! _agent_container_name_running "$container"; then
    [[ -n "$creds" ]] || {
      echo "skipped: agent not running and no near-credentials — skipping outbound/testhola webhook suites" >&2
      return 1
    }
  fi

  local peer_token_id="" cross_peer
  peer_token_id="$(resolve_peer_token_id "$id" 2>/dev/null || true)"
  if [[ -n "$peer_token_id" ]] && _agent_container_name_running "$container"; then
    local peer_base container_creds deploy_id peer_local_base
    cross_peer="$(resolve_local_cross_agent_peer_token_id "$id" 2>/dev/null || true)"
    if [[ -n "$cross_peer" && "$peer_token_id" == "$cross_peer" ]]; then
      echo "    (outbound smoke peer: same-host cross-agent ${peer_token_id})"
    fi
    peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")")"
    deploy_id="$(find_deploy_id_for_token_id "$peer_token_id" 2>/dev/null || true)"
    if [[ -n "$deploy_id" ]]; then
      local peer_local_base
      peer_local_base="$(agent_container_ingress_base_url "$deploy_id" 2>/dev/null || true)"
      [[ -z "$peer_local_base" ]] && peer_local_base="$(agent_a2a_public_base_url "$deploy_id" 2>/dev/null || true)"
      [[ -n "$peer_local_base" ]] && peer_base="$peer_local_base"
    fi
    container_creds="$(agent_near_credentials_for_tests "$id")"
    if [[ -n "$peer_base" && -n "$container_creds" ]]; then
      echo ""
      echo "==> Outbound: send_rodit_webhook smoke (${id} → ${peer_token_id})"
      podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
      podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node -e "
        import { runOutboundWebhookToPeer } from 'file:///tmp/lib-rodit-webhook-test.mjs';
        const r = await runOutboundWebhookToPeer({
          localId: '${id}',
          peerId: '${peer_token_id}',
          localCredsPath: '${container_creds}',
          peerBase: '${peer_base}',
          markerPrefix: 'test-webhook-outbound',
          delaySeconds: 0,
        });
        const ok = r.deliveredOk && r.peerReceivedOk;
        process.stdout.write((r.deliveredOk ? 'passed' : 'not-passed') + '  send_rodit_webhook to peer — ' + r.deliveredDetail + '\n');
        process.stdout.write((r.peerReceivedOk ? 'passed' : 'not-passed') + '  GET peer /hooks/_receipts — ' + r.peerReceivedDetail + '\n');
        process.exit(ok ? 0 : 1);
      " || failed=1
    fi
  fi

  if [[ "${SKIP_TESTHOLA:-0}" == 1 ]]; then
    echo ""
    echo "==> Skip /api/testhola webhook delivery (SKIP_TESTHOLA=1)"
    return "$failed"
  fi

  echo ""
  echo "==> /api/testhola webhook delivery (IdentyClaw API → agent webhook_url)"
  echo "    Same pattern as clienttest-idc: valid HOLA triggers signed webhooks to /hooks/wake and /hooks/agent"
  local api_base_args=() api_base
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  [[ -n "$api_base" ]] && api_base_args=(--api-base "$api_base")
  if _agent_container_name_running "$container"; then
    local container_creds ext_dir
    container_creds="$(agent_near_credentials_for_tests "$id")"
    [[ -n "$container_creds" ]] || container_creds="$creds"
    ext_dir="$(agent_a2a_ext_dir_container)"
    podman_cp_lib_rodit_env "$container" || return 1
    podman_cp_lib_test_report "$container" || return 1
    podman cp "${IDENTYCLAW_ROOT}/scripts/test-webhooks-testhola.mjs" "$container:/tmp/test-webhooks-testhola.mjs" >/dev/null
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-webhooks-testhola.mjs \
      --ext-dir "$ext_dir" \
      --creds "$container_creds" \
      --agent-base "$(agent_container_ingress_base_url "$id")" \
      "${api_base_args[@]}" || failed=1
  elif [[ -n "$creds" ]]; then
    NODE_TLS_REJECT_UNAUTHORIZED=0 node "${IDENTYCLAW_ROOT}/scripts/test-webhooks-testhola.mjs" \
      --ext-dir "$(agent_a2a_ext_dir "$(agent_home "$id")")" \
      --creds "$creds" \
      --agent-base "$(agent_ingress_base_url "$id")" \
      "${api_base_args[@]}" || failed=1
  fi
  return "$failed"
}


cmd_send_rodit_webhook() {
  local id="${1:?Usage: $0 send-rodit-webhook agent-c <peer-token-id> [message]}"
  local peer_token_id="${2:?Usage: $0 send-rodit-webhook agent-c <peer-token-id> [message]}"
  local text="${3:-}"
  local delay="${SEND_RODIT_WEBHOOK_DELAY:-10}"
  require_podman
  load_env
  is_passport_token_id "$peer_token_id" || {
    echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
    exit 1
  }
  require_agent_running "$id"

  local container creds ext_dir
  container="$(agent_container "$id")"
  creds="$(agent_near_credentials_in_container "$id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials in ${id} container" >&2
    exit 1
  }

  podman cp "${IDENTYCLAW_ROOT}/scripts/send-rodit-webhook.mjs" "$container:/tmp/send-rodit-webhook.mjs" >/dev/null
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/send-rodit-webhook.mjs \
    --peer "$peer_token_id" \
    --delay "$delay" \
    --creds "$creds" \
    ${text:+--text "$text"}
}


cmd_test_webhook_p2p() {
  local sender peer_token_id
  require_podman
  load_env
  sender="${1:-$(resolve_local_agent_id)}"
  peer_token_id="${2:-}"
  if [[ -z "$peer_token_id" ]]; then
    peer_token_id="$(resolve_peer_token_id "$sender" 2>/dev/null || true)"
    [[ -n "$peer_token_id" ]] || {
      echo "No peer token_id in A2A_PEER_AGENTS for ${sender} — set IDENTYCLAW_PEER_TOKEN_ID or pass token_id" >&2
      return 1
    }
  fi
  is_passport_token_id "$peer_token_id" || {
    echo "Peer must be a Passport token_id (got: ${peer_token_id})" >&2
    return 1
  }
  require_agent_running "$sender"

  local sender_container sender_creds receiver_base local_base peer_creds ext_dir
  local receiver_deploy_id reverse_via_container=0 local_receiver_base
  sender_container="$(agent_container "$sender")"
  receiver_base="$(a2a_peer_public_base_url_with_retry "$peer_token_id" "$(agent_home "$sender")")"
  receiver_deploy_id="$(find_deploy_id_for_token_id "$peer_token_id" 2>/dev/null || true)"
  if [[ -n "$receiver_deploy_id" ]]; then
    local_receiver_base="$(agent_container_ingress_base_url "$receiver_deploy_id" 2>/dev/null || true)"
    [[ -z "$local_receiver_base" ]] && local_receiver_base="$(agent_a2a_public_base_url "$receiver_deploy_id" 2>/dev/null || true)"
    [[ -n "$local_receiver_base" ]] && receiver_base="$local_receiver_base"
  fi
  local_base="$(agent_container_ingress_base_url "$sender")"
  [[ -n "$local_base" ]] || local_base="$(agent_a2a_public_base_url "$sender")"
  [[ -n "$local_base" ]] || local_base="$(agent_ingress_base_url "$sender")"
  [[ -n "$receiver_base" ]] || {
    if a2a_resolve_peers_by_token_id_enabled; then
      echo "No URL for peer token_id ${peer_token_id} — API /full and on-chain metadata.webhook_url lookup failed" >&2
    else
      echo "No URL for peer token_id ${peer_token_id} — set A2A_PEER_URLS in env.local" >&2
    fi
    return 1
  }

  sender_creds="$(agent_near_credentials_for_tests "$sender")"
  [[ -n "$sender_creds" ]] || {
    echo "No NEAR credentials for ${sender} (secrets/near-credentials/*.json; host unreadable — check container mount)" >&2
    return 1
  }

  peer_creds="$(peer_near_credentials_path "$peer_token_id")"
  local receiver_container
  if [[ -n "$receiver_deploy_id" ]]; then
    receiver_container="$(agent_container "$receiver_deploy_id")"
    if podman ps --format '{{.Names}}' | grep -qx "$receiver_container"; then
      reverse_via_container=1
    fi
  fi

  podman_cp_lib_test_report "$sender_container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$sender_container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-webhooks-p2p-suite.mjs" "$sender_container:/tmp/test-webhooks-p2p-suite.mjs" >/dev/null

  local sender_token_id
  sender_token_id="$(agent_token_id "$sender")"
  [[ -n "$sender_token_id" ]] || {
    echo "Cannot resolve Passport token_id for ${sender} — probe NEAR creds / IDENTITYCLAW.md" >&2
    return 1
  }

  echo "==> P2P webhook test (outbound + inbound via send_rodit_webhook)"
  echo "    Outbound: ${sender} (${sender_token_id}) delivers → peer token_id=${peer_token_id} records"
  echo "    Inbound:  peer delivers → ${sender} (${sender_token_id}) records"

  local -a exec_args=(
    node /tmp/test-webhooks-p2p-suite.mjs
    --local "$sender_token_id"
    --peer "$peer_token_id"
    --local-creds "$sender_creds"
    --local-base "$local_base"
    --peer-base "$receiver_base"
    --path hooks/wake
  )
  [[ -n "$sender_token_id" ]] && exec_args+=(--local-token-id "$sender_token_id")
  if [[ -n "${WEBHOOK_P2P_INBOUND_POLL_TIMEOUT_MS:-}" ]]; then
    exec_args+=(--poll-timeout-ms "$WEBHOOK_P2P_INBOUND_POLL_TIMEOUT_MS")
  fi

  if [[ "$reverse_via_container" -eq 1 ]]; then
    exec_args+=(--skip-inbound)
  elif [[ -n "$peer_creds" && "${WEBHOOK_P2P_SIMULATE_INBOUND:-}" == 1 ]]; then
    podman cp "$peer_creds" "$sender_container:/tmp/peer-inbound-creds.json" >/dev/null
    exec_args+=(--simulate-inbound --peer-creds /tmp/peer-inbound-creds.json)
  else
    echo "    Inbound: live peer at ${receiver_base} via A2A message/send (P2P login → send_rodit_webhook at origin)"
  fi

  local smoke_responder_pids=()
  if [[ "$reverse_via_container" -ne 1 ]] && [[ "${WEBHOOK_P2P_SIMULATE_INBOUND:-}" != 1 ]]; then
    local smoke_id
    for smoke_id in $AGENT_IDS; do
      if agent_container_running "$smoke_id"; then
        echo "    Inbound: polling ${smoke_id} A2A webhook smoke responder during live peer test"
        (
          while true; do
            respond_a2a_webhook_smoke_one "$smoke_id" >/dev/null 2>&1 || true
            sleep "${WEBHOOK_P2P_SMOKE_POLL_SEC:-2}"
          done
        ) &
        smoke_responder_pids+=("$!")
      fi
    done
  fi

  local exit_code=0
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" "${exec_args[@]}" || exit_code=$?

  if [[ ${#smoke_responder_pids[@]} -gt 0 ]]; then
    local pid
    for pid in "${smoke_responder_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    for smoke_id in $AGENT_IDS; do
      respond_a2a_webhook_smoke_one "$smoke_id" >/dev/null 2>&1 || true
    done
  fi

  if [[ "$reverse_via_container" -eq 1 && -n "$local_base" && -n "$receiver_deploy_id" ]]; then
    echo ""
    echo "--- Inbound: we receive webhooks from peer (${receiver_deploy_id} container) ---"
    local receiver_creds marker send_out verify_script
    receiver_creds="$(agent_near_credentials_in_container "$receiver_deploy_id")"
    [[ -n "$receiver_creds" ]] || {
      echo "not-passed  peer send_rodit_webhook to local gateway — no NEAR creds in ${receiver_deploy_id} container" >&2
      return 1
    }
    marker="inbound-${peer_token_id}-to-${sender}-$(date +%s)"
    podman cp "${IDENTYCLAW_ROOT}/scripts/send-rodit-webhook.mjs" "$receiver_container:/tmp/send-rodit-webhook.mjs" >/dev/null
    podman cp "${IDENTYCLAW_ROOT}/scripts/lib-rodit-webhook-test.mjs" "$sender_container:/tmp/lib-rodit-webhook-test.mjs" >/dev/null
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" node -e "
      import { clearReceipts } from 'file:///tmp/lib-rodit-webhook-test.mjs';
      await clearReceipts('${local_base}');
    " >/dev/null
    if [[ -n "$sender_token_id" ]]; then
    send_out="$(podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$receiver_container" node /tmp/send-rodit-webhook.mjs \
      --peer "$sender_token_id" --text "$marker" --delay 0 --creds "$receiver_creds" 2>&1)" || true
    if echo "$send_out" | grep -q '"ok": true'; then
      echo "passed  peer send_rodit_webhook to local gateway — $(echo "$send_out" | grep -o '"requestId": "[^"]*"' | head -1)"
    else
      echo "not-passed  peer send_rodit_webhook to local gateway — ${send_out}" >&2
      exit_code=1
    fi
    verify_script="$(mktemp)"
    cat >"$verify_script" <<NODE
import { verifyWebhookReceipt } from "file:///tmp/lib-rodit-webhook-test.mjs";
const r = await verifyWebhookReceipt("${local_base}", { marker: "${marker}" });
process.stdout.write((r.receiptOk ? "passed" : "not-passed") + "  GET local /hooks/_receipts — " + r.receiptDetail + "\\n");
process.exit(r.receiptOk ? 0 : 1);
NODE
    podman cp "$verify_script" "$sender_container:/tmp/verify-webhook-receipt.mjs" >/dev/null
    rm -f "$verify_script"
    podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$sender_container" node /tmp/verify-webhook-receipt.mjs || exit_code=1
    fi
  fi

  return "$exit_code"
}


cmd_test_peer_gateway() {
  cmd_test_unit
}


cmd_test_unit() {
  echo "==> Unit tests (repo-local, no Podman)"
  node "${IDENTYCLAW_ROOT}/scripts/test-unit-all.mjs"
}


cmd_test_a2a_messaging() {
  local local_id="" peer_token_id=""
  if [[ -n "${1:-}" ]] && is_valid_agent_id "$1"; then
    local_id="$1"
    shift
  fi
  peer_token_id="${1:-}"
  local container creds ext_dir peer_base failed=0
  require_podman
  load_env
  local_id="${local_id:-$(resolve_local_agent_id)}"
  peer_token_id="$(resolve_peer_token_id "$local_id" "$peer_token_id" 2>/dev/null || true)"
  [[ -n "$peer_token_id" ]] || {
    echo "test-a2a-messaging requires a peer token_id (A2A_PEER_AGENTS)" >&2
    return 1
  }
  if peer_shares_local_gateway_base "$local_id" "$peer_token_id"; then
    echo "==> Skip test-a2a-messaging (peer ${peer_token_id} shares gateway with ${local_id})"
    return 0
  fi
  require_agent_running "$local_id"

  peer_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$local_id")")"
  [[ -n "$peer_base" ]] || {
    echo "No peer base URL for token_id ${peer_token_id}" >&2
    return 1
  }

  container="$(agent_container "$local_id")"
  creds="$(agent_near_credentials_for_tests "$local_id")"
  [[ -n "$creds" ]] || {
    echo "No NEAR credentials for ${local_id}" >&2
    return 1
  }
  ext_dir="$(agent_a2a_ext_dir_container)"
  podman_cp_lib_rodit_env "$container" || return 1
  podman_cp_lib_test_report "$container" || return 1
  podman cp "${IDENTYCLAW_ROOT}/scripts/test-a2a-messaging-e2e.mjs" "$container:/tmp/test-a2a-messaging-e2e.mjs" >/dev/null

  echo "==> A2A messaging E2E (local=${local_id} → peer ${peer_token_id} at ${peer_base})"
  podman exec -e NODE_TLS_REJECT_UNAUTHORIZED=0 "$container" node /tmp/test-a2a-messaging-e2e.mjs \
    --ext-dir "$ext_dir" --creds "$creds" --peer-base "$peer_base" || failed=1
  return "$failed"
}


cmd_test_all_peers() {
  local local_id peer_token_id peers failed=0
  load_env
  local_id="$(resolve_local_agent_id)"
  peers="$(resolve_live_peer_token_ids "$local_id" 2>/dev/null || true)"
  echo "==> Test constitution — all live remote peers (local=${local_id})"
  echo "    AGENT_IDS=${AGENT_IDS} (excluded from peer targets)"
  echo "    live peers (registry-resolved, deduped by gateway base)=${peers:-none}"
  echo ""

  cmd_test_peer_gateway || failed=1
  echo ""
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
  else
    cmd_test_webhook "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped mail; then
    echo "==> Skip test-mail (CONSTITUTION_SKIP_SUITES includes mail)"
  else
    cmd_test_mail "$local_id" || failed=1
  fi

  if [[ -z "$peers" ]]; then
    echo ""
    echo "==> Skip peer suites (no remote A2A peers — local AGENT_IDS entries are excluded)"
  else
    for peer_token_id in $peers; do
      echo ""
      echo "========================================"
      echo "=== PEER ${peer_token_id} ==="
      echo "========================================"
      if peer_shares_local_gateway_base "$local_id" "$peer_token_id"; then
        echo "==> Skip A2A suites for peer ${peer_token_id} (same gateway as ${local_id}; local suites cover this ingress)"
        echo ""
      else
        if constitution_suite_skipped a2a; then
          echo "==> Skip test-a2a for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a)"
        else
          cmd_test_a2a "$local_id" "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped a2a-auth; then
          echo "==> Skip test-a2a-auth for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
        else
          cmd_test_a2a_auth "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped a2a-messaging; then
          echo "==> Skip test-a2a-messaging for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes a2a-messaging)"
        else
          cmd_test_a2a_messaging "$local_id" "$peer_token_id" || failed=1
        fi
        echo ""
        if constitution_suite_skipped auth-boundaries; then
          echo "==> Skip test-auth-boundaries for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
        else
          cmd_test_auth_boundaries "$peer_token_id" || failed=1
        fi
        echo ""
      fi
      if constitution_suite_skipped webhook-p2p; then
        echo "==> Skip test-webhook-p2p for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes webhook-p2p)"
      else
        cmd_test_webhook_p2p "$local_id" "$peer_token_id" || failed=1
      fi
      if constitution_suite_skipped mail-hola; then
        echo ""
        echo "==> Skip test-mail-hola for peer ${peer_token_id} (CONSTITUTION_SKIP_SUITES includes mail-hola)"
      elif peer_mail_hola_ambiguous "$local_id" "$peer_token_id"; then
        echo ""
        echo "==> Skip test-mail-hola for peer ${peer_token_id} (shares this host's pod ingress; HOLA peerTokenId binding is ambiguous)"
      else
        echo ""
        cmd_test_mail_hola "$local_id" "$peer_token_id" || failed=1
      fi
    done
  fi

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites (all peers): passed"
  else
    echo "Constitution suites (all peers): not-passed (see output above)" >&2
  fi
  return "$failed"
}


print_agent_test_candidates() {
  local id="$1" self_token local_email configured_peers api_peers all_peers peer_token_id
  local probed_json a2a_base peer_email mode source primary_peer constitution_mode
  load_env
  is_valid_agent_id "$id" || return 1
  self_token="$(agent_token_id "$id" 2>/dev/null || true)"
  local_email="$(agent_env_value "$id" EMAIL "")"
  configured_peers="$(a2a_remote_peer_token_ids)"
  all_peers="$(a2a_discovered_test_candidate_token_ids)"
  primary_peer="$(resolve_peer_token_id "$id" 2>/dev/null || true)"

  echo "==> ${id} (token_id=${self_token:-unknown}, email=${local_email:-none})"
  if [[ -z "$all_peers" ]]; then
    echo "    test candidates: (none — no remote peers in A2A_PEER_AGENTS or GET /api/agents)"
    echo "    constitution mode: local-only (self a2a + webhooks + mail IMAP; no cross-agent peer)"
    return 0
  fi

  for peer_token_id in $all_peers; do
    if a2a_peer_token_id_is_configured "$peer_token_id"; then
      source="configured"
    else
      source="api"
    fi
    if [[ "$source" == "api" ]]; then
      a2a_base=""
      peer_email=""
      probed_json="$(probe_test_candidate_peer_json "$id" "$peer_token_id" 2>/dev/null || true)"
      if [[ -n "$probed_json" ]]; then
        read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
      fi
      [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
      if [[ -n "$a2a_base" ]]; then
        mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
        echo "    candidate ${peer_token_id} [${source}]: mode=${mode} a2a=${a2a_base} peer_email=${peer_email:-—}"
      else
        echo "    candidate ${peer_token_id} [${source}]: listed via GET /api/agents (no live gateway URL yet)"
      fi
      continue
    fi
    a2a_base=""
    peer_email=""
    probed_json="$(probe_test_candidate_peer_json "$id" "$peer_token_id" 2>/dev/null || true)"
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$peer_token_id" "$(agent_home "$id")" 2>/dev/null || true)"
    mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    echo "    candidate ${peer_token_id} [${source}]: mode=${mode} a2a=${a2a_base:-—} peer_email=${peer_email:-—}"
  done

  if [[ -n "$primary_peer" ]]; then
    probed_json="$(probe_test_candidate_peer_json "$id" "$primary_peer" 2>/dev/null || true)"
    a2a_base=""
    peer_email=""
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$(a2a_peer_public_base_url "$primary_peer" "$(agent_home "$id")" 2>/dev/null || true)"
    constitution_mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    if a2a_peer_token_id_is_configured "$primary_peer"; then
      source="configured"
    else
      source="api"
    fi
    echo "    constitution peer: ${primary_peer} [${source}] → mode=${constitution_mode}"
  fi
}


print_test_peer_roster() {
  local id configured_peers all_peers api_base api_count cross_peers
  load_env
  configured_peers="$(a2a_remote_peer_token_ids)"
  all_peers="$(a2a_discovered_test_candidate_token_ids)"
  cross_peers="$(local_cross_agent_peer_token_ids "$(resolve_local_agent_id)" 2>/dev/null || true)"
  api_base="$(identyclaw_api_base_url_override 2>/dev/null || true)"
  api_count="$(fetch_identyclaw_api_peer_token_ids 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(len(d.get('tokenIds') or []))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"
  echo "==> Test candidates per agent"
  echo "    AGENT_IDS (local):       ${AGENT_IDS}"
  echo "    A2A_PEER_AGENTS:       ${A2A_PEER_AGENTS:-none}"
  echo "    same-host cross-agent:   ${cross_peers:-none} (preferred for outbound P2P webhooks)"
  echo "    A2A_TEST_EXCLUDE_PEERS:  ${A2A_TEST_EXCLUDE_PEERS:-none}"
  echo "    A2A_TEST_ONLY_PEERS:     ${A2A_TEST_ONLY_PEERS:-none}"
  echo "    CONSTITUTION_SKIP_SUITES: ${CONSTITUTION_SKIP_SUITES:-none}"
  echo "    webhooks pin (local):    ${IDENTYCLAW_CLAWHUB_WEBHOOKS_PLUGIN} (peer receivers must match)"
  echo "    configured remote peers: ${configured_peers:-none}"
  if a2a_discover_peers_from_api_enabled; then
    echo "    API discovery:           GET ${api_base:-api.identyclaw.com}/api/agents (${api_count} token_ids, public; webhook_url needs auth /full)"
  else
    echo "    API discovery:           off (set IDENTYCLAW_A2A_DISCOVER_PEERS_FROM_API=1)"
  fi
  echo "    total candidates:        $(echo "$all_peers" | wc -w | tr -d ' ') (configured + api, deduped)"
  echo ""
  for id in $AGENT_IDS; do
    print_agent_test_candidates "$id" || true
    echo ""
  done
}


cmd_test_candidates() {
  load_env
  echo "==> Constitution test candidates"
  echo ""
  print_test_peer_roster
}


cmd_test_constitution_for_agent() {
  local local_id="$1"
  local failed=0 peers peer base local_email peer_email a2a_base constitution_mode
  local peer_count=0
  load_env
  is_valid_agent_id "$local_id" || {
    echo "Invalid agent id: ${local_id}" >&2
    return 1
  }
  print_constitution_agent_preflight "$local_id"

  # All live remote peers (registry-resolved, deduped by gateway base) — test every one.
  peers="$(resolve_live_peer_token_ids "$local_id" 2>/dev/null || true)"
  local_email="$(agent_env_value "$local_id" EMAIL "")"
  echo "==> Test constitution (local=${local_id})"
  if [[ -n "$peers" ]]; then
    echo "    live peers detected:"
    for peer in $peers; do
      base="$(a2a_peer_public_base_url "$peer" "$(agent_home "$local_id")" 2>/dev/null || true)"
      echo "      - ${peer} → ${base:-unresolved}"
      peer_count=$((peer_count + 1))
    done
  else
    echo "    live peers detected: none (local-only run)"
  fi
  echo ""

  # --- Local coverage (once, peer-independent) ---
  echo "======== LOCAL SUITES (${local_id}) ========"
  if constitution_suite_skipped a2a; then
    echo "==> Skip test-a2a (CONSTITUTION_SKIP_SUITES includes a2a)"
  else
    CONSTITUTION_LOCAL_ONLY=1 cmd_test_a2a "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped a2a-auth; then
    echo "==> Skip test-a2a-auth (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
  else
    CONSTITUTION_LOCAL_ONLY=1 cmd_test_a2a_auth "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped webhook-all; then
    echo "==> Skip test-webhook (CONSTITUTION_SKIP_SUITES includes webhook-all)"
  else
    cmd_test_webhook "$local_id" || failed=1
  fi
  echo ""
  if constitution_suite_skipped mail; then
    echo "==> Skip test-mail (CONSTITUTION_SKIP_SUITES includes mail)"
  else
    cmd_test_mail "$local_id" || failed=1
  fi

  if [[ -z "$peers" ]]; then
    echo ""
    if constitution_suite_skipped auth-boundaries; then
      echo "==> Skip test-auth-boundaries (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
    else
      CONSTITUTION_LOCAL_ONLY=1 cmd_test_auth_boundaries "$local_id" || failed=1
    fi
    echo ""
    echo "==> Skip peer suites (no live remote peers detected)"
    echo ""
    if [[ $failed -eq 0 ]]; then
      echo "Constitution suites (${local_id}): passed"
    else
      echo "Constitution suites (${local_id}): not-passed (see output above)" >&2
    fi
    return "$failed"
  fi

  # --- Per-peer coverage (every live peer detected) ---
  for peer in $peers; do
    base="$(a2a_peer_public_base_url "$peer" "$(agent_home "$local_id")" 2>/dev/null || true)"
    peer_email=""
    a2a_base=""
    local probed_json peer_shares_gateway=0
    probed_json="$(probe_test_candidate_peer_json "$local_id" "$peer" 2>/dev/null || true)"
    if [[ -n "$probed_json" ]]; then
      read -r a2a_base peer_email <<<"$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(' ')
    sys.exit(0)
print(d.get('a2aBase') or '', d.get('peerEmail') or '')
" "$probed_json")"
    fi
    [[ -z "$a2a_base" ]] && a2a_base="$base"
    if peer_shares_local_gateway_base "$local_id" "$peer"; then
      peer_shares_gateway=1
      a2a_base=""
    fi
    constitution_mode="$(classify_constitution_test_mode "$a2a_base" "$peer_email" "$local_email")"
    echo ""
    echo "======== PEER ${peer} (${base:-unresolved}) — from ${local_id} [mode=${constitution_mode}] ========"
    if [[ $peer_shares_gateway -eq 1 ]]; then
      echo "==> Skip A2A suites for peer ${peer} (same gateway as ${local_id}; local suites cover this ingress)"
      echo ""
    else
      if constitution_suite_skipped a2a; then
        echo "==> Skip test-a2a for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a)"
      else
        CONSTITUTION_PEER_ONLY=1 cmd_test_a2a "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped a2a-auth; then
        echo "==> Skip test-a2a-auth for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a-auth)"
      else
        CONSTITUTION_PEER_ONLY=1 cmd_test_a2a_auth "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped a2a-messaging; then
        echo "==> Skip test-a2a-messaging for peer ${peer} (CONSTITUTION_SKIP_SUITES includes a2a-messaging)"
      elif peer_shares_local_gateway_base "$local_id" "$peer"; then
        echo "==> Skip test-a2a-messaging for peer ${peer} (same gateway as ${local_id})"
      else
        cmd_test_a2a_messaging "$local_id" "$peer" || failed=1
      fi
      echo ""
      if constitution_suite_skipped auth-boundaries; then
        echo "==> Skip test-auth-boundaries for peer ${peer} (CONSTITUTION_SKIP_SUITES includes auth-boundaries)"
      else
        cmd_test_auth_boundaries "$local_id" "$peer" || failed=1
      fi
      echo ""
    fi
    if constitution_suite_skipped webhook-p2p; then
      echo "==> Skip test-webhook-p2p for peer ${peer} (CONSTITUTION_SKIP_SUITES includes webhook-p2p)"
    else
      cmd_test_webhook_p2p "$local_id" "$peer" || failed=1
    fi
    if constitution_suite_skipped mail-hola; then
      echo ""
      echo "==> Skip test-mail-hola for peer ${peer} (CONSTITUTION_SKIP_SUITES includes mail-hola)"
    elif peer_mail_hola_ambiguous "$local_id" "$peer"; then
      echo ""
      echo "==> Skip test-mail-hola for peer ${peer} (shares this host's pod ingress; HOLA peerTokenId binding is ambiguous)"
    else
      echo ""
      cmd_test_mail_hola "$local_id" "$peer" || failed=1
    fi
  done

  echo ""
  echo "==> Constitution peer coverage (${local_id}): ${peer_count} live peer(s) tested"
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites (${local_id}): passed"
  else
    echo "Constitution suites (${local_id}): not-passed (see output above)" >&2
  fi
  return "$failed"
}


cmd_test() {
  local local_id="${1:-}" peer_token_id="" failed=0
  load_env
  if [[ -n "$local_id" ]] && ! is_valid_agent_id "$local_id"; then
    echo "Usage: $0 test [agent-id]" >&2
    return 1
  fi
  local_id="${local_id:-$(resolve_local_agent_id)}"
  peer_token_id="$(resolve_peer_token_id "$local_id" 2>/dev/null || true)"
  echo "==> Test constitution (local=${local_id}${peer_token_id:+, peer token_id=${peer_token_id}})"
  echo "    AGENT_IDS=${AGENT_IDS}"
  echo "    A2A_PEER_AGENTS=${A2A_PEER_AGENTS}"
  echo ""

  cmd_test_unit || failed=1
  echo ""
  cmd_test_constitution_for_agent "$local_id" || failed=1

  echo ""
  if [[ $failed -eq 0 ]]; then
    echo "Constitution suites: passed"
  else
    echo "Constitution suites: not-passed (see output above)" >&2
  fi
  return "$failed"
}


cmd_test_all_agents() {
  local id failed=0 agent_failed=0
  local -a results=()
  require_podman
  require_rootless_user
  load_env

  echo "==> Test constitution — all agents on this host"
  echo ""

  local missing_mail_pw
  missing_mail_pw="$(constitution_agents_missing_mail_password)"
  if [[ -n "$missing_mail_pw" ]]; then
    echo "==> Preflight not-passed: missing Migadu mailbox password for:${missing_mail_pw}" >&2
    echo "    Run: ./identyclaw.sh set-password <agent-id> for each, then re-run test-all-agents" >&2
    return 1
  fi
  echo "==> Preflight: Migadu passwords present for all AGENT_IDS"
  echo ""

  echo "==> Start agents in AGENT_IDS"
  for id in $AGENT_IDS; do
    if agent_container_running "$id"; then
      echo "    ${id}: already running"
    else
      echo "    ${id}: starting..."
      start_one "$id" || failed=1
    fi
  done
  [[ $failed -eq 0 ]] || {
    echo "Start failed for one or more agents — fix before running constitution suites" >&2
    return 1
  }
  echo ""

  echo "==> Sync A2A config (ensure outbound peers + public base, even when already running)"
  for id in $AGENT_IDS; do
    ensure_a2a_config "$id" "$(agent_home "$id")" "$(agent_container "$id")" || true
  done
  echo ""

  print_test_peer_roster
  echo ""

  cmd_test_peer_gateway || failed=1
  echo ""

  for id in $AGENT_IDS; do
    echo "########################################"
    echo "### AGENT ${id}"
    echo "########################################"
    echo ""
    agent_failed=0
    cmd_test_constitution_for_agent "$id" || agent_failed=1
    if [[ $agent_failed -eq 0 ]]; then
      results+=("${id}: passed")
    else
      results+=("${id}: not-passed")
      failed=1
    fi
    echo ""
  done

  echo "========================================"
  echo "==> Constitution summary (all agents)"
  for line in "${results[@]}"; do
    echo "    ${line}"
  done
  echo "========================================"
  if [[ $failed -eq 0 ]]; then
    echo "All constitution suites: passed"
  else
    echo "All constitution suites: not-passed (see per-agent output above)" >&2
  fi
  return "$failed"
}


cmd_test_all_agents_chat() {
  local id constitution_failed=0 chat_failed=0
  local -a chat_results=()
  require_podman
  require_rootless_user
  load_env

  echo "==> Full test run — constitution suites + chat peer discovery (all agents)"
  echo ""

  cmd_test_all_agents || constitution_failed=1
  echo ""
  echo "========================================"
  echo "==> Chat-driven peer discovery (A2A + email)"
  echo "========================================"
  echo ""

  for id in $AGENT_IDS; do
    require_agent_running "$id"
    echo "########################################"
    echo "### CHAT TEST ${id}"
    echo "########################################"
    echo ""
    if cmd_ask "$id" "$(agent_chat_peer_discovery_test_prompt "$id")"; then
      chat_results+=("${id}: chat passed")
    else
      chat_results+=("${id}: chat not-passed")
      chat_failed=1
    fi
    echo ""
  done

  echo "========================================"
  echo "==> Chat peer-discovery summary"
  for line in "${chat_results[@]}"; do
    echo "    ${line}"
  done
  echo "========================================"
  if [[ $constitution_failed -eq 0 && $chat_failed -eq 0 ]]; then
    echo "All tests (constitution + chat): passed"
    return 0
  fi
  echo "Tests not-passed (constitution=${constitution_failed}, chat=${chat_failed})" >&2
  return 1
}

