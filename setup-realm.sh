#!/usr/bin/env bash
# Creates the lumini realm from scratch via the Keycloak Admin REST API.
# A fresh realm gets all built-in scopes (openid, profile, email, roles, etc.)
# Then we add our custom clients, roles, groups, and the lumini-groups scope.
#
# Usage:  bash setup-realm.sh

set -euo pipefail

KC_BASE="http://localhost:8080"
ADMIN_USER="admin"
ADMIN_PASS="admin"

# ── Helper ────────────────────────────────────────────────────────────
get_token() {
  curl -s -X POST "$KC_BASE/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "grant_type=password" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
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
  | python -c "import sys,json; scopes=json.load(sys.stdin); print([s['id'] for s in scopes if s['name']=='lumini-groups'][0])")
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

# ── 6. Add lumini-groups as default scope to each client ──────────────
echo "==> Assigning lumini-groups scope to clients..."
for CID_NAME in friopacking-planner-web friopacking-op-web crm-web hermetica-web; do
  CID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=$CID_NAME" \
    | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  curl -s -X PUT -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients/$CID/default-client-scopes/$GROUPS_SCOPE_ID"
  echo "    [OK] $CID_NAME"
done

# ── 7. Create hermetica client roles ──────────────────────────────────
echo "==> Creating hermetica-web client roles..."
HERMETICA_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/clients?clientId=hermetica-web" \
  | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

for ROLE in commercial_full_access module_dispatch module_calendar module_dashboard module_commercial module_inventory module_imports module_mrp; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" \
    "$KC_BASE/admin/realms/lumini/clients/$HERMETICA_UUID/roles" \
    -d "{\"name\": \"$ROLE\"}"
  echo "    [OK] $ROLE"
done

# ── 8. Create group tree ──────────────────────────────────────────────
echo "==> Creating group tree..."

# /PE
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups" \
  -d '{"name": "PE"}'
PE_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups" \
  | python -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='PE'][0])")

# /PE/Friopacking
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  -d '{"name": "Friopacking"}'
FRIO_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  | python -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='Friopacking'][0])")

# /PE/Friopacking/PlannerLima, OpCallao, CrmComercial
for GRP in PlannerLima OpCallao CrmComercial; do
  curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$FRIO_ID/children" \
    -d "{\"name\": \"$GRP\"}"
  echo "    [OK] /PE/Friopacking/$GRP"
done

# /PE/Hermetica
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  -d '{"name": "Hermetica"}'
HERM_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$PE_ID/children" \
  | python -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='Hermetica'][0])")

# /PE/Hermetica/ComercialPeru
curl -s -f -X POST -H "$AUTH" -H "$CT" "$KC_BASE/admin/realms/lumini/groups/$HERM_ID/children" \
  -d '{"name": "ComercialPeru"}'
echo "    [OK] /PE/Hermetica/ComercialPeru"

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
  | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "    User UUID: $USER_UUID"

# Assign user to /PE/Friopacking/PlannerLima
PLANNER_GRP_ID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/groups/$FRIO_ID/children" \
  | python -c "import sys,json; print([g['id'] for g in json.load(sys.stdin) if g['name']=='PlannerLima'][0])")
curl -s -X PUT -H "$AUTH" "$KC_BASE/admin/realms/lumini/users/$USER_UUID/groups/$PLANNER_GRP_ID"
echo "    [OK] User added to /PE/Friopacking/PlannerLima"

# Assign ADMIN realm role
ADMIN_ROLE=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/lumini/roles/ADMIN")
curl -s -f -X POST -H "$AUTH" -H "$CT" \
  "$KC_BASE/admin/realms/lumini/users/$USER_UUID/role-mappings/realm" \
  -d "[$ADMIN_ROLE]"
echo "    [OK] ADMIN role assigned"

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

ACCESS_TOKEN=$(echo "$RESPONSE" | python -c "import sys,json; print(json.load(sys.stdin).get('access_token','ERROR'))" 2>/dev/null || echo "ERROR")

if [ "$ACCESS_TOKEN" = "ERROR" ]; then
  echo "[FAIL] Could not get token:"
  echo "$RESPONSE"
  exit 1
fi

echo "[OK] Token obtained. Decoded payload:"
echo "$ACCESS_TOKEN" | python -c "
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
