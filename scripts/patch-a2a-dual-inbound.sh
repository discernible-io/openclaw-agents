#!/usr/bin/env bash
# Patch A2A IDC plugin: dual inbound must catch validate_jwt_token_be throws per profile.
# Without this, P2P JWTs fail because mediated profile throws before p2p is tried.
set -euo pipefail

target="${1:?usage: patch-a2a-dual-inbound.sh <path-to-rodit-inbound.js>}"
[[ -f "$target" ]] || exit 0

if grep -q 'catch {$' "$target" 2>/dev/null && grep -q 'validateJwtWithProfiles' "$target"; then
  if grep -A6 'validateJwtWithProfiles' "$target" | grep -q 'catch'; then
    exit 0
  fi
fi

python3 - "$target" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """async function validateJwtWithProfiles(token, config, validateJwt) {
    for (const profile of resolveInboundAudienceProfiles(config)) {
        const result = await validateJwt(token, {
            ...config,
            issuer: profile.issuer,
            audience: profile.audience,
        });
        if (result?.valid && result.payload) {
            return result;
        }
    }
    return null;
}"""
new = """async function validateJwtWithProfiles(token, config, validateJwt) {
    for (const profile of resolveInboundAudienceProfiles(config)) {
        try {
            const result = await validateJwt(token, {
                ...config,
                issuer: profile.issuer,
                audience: profile.audience,
            });
            if (result?.valid && result.payload) {
                return result;
            }
        }
        catch {
            // validate_jwt_token_be throws on mismatch; try next profile (dual: mediated → p2p)
        }
    }
    return null;
}"""
if old not in text:
    if "catch {" in text and "validateJwtWithProfiles" in text:
        sys.exit(0)
    sys.stderr.write(f"patch-a2a-dual-inbound: pattern not found in {path}\n")
    sys.exit(1)
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
