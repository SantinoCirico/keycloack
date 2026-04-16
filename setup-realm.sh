#!/usr/bin/env bash
# Creates the lumini realm from scratch via the Keycloak Admin REST API.
# A fresh realm gets all built-in scopes (openid, profile, email, roles, etc.)
# Then we add our custom clients, roles, groups, and the lumini-groups scope.
#
# Usage:  bash setup-realm.sh

set -euo pipefail

KC_BASE="http://localhost:8080"

# ── Load credentials from .env (same file docker-compose uses) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

ADMIN_USER="${KEYCLOAK_ADMIN_USERNAME:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

echo "Using Keycloak at $KC_BASE with user=$ADMIN_USER"

# ── Helper ────────────────────────────────────────────────────────────
PY=$(command -v python3 || command -v python)

get_token() {
  local RESPONSE
  RESPONSE=$(curl -s -X POST "$KC_BASE/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "grant_type=password" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS")

  local TOKEN_VAL
  TOKEN_VAL=$($PY -c "import sys,json; data=json.load(sys.stdin); print(data.get('access_token',''))" <<< "$RESPONSE")

  if [ -z "$TOKEN_VAL" ]; then
    echo "[ERROR] Failed to get admin token. Keycloak response:" >&2
    echo "$RESPONSE" >&2
    echo "" >&2
    echo "Check that KEYCLOAK_ADMIN_USERNAME and KEYCLOAK_ADMIN_PASSWORD in .env" >&2
    echo "match the credentials Keycloak was bootstrapped with." >&2
    exit 1
  fi
  echo "$TOKEN_VAL"
}

TOKEN=$(get_token)
AUTH="Authorization: Bearer $TOKEN"
CT="Content-Type: application/json"

# ── 1. Delete existing lumini realm (if any) ──────────────────────────
echo "==> Deleting existing lumini realm (if any)..."
curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "$AUTH" "$KC_BASE/admin/realms/lumini" || true
echo " done"

# ── 2. Create fresh lumini realm (gets all built-in scopes) ──────────
echo "==> Creating fresh lumini realm..."
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms" -d '{
  "realm": "lumini",
  "displayName": "Lumini",
  "enabled": true,
  "sslRequired": "none",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": true,
  "verifyEmail": false,
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "bruteForceProtected": true,
  "permanentLockout": true,
  "failureFactor": 30,
  "passwordPolicy": "length(10) and digits(1) and upperCase(1) and notUsername and passwordHistory(5)"
}'
echo "  Realm created"

# Refresh token (realm creation can take a moment)
TOKEN=$(get_token)
AUTH="Authorization: Bearer $TOKEN"

# ── 3. Create realm roles ─────────────────────────────────────────────
echo "==> Creating realm roles..."
for ROLE in SUPER_ADMIN ADMIN SUPERVISOR USER DEVELOPER; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 4. Create the lumini-groups custom scope ──────────────────────────
echo "==> Creating lumini-groups client scope..."
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/client-scopes" -d '{
  "name": "lumini-groups",
  "description": "Adds group paths as a groups claim on tokens",
  "protocol": "openid-connect",
  "attributes": {
    "include.in.token.scope": "true",
    "display.on.consent.screen": "false"
  }
}'

# Get scope UUID
GROUPS_SCOPE_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/client-scopes" \
  | $PY -c "import sys,json; scopes=json.load(sys.stdin); print([s['id'] for s in scopes if s['name']=='lumini-groups'][0])")
echo "    Scope ID: $GROUPS_SCOPE_ID"

# Add group membership mapper to the scope
echo "    Adding group membership mapper..."
curl -s -f -X POST -H "$AUTH" -H "$CT" \
  "$KC_BASE/admin/realms/lumini/client-scopes/$GROUPS_SCOPE_ID/protocol-mappers/models" -d '{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "consentRequired": false,
  "config": {
    "full.path": "true",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "claim.name": "groups"
  }
}'
echo "    [OK] mapper added"

# ── 5. Create 4 OIDC clients ─────────────────────────────────────────
echo "==> Creating clients..."

create_client() {
  local CLIENT_ID=$1
  local NAME=$2
  local REDIRECT=$3
  local ORIGIN=$4

  curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/clients" -d "{
    \"clientId\": \"$CLIENT_ID\",
    \"name\": \"$NAME\",
    \"enabled\": true,
    \"publicClient\": true,
    \"protocol\": \"openid-connect\",
    \"standardFlowEnabled\": true,
    \"implicitFlowEnabled\": false,
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": false,
    \"frontchannelLogout\": true,
    \"redirectUris\": $REDIRECT,
    \"webOrigins\": $ORIGIN,
    \"attributes\": {
      \"pkce.code.challenge.method\": \"S256\",
      \"post.logout.redirect.uris\": \"+\",
      \"access.token.lifespan\": \"300\"
    }
  }"
  echo "    [OK] $CLIENT_ID"
}

create_client "friopacking-planner-web" "Friopacking Planner" \
  '["https://planner.lumini.dev/*","http://localhost:5173/*"]' \
  '["https://planner.lumini.dev","http://localhost:5173"]'

create_client "friopacking-op-web" "Friopacking Op" \
  '["https://op.lumini.dev/*","http://localhost:5174/*"]' \
  '["https://op.lumini.dev","http://localhost:5174"]'

create_client "crm-web" "CRM" \
  '["https://crm.lumini.dev/*","http://localhost:5175/*"]' \
  '["https://crm.lumini.dev","http://localhost:5175"]'

create_client "hermetica-web" "Hermetica" \
  '["https://hermetica.lumini.dev/*","http://localhost:5176/*"]' \
  '["https://hermetica.lumini.dev","http://localhost:5176"]'

create_client "lumini-audit-dashboard" "Lumini Audit Dashboard" \
  '["http://localhost:8090/*","https://audit.lumini.dev/*"]' \
  '["http://localhost:8090","https://audit.lumini.dev"]'

# ── 6. Add lumini-groups as default scope to each client ──────────────
echo "==> Assigning lumini-groups scope to clients..."
for CID_NAME in friopacking-planner-web friopacking-op-web crm-web hermetica-web lumini-audit-dashboard; do
  CID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=$CID_NAME" \
    | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  curl -s -X PUT -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients/$CID/default-client-scopes/$GROUPS_SCOPE_ID"
  echo "    [OK] $CID_NAME"
done

# ── 7. Create hermetica client roles ──────────────────────────────────
echo "==> Creating hermetica-web client roles..."
HERMETICA_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=hermetica-web" \
  | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

for ROLE in commercial_full_access module_dispatch module_calendar module_dashboard module_commercial module_inventory module_imports module_mrp; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" \
    "$KC_BASE/admin/realms/lumini/clients/$HERMETICA_UUID/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 7b. Create crm-web client roles ─────────────────────────────────
echo "==> Creating crm-web client roles..."
CRM_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=crm-web" \
  | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

for ROLE in crm_admin crm_user project_comercial project_arquitecto project_presupuestor; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" \
    "$KC_BASE/admin/realms/lumini/clients/$CRM_UUID/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 7c. Create friopacking-op-web client roles ──────────────────────
echo "==> Creating friopacking-op-web client roles..."
OP_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=friopacking-op-web" \
  | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

for ROLE in op_admin op_user op_developer; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" \
    "$KC_BASE/admin/realms/lumini/clients/$OP_UUID/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 7d. Create friopacking-planner-web client roles ─────────────────
echo "==> Creating friopacking-planner-web client roles..."
PLANNER_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=friopacking-planner-web" \
  | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

for ROLE in planner_supervisor planner_admin planner_manage_projects; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" \
    "$KC_BASE/admin/realms/lumini/clients/$PLANNER_UUID/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 8. Create group tree ──────────────────────────────────────────────
echo "==> Creating group tree..."

# /PE
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups" \
  -d '{"name": "PE"}'
PE_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups" \
  | $PY -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='PE'][0])")

# /PE/Friopacking
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  -d '{"name": "Friopacking"}'
FRIO_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  | $PY -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='Friopacking'][0])")

# /PE/Friopacking projects: CRM, Operaciones, Planner
for GRP in CRM Operaciones Planner; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$FRIO_ID/children" \
    -d "{\"name\": \"$GRP\"}"
  echo "    [OK] /PE/Friopacking/$GRP"
done

# /PE/Hermetica
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  -d '{"name": "Hermetica"}'
HERM_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  | $PY -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='Hermetica'][0])")

# /PE/Hermetica/Hermetica (the Hermetica project under Hermetica company)
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$HERM_ID/children" \
  -d '{"name": "Hermetica"}'
echo "    [OK] /PE/Hermetica/Hermetica"

echo ""
echo "==> Creating test user..."
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/users" -d '{
  "username": "test@lumini.dev",
  "email": "test@lumini.dev",
  "emailVerified": true,
  "enabled": true,
  "firstName": "Test",
  "lastName": "User",
  "credentials": [{"type": "password", "value": "Saitim1234", "temporary": false}]
}'

# Get user UUID
USER_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/users?email=test@lumini.dev" \
  | $PY -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "    User UUID: $USER_UUID"

# Assign user to /PE/Friopacking/Planner
PLANNER_GRP_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$FRIO_ID/children" \
  | $PY -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='Planner'][0])")
curl -s -X PUT -H "$AUTH" "$KC_BASE/admin/realms/lumini/users/$USER_UUID/groups/$PLANNER_GRP_ID"
echo "    [OK] User added to /PE/Friopacking/Planner"

# Assign ADMIN + DEVELOPER realm roles (DEVELOPER unlocks the audit dashboard)
ADMIN_ROLE=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/roles/ADMIN")
DEVELOPER_ROLE=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/roles/DEVELOPER")
curl -s -f -X POST -H "$AUTH" -H "$CT" \
  "$KC_BASE/admin/realms/lumini/users/$USER_UUID/role-mappings/realm" \
  -d "[$ADMIN_ROLE, $DEVELOPER_ROLE]"
echo "    [OK] ADMIN + DEVELOPER roles assigned"

echo ""
echo "========================================="
echo "  Setup complete! Testing token..."
echo "========================================="
echo ""

# Test: get a token
RESPONSE=$(curl -s -X POST "$KC_BASE/realms/lumini/protocol/openid-connect/token" \
  -d "client_id=friopacking-planner-web" \
  -d "grant_type=password" \
  -d "username=test@lumini.dev" \
  -d "password=Saitim1234")

ACCESS_TOKEN=$(echo "$RESPONSE" | $PY -c "import sys,json; print(json.load(sys.stdin).get('access_token','ERROR'))" 2>/dev/null || echo "ERROR")

if [ "$ACCESS_TOKEN" = "ERROR" ]; then
  echo "[FAIL] Could not get token:"
  echo "$RESPONSE"
  exit 1
fi

echo "[OK] Token obtained. Decoded payload:"
echo "$ACCESS_TOKEN" | $PY -c "
import sys, json, base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
# Fix padding
payload += '=' * (4 - len(payload) % 4)
data = json.loads(base64.urlsafe_b64decode(payload))
for key in ['sub','email','preferred_username','realm_access','groups','scope','azp']:
    if key in data:
        print(f'  {key}: {json.dumps(data[key])}')" 2>&1

echo ""
echo "ACCESS_TOKEN=$ACCESS_TOKEN"
