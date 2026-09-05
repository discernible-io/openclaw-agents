# IdentyClaw Passport host helpers (enroll → purchase → ensure_session).
# Pattern mirrors hermes-agents/deploy/hermes.sh idcp-* commands.

# Stop agent containers and restore host ownership so we can write near-credentials.
# Mirrors hermes setup stopping the gateway before idcp-setup.
_idcp_prepare_host_write() {
  local ids="${1:-}"
  local id container dir
  load_env
  [[ -n "$ids" ]] || ids="$(configured_agent_ids)"
  for id in $ids; do
    container="$(agent_container "$id")"
    if podman container exists "$container" 2>/dev/null; then
      if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
        echo "==> Stopping ${container} for Passport setup"
        podman stop "$container" >/dev/null 2>&1 || true
      fi
      podman rm -f "$container" >/dev/null 2>&1 || true
    fi
    dir="$(agent_home "$id")"
    if [[ -d "$dir" ]]; then
      restore_pod_path_for_host "$dir" 2>/dev/null || true
    fi
  done
}

ensure_idcp_layout_for_agent() {
  local id="${1:?}"
  local home
  home="$(agent_home "$id")"
  mkdir -p \
    "$home/secrets/near-credentials" \
    "$home/secrets/identyclaw" \
    2>/dev/null || true
  chmod 700 "$home/secrets" "$home/secrets/near-credentials" "$home/secrets/identyclaw" 2>/dev/null || true
}

_idcp_install_core() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm required on host for IdentyClaw (idcp-install)" >&2
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "node required on host for IdentyClaw" >&2
    return 1
  fi
  echo "Installing idcp deps in ${IDENTYCLAW_ROOT}/idcp ..."
  (cd "${IDENTYCLAW_ROOT}/idcp" && npm install --omit=dev)
}

# Host-side idcp for one agent (IDENTYCLAW_HOME = agents/<id>/).
_idcp_host() {
  local id="${1:?}"
  shift
  local home
  home="$(agent_home "$id")"
  ensure_idcp_layout_for_agent "$id"
  IDENTYCLAW_HOME="$home" \
    IDENTYCLAW_NEAR_CREDENTIALS_DIR="$home/secrets/near-credentials" \
    node "${IDENTYCLAW_ROOT}/idcp/bin/idcp.mjs" "$@"
}

_idcp_account_id_for_agent() {
  local id="${1:?}"
  local dir home
  home="$(agent_home "$id")"
  dir="${home}/secrets/near-credentials"
  if [[ -f "$dir/.active" ]]; then
    tr -d '[:space:]' <"$dir/.active"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$dir" <<'PY'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1])
if not d.is_dir():
    sys.exit(0)
files = sorted(d.glob("*.json"))
if not files:
    sys.exit(0)
try:
    raw = json.loads(files[0].read_text())
except Exception:
    sys.exit(0)
aid = raw.get("account_id") or raw.get("implicit_account_id") or ""
if aid:
    print(aid)
PY
  fi
}

_idcp_mark_active() {
  local id="${1:?}"
  local account_id="${2:?}"
  local dir
  dir="$(agent_home "$id")/secrets/near-credentials"
  mkdir -p "$dir"
  printf '%s\n' "$account_id" >"$dir/.active"
  chmod 600 "$dir/.active" 2>/dev/null || true
  chmod 600 "$dir/${account_id}.json" 2>/dev/null || true
}

# Natural IdentyClaw path: install → enroll → purchase guide → ensure_session → me.
# Invoked from init (default) or standalone to resume after mint.
# Usage: idcp_setup_one_agent <agent-id>
idcp_setup_one_agent() {
  local id="${1:?}"
  local home enroll_json account_id tmp_sess tmp_me attempt max_attempts

  home="$(agent_home "$id")"
  ensure_idcp_layout_for_agent "$id"
  write_idcp_wallet_scripts "$home" "$id" 2>/dev/null || true

  echo ""
  echo "=== IdentyClaw Passport: ${id} ==="
  echo "Enrolling NEAR implicit account (agent key file — not the paying wallet) ..."
  enroll_json="$(_idcp_host "$id" enroll)"
  echo "$enroll_json"
  account_id="$(
    printf '%s' "$enroll_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
print(d.get("account_id") or "")
' 2>/dev/null || true
  )"
  if [[ -z "$account_id" ]]; then
    account_id="$(_idcp_account_id_for_agent "$id")"
  fi
  if [[ -z "$account_id" ]]; then
    echo "Could not determine implicit_account_id after enroll for ${id}." >&2
    return 1
  fi
  _idcp_mark_active "$id" "$account_id"
  # Wire .env / plugin pointers when possible (no restart required yet).
  ensure_near_credentials_active "$home" 2>/dev/null || true
  sync_identyclaw_env "$home" "" 2>/dev/null || true

  tmp_sess="$(mktemp)"
  tmp_me="$(mktemp)"
  if _idcp_host "$id" ensure_session >"$tmp_sess" 2>/dev/null \
    && _idcp_host "$id" me >"$tmp_me" 2>/dev/null; then
    echo ""
    echo "Passport already active on home (api.identyclaw.com) for ${id}:"
    cat "$tmp_me"
    rm -f "$tmp_sess" "$tmp_me"
    return 0
  fi
  rm -f "$tmp_sess" "$tmp_me"

  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo "Craft your Passport for ${id} (required)"
  echo "──────────────────────────────────────────────────────────────"
  echo "1. Fund a SEPARATE checkout wallet with NEAR (e.g. HOT Wallet)."
  echo "   Do not paste the agent key file into chat or the portal."
  echo "2. Open: https://purchase.identyclaw.com"
  echo "3. Paste this 64-char hex as the NEAR recipient account:"
  echo ""
  echo "   ${account_id}"
  echo ""
  echo "4. Connect the paying wallet, mint, wait for confirmation."
  echo "   Docs: https://www.discernible.io/  ·  https://api.identyclaw.com/.well-known/enrollment"
  echo "──────────────────────────────────────────────────────────────"

  if [[ ! -t 0 ]]; then
    echo "Non-interactive TTY: after minting, re-run: ./identyclaw.sh idcp-setup ${id}" >&2
    echo "Account id saved under ${home}/secrets/near-credentials/" >&2
    return 0
  fi

  # shellcheck disable=SC2162
  read -r -p "Press Enter after the Passport mint confirms (Ctrl-C to pause; resume with ./identyclaw.sh idcp-setup ${id}) ... "

  attempt=1
  max_attempts=8
  while (( attempt <= max_attempts )); do
    echo "Activating home session for ${id} (attempt ${attempt}/${max_attempts}) ..."
    if _idcp_host "$id" ensure_session && _idcp_host "$id" me; then
      echo ""
      echo "IdentyClaw home session ready for ${id}."
      ensure_near_credentials_active "$home" 2>/dev/null || true
      sync_identyclaw_env "$home" "" 2>/dev/null || true
      return 0
    fi
    if (( attempt == max_attempts )); then
      break
    fi
    echo "Login failed — Passport may still be indexing, or mint not finished."
    # shellcheck disable=SC2162
    read -r -p "Press Enter to retry (or Ctrl-C and later: ./identyclaw.sh idcp-setup ${id}) ... "
    (( ++attempt ))
  done

  echo "Could not activate session yet for ${id}. After mint confirms:" >&2
  echo "  ./identyclaw.sh idcp-setup ${id}" >&2
  echo "  # or: ./identyclaw.sh idcp ${id} ensure_session && ./identyclaw.sh idcp ${id} me" >&2
  return 1
}
