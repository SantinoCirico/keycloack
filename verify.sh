#!/usr/bin/env bash
# verify.sh — Phase 0 sanity check for the lumini Keycloak realm.
#
# Boots through the verification steps documented in the migration plan:
#   1. Confirm Keycloak is reachable.
#   2. Confirm the lumini realm imported (well-known endpoint).
#   3. Request a token via password grant against friopacking-planner-web.
#   4. Decode the JWT payload and assert the expected claims are present.
#
# Prerequisites:
#   - `docker compose up -d` has been run from this directory.
#   - You have manually created a test user in the lumini realm and added
#     them to /PE/Friopacking/PlannerLima:
#       (a) Open http://localhost:8080/admin
#       (b) Log in with KEYCLOAK_ADMIN_USERNAME / KEYCLOAK_ADMIN_PASSWORD from .env
#       (c) Switch realm dropdown to "lumini"
#       (d) Users -> Add user -> username: maria.lopez, email: maria.lopez@lumini.dev
#       (e) Credentials tab -> Set password (uncheck "Temporary")
#       (f) Groups tab -> Join Group -> /PE/Friopacking/PlannerLima
#
# Usage:
#   USERNAME=maria.lopez PASSWORD='YourPassword1' ./verify.sh
#
# Requires: bash, curl, python3 (on Windows: Git Bash + Python from python.org).

set -euo pipefail

KC_BASE="${KC_BASE:-http://localhost:8080}"
REALM="${REALM:-lumini}"
CLIENT_ID="${CLIENT_ID:-friopacking-planner-web}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Keycloak reachable
# ---------------------------------------------------------------------------
bold "[1/4] Checking Keycloak is reachable at ${KC_BASE} ..."
if ! curl -fsS "${KC_BASE}/realms/master/.well-known/openid-configuration" >/dev/null; then
  red "  FAIL: Cannot reach ${KC_BASE}. Is 'docker compose up -d' running?"
  exit 1
fi
green "  OK"

# ---------------------------------------------------------------------------
# 2. lumini realm imported
# ---------------------------------------------------------------------------
bold "[2/4] Checking the '${REALM}' realm imported ..."
WELL_KNOWN="${KC_BASE}/realms/${REALM}/.well-known/openid-configuration"
if ! curl -fsS "${WELL_KNOWN}" >/dev/null; then
  red "  FAIL: ${WELL_KNOWN} did not return 200."
  red "        Check 'docker compose logs keycloak' for an import error."
  exit 1
fi
ISSUER=$(curl -fsS "${WELL_KNOWN}" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
green "  OK  issuer = ${ISSUER}"

# ---------------------------------------------------------------------------
# 3. Token request (requires test user)
# ---------------------------------------------------------------------------
if [[ -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
  yellow ""
  yellow "[3/4] SKIPPED token check — USERNAME and PASSWORD env vars not set."
  yellow "      Create a test user (see header of this script) then re-run:"
  yellow "        USERNAME=maria.lopez PASSWORD='YourPassword1' ./verify.sh"
  exit 0
fi

bold "[3/4] Requesting an access token for ${USERNAME} via ${CLIENT_ID} ..."
TOKEN_ENDPOINT="${KC_BASE}/realms/${REALM}/protocol/openid-connect/token"
TOKEN_RESPONSE=$(curl -fsS -X POST "${TOKEN_ENDPOINT}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${CLIENT_ID}" \
  -d "username=${USERNAME}" \
  -d "password=${PASSWORD}" \
  -d "scope=openid") || {
    red "  FAIL: Token request rejected. Check user exists, password is correct,"
    red "        and that 'Direct access grants' is enabled on ${CLIENT_ID}."
    exit 1
  }

ACCESS_TOKEN=$(printf '%s' "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
green "  OK  received access_token (${#ACCESS_TOKEN} bytes)"

# ---------------------------------------------------------------------------
# 4. Decode and assert claims
# ---------------------------------------------------------------------------
bold "[4/4] Decoding access token payload and asserting required claims ..."
PAYLOAD_JSON=$(python3 - <<PY
import sys, json, base64
token = "${ACCESS_TOKEN}"
parts = token.split('.')
if len(parts) != 3:
    print("invalid JWT", file=sys.stderr); sys.exit(1)
# JWT base64url decode (with padding fix)
def b64url(s):
    s += '=' * (-len(s) % 4)
    return base64.urlsafe_b64decode(s.encode())
payload = json.loads(b64url(parts[1]))
print(json.dumps(payload, indent=2, ensure_ascii=False))
PY
)
echo "${PAYLOAD_JSON}"

# Required claims per the migration plan
python3 - <<PY
import sys, json
payload = json.loads("""${PAYLOAD_JSON}""")
errors = []
expected_iss = "${ISSUER}"

if payload.get("iss") != expected_iss:
    errors.append(f"iss mismatch: got {payload.get('iss')!r} expected {expected_iss!r}")

if "groups" not in payload:
    errors.append("missing 'groups' claim — is the lumini-groups client scope attached to the client?")
elif not any(g.startswith("/PE/") for g in payload["groups"]):
    errors.append(f"'groups' claim does not include any /PE/* path: {payload['groups']}")

ra = payload.get("realm_access", {})
if not isinstance(ra.get("roles"), list):
    errors.append("missing 'realm_access.roles' claim")

if "${CLIENT_ID}" not in (payload.get("aud") if isinstance(payload.get("aud"), list) else [payload.get("aud")]) and payload.get("azp") != "${CLIENT_ID}":
    errors.append(f"token audience does not include ${CLIENT_ID}")

if errors:
    print("\n".join("  FAIL: " + e for e in errors), file=sys.stderr)
    sys.exit(1)
PY

green "  OK  all required claims present"
echo
green "Phase 0 verification PASSED. Realm 'lumini' is correctly configured."
