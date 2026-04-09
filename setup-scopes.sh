#!/usr/bin/env bash
# Configures the friopacking-planner-web client scopes via Keycloak Admin REST API.
# Run this ONCE after Keycloak is up and the lumini realm exists.
#
# Usage:  bash setup-scopes.sh

set -euo pipefail

KC_BASE="http://localhost:8080"
REALM="lumini"
CLIENT_ID_NAME="friopacking-planner-web"
ADMIN_USER="admin"
ADMIN_PASS="admin"

echo "==> Getting admin token..."
TOKEN=$(curl -s -X POST "$KC_BASE/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "grant_type=password" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

AUTH="Authorization: Bearer $TOKEN"

echo "==> Finding client UUID for $CLIENT_ID_NAME..."
CLIENT_UUID=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/$REALM/clients?clientId=$CLIENT_ID_NAME" \
  | python -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "    Client UUID: $CLIENT_UUID"

echo "==> Listing all realm client scopes..."
ALL_SCOPES=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/$REALM/client-scopes")

echo "==> Getting currently assigned default scopes..."
CURRENT=$(curl -s -H "$AUTH" "$KC_BASE/admin/realms/$REALM/clients/$CLIENT_UUID/default-client-scopes")

# Scopes we need as defaults
NEEDED_SCOPES=("openid" "profile" "email" "roles" "web-origins" "lumini-groups")

for SCOPE_NAME in "${NEEDED_SCOPES[@]}"; do
  # Check if already assigned
  ALREADY=$(echo "$CURRENT" | python -c "
import sys, json
scopes = json.load(sys.stdin)
print('yes' if any(s['name'] == '$SCOPE_NAME' for s in scopes) else 'no')
" 2>/dev/null || echo "no")

  if [ "$ALREADY" = "yes" ]; then
    echo "    [OK] $SCOPE_NAME already assigned"
    continue
  fi

  # Find scope UUID
  SCOPE_UUID=$(echo "$ALL_SCOPES" | python -c "
import sys, json
scopes = json.load(sys.stdin)
matches = [s['id'] for s in scopes if s['name'] == '$SCOPE_NAME']
print(matches[0] if matches else '')
" 2>/dev/null || echo "")

  if [ -z "$SCOPE_UUID" ]; then
    echo "    [SKIP] $SCOPE_NAME not found in realm scopes"
    continue
  fi

  echo "    Adding $SCOPE_NAME ($SCOPE_UUID) as default..."
  curl -s -X PUT -H "$AUTH" \
    "$KC_BASE/admin/realms/$REALM/clients/$CLIENT_UUID/default-client-scopes/$SCOPE_UUID"
  echo "    [ADDED] $SCOPE_NAME"
done

echo ""
echo "==> Done! Now request a token and verify it has sub, email, realm_access, groups."
echo "    POST $KC_BASE/realms/$REALM/protocol/openid-connect/token"
echo "    grant_type=password  client_id=$CLIENT_ID_NAME  username=...  password=..."
