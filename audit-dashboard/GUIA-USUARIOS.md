# Guía de gestión de usuarios del Audit Dashboard

Explica cómo conceder, revocar y migrar el acceso al dashboard de auditoría (`lumini-audit-dashboard`) para usuarios existentes y nuevos.

## Concepto en una frase

El dashboard requiere que el JWT emitido por Keycloak contenga en `realm_access.roles` el valor **`SUPER_ADMIN`** o **`DEVELOPER`**. Esto lo valida el permission `IsAuditLogViewer` en [lumini-auth/src/lumini_auth/permissions.py](../../lumini-auth/src/lumini_auth/permissions.py). Todo lo demás (grupo, client roles, rol local del backend) es irrelevante para este endpoint concreto.

Un usuario puede recibir `SUPER_ADMIN`/`DEVELOPER` de dos formas:

1. **Asignación directa** a su cuenta.
2. **Herencia desde un grupo** al que pertenece (el grupo tiene el realm role asignado).

---

## Flujo A — Crear usuario nuevo directamente en Keycloak

Recomendado para cuentas de soporte, auditores externos, personal de TI que no existe en los backends.

1. Abre el Admin Console: `http://localhost:8080` (o el dominio de producción) → login `admin`.
2. Cambia el selector de realm (arriba a la izquierda) de `master` a **`lumini`**.
3. Menú izquierdo → **Users** → botón **Add user**.
   - **Username / Email**: `soporte@lumini.dev`.
   - **Email verified**: ON.
   - **Enabled**: ON.
   - **Create**.
4. Pestaña **Credentials** → **Set password**.
   - Respeta la `passwordPolicy`: mínimo 10 caracteres, 1 dígito, 1 mayúscula, distinta al username, sin reutilizar las últimas 5.
   - **Temporary**: OFF.
   - **Save password**.
5. Pestaña **Role mapping** → **Assign role** → filtra por **Filter by realm roles** → marca **`DEVELOPER`** (o `SUPER_ADMIN`) → **Assign**.
6. (Opcional) Pestaña **Groups** → **Join Group** → elige el grupo corporativo (por ejemplo `/PE/Friopacking/PlannerLima`). Afecta al claim `groups` del token, pero no a la autorización del dashboard.

Listo. Ya puede iniciar sesión en `http://localhost:8090/` (o el dominio prod).

> **Nota**: el usuario **no existe** en ningún backend Django todavía. Se creará automáticamente en la tabla `auth_user` + `keycloak_binding` la primera vez que haga una request autenticada a cualquier backend. Para el dashboard no hace falta que exista previamente — los backends solo validan su JWT y devuelven logs ya persistidos.

---

## Flujo B — Migrar usuarios existentes de un backend Django a Keycloak

Desde el repo del backend que contiene usuarios locales, usa el management command de `lumini-auth`. Conserva el hash de la contraseña, así que el usuario mantiene su contraseña actual.

### planner-backend

```bash
cd /home/vdiaz/lumini/grupoFP/planner-backend
python manage.py migrate_users_to_keycloak --dry-run \
    --role-field rol \
    --role-mapping "SUPER_ADMIN:SUPER_ADMIN,ADMINISTRADOR:ADMIN,SUPERVISOR:SUPERVISOR,DESARROLLADOR:DEVELOPER" \
    --group /PE/Friopacking/PlannerLima
# Si el dry-run se ve correcto, quita --dry-run y vuelve a ejecutarlo.
```

Usuarios con `rol=DESARROLLADOR` o `rol=SUPER_ADMIN` localmente → **recibirán acceso al dashboard** automáticamente.

### crm-backend

```bash
cd /home/vdiaz/lumini/grupoFP/crm-backend/app
python manage.py migrate_users_to_keycloak --dry-run \
    --role-mapping "admin:ADMIN,usuario:USER" \
    --group /PE/Friopacking/CrmComercial
```

Ningún rol local mapea a `DEVELOPER` — si alguien de crm necesita acceso al dashboard, aplícale el Flujo C después de migrar.

### hermetica-backend (usa Django Groups)

```bash
cd /home/vdiaz/lumini/grupoFP/hermetica-backend
python manage.py migrate_users_to_keycloak --dry-run \
    --use-django-groups \
    --group-role-mapping "Full Access:ADMIN,Read Only:USER" \
    --group /PE/Hermetica/ComercialPeru
```

### operaciones-backend

Similar a los anteriores. Ajusta `--role-field` y `--role-mapping` al modelo `User` propio. Ejemplo típico:

```bash
cd /home/vdiaz/lumini/grupoFP/operaciones-backend
python manage.py migrate_users_to_keycloak --dry-run \
    --role-mapping "Administrador:ADMIN,Usuario:USER,Desarrollador:DEVELOPER" \
    --group /PE/Friopacking/OpCallao
```

### Notas sobre el command

- Es **idempotente**: re-ejecutarlo salta usuarios que ya existen en Keycloak (match por email).
- Si un usuario no tiene `rol` en el mapping, por defecto no recibe rol (puedes añadirlo con Flujo C).
- No toca usuarios inactivos (solo `is_active=True`).
- Crea `KeycloakBinding` localmente tras migrar — así en el siguiente login el provisioner los reconoce.

---

## Flujo C — Dar acceso al dashboard a un usuario que YA existe en Keycloak

Dos variantes, elige una.

### C1 — Asignación individual (UI)

1. Admin Console → realm `lumini` → **Users** → busca y abre el usuario.
2. Pestaña **Role mapping** → **Assign role** → filtro **Filter by realm roles** → marca `DEVELOPER` (o `SUPER_ADMIN`) → **Assign**.
3. El usuario debe **cerrar sesión y volver a entrar** al dashboard para que su nuevo JWT incluya el rol (o esperar hasta 5 min al refresh del access token).

### C2 — Asignación por grupo (escalable)

Recomendado si hay muchos usuarios o cambios frecuentes.

1. Admin Console → realm `lumini` → **Groups** → **Create group** → nombre `AuditViewers` (puedes crearlo en la raíz o anidado según convención).
2. Abre el grupo recién creado → pestaña **Role mapping** → **Assign role** → marca `DEVELOPER` → **Assign**.
3. Vuelve a **Users**, abre cada usuario que necesite acceso → pestaña **Groups** → **Join Group** → elige `AuditViewers`.

Todos los miembros del grupo heredan `DEVELOPER`. Para quitar acceso a uno, lo sacas del grupo.

### C3 — Asignación por API (scripting)

Útil para automatizar desde CI/CD o un script de onboarding.

```bash
KC="http://localhost:8080"
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=admin" -d "password=admin" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

USER_UUID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/lumini/users?email=soporte@lumini.dev" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")

DEV_ROLE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/lumini/roles/DEVELOPER")

curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$KC/admin/realms/lumini/users/$USER_UUID/role-mappings/realm" \
  -d "[$DEV_ROLE]"
```

---

## Flujo D — Revocar acceso

- **Individual**: Users → usuario → Role mapping → quita `DEVELOPER`/`SUPER_ADMIN`.
- **En masa**: saca al usuario del grupo que le daba el rol, o quita el role mapping del grupo.
- **Inmediato** (sin esperar al TTL del access token de 5 min): Users → usuario → pestaña **Sessions** → **Logout** → fuerza re-login y el nuevo JWT ya no traerá el rol.

---

## Comprobación rápida: ¿puede este usuario ver el dashboard?

```bash
curl -s -X POST "http://localhost:8080/realms/lumini/protocol/openid-connect/token" \
    -d "client_id=lumini-audit-dashboard" \
    -d "grant_type=password" \
    -d "username=usuario@lumini.dev" \
    -d "password=SuContrasena" | python3 -c "
import sys, json, base64
t = json.load(sys.stdin)['access_token']
p = t.split('.')[1]; p += '=' * (4 - len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
roles = claims.get('realm_access', {}).get('roles', [])
ok = any(r in roles for r in ('SUPER_ADMIN', 'DEVELOPER'))
print(f'realm_access.roles = {roles}')
print('PUEDE ver el dashboard' if ok else 'NO puede (falta SUPER_ADMIN o DEVELOPER)')"
```

---

## Resumen operativo

| Situación                                                  | Flujo                                              |
| ---------------------------------------------------------- | -------------------------------------------------- |
| Crear cuenta nueva de auditor/soporte desde cero           | A                                                  |
| Migrar usuarios por lote desde un backend Django existente | B, luego C para los que necesiten ver el dashboard |
| Un usuario ya existe en Keycloak y necesitas darle acceso  | C1 (pocos) / C2 (muchos) / C3 (scripting)          |
| Equipo grande o rotativo que necesita acceso recurrente    | C2 con grupo dedicado                              |
| Retirar acceso                                             | D                                                  |

---

## Apéndice: ¿por qué solo SUPER_ADMIN y DEVELOPER?

Es la política declarada en [permissions.py](../../lumini-auth/src/lumini_auth/permissions.py) → clase `IsAuditLogViewer`. Los audit-logs contienen payloads de escritura (redactados, pero aun así sensibles), IPs, emails y rutas — información que no debería ser visible a todos los `ADMIN` de cada realm por separado. Si en el futuro se necesita ampliar el acceso, se edita el `check()` de esa clase y se publica una nueva versión de `lumini-auth`.
