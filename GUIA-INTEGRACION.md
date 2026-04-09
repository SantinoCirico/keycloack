# Guia de Integracion Keycloak para Backends Django + DRF

Guia paso a paso para integrar Keycloak como proveedor de identidad en un backend Django + Django REST Framework que actualmente usa autenticacion propia (simplejwt, authtoken, o similar).

Basada en la integracion real del sistema Friopacking Planner. Documenta los problemas encontrados y sus soluciones.

---

## Indice

1. [Arquitectura general](#1-arquitectura-general)
2. [Prerequisitos](#2-prerequisitos)
3. [Paso 1 — Levantar Keycloak](#3-paso-1--levantar-keycloak)
4. [Paso 2 — Configurar el realm via API](#4-paso-2--configurar-el-realm-via-api)
5. [Paso 3 — Instalar lumini-auth en el backend](#5-paso-3--instalar-lumini-auth-en-el-backend)
6. [Paso 4 — Configurar settings.py](#6-paso-4--configurar-settingspy)
7. [Paso 5 — Crear el modulo de dual-auth](#7-paso-5--crear-el-modulo-de-dual-auth)
8. [Paso 6 — Registrar endpoint de debug](#8-paso-6--registrar-endpoint-de-debug)
9. [Paso 7 — Migrar y probar](#9-paso-7--migrar-y-probar)
10. [Paso 8 — Probar con Postman](#10-paso-8--probar-con-postman)
11. [Problemas conocidos y soluciones](#11-problemas-conocidos-y-soluciones)
12. [Provisioner custom (si tu User tiene campos extra)](#12-provisioner-custom)
13. [Limpieza post-migracion](#13-limpieza-post-migracion)
14. [Referencia: claims del token Keycloak](#14-referencia-claims-del-token-keycloak)

---

## 1. Arquitectura general

```
                    ┌──────────────────┐
                    │    Keycloak      │
                    │  realm: lumini   │
                    │  (puerto 8080)   │
                    └────────┬─────────┘
                             │ OIDC (JWT firmado con RS256)
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
   │  Backend A  │   │  Backend B  │   │  Backend C  │
   │  Django+DRF │   │  Django+DRF │   │  Django+DRF │
   │  +lumini-auth│  │  +lumini-auth│  │  +lumini-auth│
   └─────────────┘   └─────────────┘   └─────────────┘
```

- Cada backend valida el JWT contra el JWKS de Keycloak (no necesita client secret)
- Un usuario que inicia sesion en un frontend puede usar el mismo token en cualquier backend
- Los usuarios locales de Django se crean automaticamente la primera vez (shadow users via KeycloakBinding)
- Las FKs existentes (audit logs, created_by, etc.) siguen funcionando

---

## 2. Prerequisitos

- Python 3.10+
- Django 4.2+ con Django REST Framework 3.14+
- Docker y Docker Compose
- Git Bash, WSL, o cualquier terminal con bash y curl
- El paquete `lumini-auth` (en la carpeta `lumini-auth/` del monorepo)

---

## 3. Paso 1 — Levantar Keycloak

```bash
cd keycloak/

# Crear .env si no existe
cp .env.example .env
# Editar con credenciales (default: admin/admin)

# Levantar Keycloak + Postgres
docker compose up -d
```

Esperar ~30 segundos. Verificar que responda:

```bash
curl -s http://localhost:8080/realms/master
```

> **IMPORTANTE**: Keycloak corre en el puerto 8080. Si ya tienes algo ahi, cambia el puerto en `docker-compose.yml`.

---

## 4. Paso 2 — Configurar el realm via API

> **NO usar `--import-realm` con realm-export.json**. El import de Keycloak 26 no crea los scopes built-in (openid, profile, email, roles, web-origins) cuando se importa un realm desde archivo. Esto causa que los tokens no tengan `sub`, `email`, ni `realm_access`. Ver seccion [Problemas conocidos](#11-problemas-conocidos-y-soluciones).

Usar el script que crea todo via la Admin REST API:

```bash
bash setup-realm.sh
```

El script:
1. Borra el realm `lumini` si existe
2. Crea uno nuevo (Keycloak genera automaticamente los scopes built-in)
3. Crea los realm roles (SUPER_ADMIN, ADMIN, SUPERVISOR, USER, DEVELOPER)
4. Crea el scope custom `lumini-groups` con el mapper de grupo
5. Crea los 4 clientes OIDC con PKCE
6. Asigna `lumini-groups` como default scope a cada cliente
7. Crea los client roles de hermetica
8. Crea el arbol de grupos (/PE/Friopacking/..., /PE/Hermetica/...)
9. Crea un usuario de prueba y obtiene un token para verificar

Al final del script ves el token decodificado. Debe mostrar:

```
sub: "a3318245-..."
email: "test@lumini.dev"
realm_access: {"roles": ["ADMIN", ...]}
groups: ["/PE/Friopacking/PlannerLima"]
scope: "email lumini-groups profile"
```

Si ves esos campos, Keycloak esta listo.

---

## 5. Paso 3 — Instalar lumini-auth en el backend

Desde la carpeta de tu backend:

```bash
# Activar el venv
source venv/bin/activate  # o venv\Scripts\activate en Windows

# Instalar el paquete compartido (editable, para desarrollo)
pip install -e ../../lumini-auth
```

O agregar al `requirements.txt`:

```
# Keycloak shared auth package
-e ../../lumini-auth
```

> Ajustar la ruta relativa segun la ubicacion de tu backend respecto a `lumini-auth/`.

---

## 6. Paso 4 — Configurar settings.py

### 6.1 Agregar lumini_auth a INSTALLED_APPS

```python
INSTALLED_APPS = [
    # ... django apps ...
    # Third-party
    "rest_framework",
    "rest_framework_simplejwt",           # mantener durante la migracion
    "rest_framework_simplejwt.token_blacklist",  # si lo usas
    "lumini_auth",                         # <-- AGREGAR
    # Local apps
    "tu_app.apps.TuAppConfig",
]
```

### 6.2 Configurar REST_FRAMEWORK con dual-auth

Reemplazar el bloque existente:

```python
# --- Django Rest Framework (DRF) ---
# Dual-auth: Keycloak primero, simplejwt como fallback.
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "tu_app.keycloak.DualAuthKeycloakJWT",
        "tu_app.keycloak.DualAuthSimpleJWT",
    ),
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.IsAuthenticated",),
}
```

> **IMPORTANTE**: Usar los wrappers Dual*, NO las clases directas. Ver seccion [Problemas conocidos](#11-problemas-conocidos-y-soluciones) para entender por que.

### 6.3 Agregar configuracion de Keycloak

Despues del bloque REST_FRAMEWORK:

```python
# --- Keycloak (OIDC) ---
_keycloak_url = env("KEYCLOAK_BASE_URL", default="")
if _keycloak_url:
    from lumini_auth.config import configure_keycloak

    configure_keycloak(
        globals(),
        base_url=_keycloak_url,
        realm=env("KEYCLOAK_REALM", default="lumini"),
        client_id=env("KEYCLOAK_CLIENT_ID", default="tu-client-id-web"),
        configure_drf=False,  # ya lo configuramos arriba con dual-auth
    )

    # Opcional: provisioner custom si tu User tiene campos extra
    # LUMINI_KEYCLOAK_PROVISIONER = "tu_app.keycloak.provision_custom_user"
```

> Si `KEYCLOAK_BASE_URL` esta vacio, Keycloak queda desactivado y todo funciona solo con simplejwt.

### 6.4 Agregar variables al .env

```env
KEYCLOAK_BASE_URL=http://localhost:8080
KEYCLOAK_REALM=lumini
KEYCLOAK_CLIENT_ID=tu-client-id-web
```

---

## 7. Paso 5 — Crear el modulo de dual-auth

Crear un archivo `tu_app/keycloak.py` (donde `tu_app` es tu app de autenticacion, ej: `security`, `accounts`):

```python
"""Dual-auth: Keycloak + simplejwt durante la ventana de migracion."""

from __future__ import annotations

import logging

from rest_framework_simplejwt.authentication import JWTAuthentication
from lumini_auth.authentication import KeycloakJWTAuthentication

logger = logging.getLogger(__name__)


class DualAuthKeycloakJWT(KeycloakJWTAuthentication):
    """Valida tokens Keycloak. Si falla, deja pasar al siguiente auth."""

    def authenticate(self, request):
        try:
            result = super().authenticate(request)
            logger.info("keycloak auth OK for %s", request.path)
            return result
        except Exception as exc:
            logger.warning("keycloak auth failed: %s", exc)
            return None


class DualAuthSimpleJWT(JWTAuthentication):
    """Valida tokens simplejwt legacy. Si falla, deja pasar al siguiente."""

    def authenticate(self, request):
        try:
            result = super().authenticate(request)
            logger.info("simplejwt auth OK for %s", request.path)
            return result
        except Exception as exc:
            logger.warning("simplejwt auth failed: %s", exc)
            return None
```

> **CRITICO**: Este archivo NO debe importar `rest_framework.views.APIView` ni nada de `rest_framework` que no sea authentication. DRF importa las clases de `DEFAULT_AUTHENTICATION_CLASSES` durante su inicializacion, y si esas clases importan `rest_framework.views`, se produce un **import circular** que crashea Django al arrancar. Ver seccion [Problemas conocidos](#11-problemas-conocidos-y-soluciones).

---

## 8. Paso 6 — Registrar endpoint de debug

En tu `views.py` (donde ya se importa APIView sin problema):

```python
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated


class KeycloakDebugView(APIView):
    """Temporal: muestra el metodo de auth y los claims Keycloak. BORRAR antes de prod."""

    permission_classes = (IsAuthenticated,)

    def get(self, request):
        claims = getattr(request, "keycloak_claims", None)
        return Response({
            "auth_method": "keycloak" if claims else "simplejwt",
            "user_id": request.user.pk,
            "email": getattr(request.user, "email", None),
            "keycloak_claims": claims,
        })
```

En tu `urls.py`:

```python
from .views import KeycloakDebugView

urlpatterns = [
    # ... tus rutas existentes ...
    path("keycloak-debug/", KeycloakDebugView.as_view(), name="keycloak_debug"),
]
```

---

## 9. Paso 7 — Migrar y probar

```bash
# Crear tablas de lumini_auth (KeycloakBinding + AuditLog)
python manage.py migrate lumini_auth

# Iniciar el servidor
python manage.py runserver
```

Probar con curl:

```bash
# 1. Obtener token de Keycloak
TOKEN=$(curl -s -X POST http://localhost:8080/realms/lumini/protocol/openid-connect/token \
  -d "grant_type=password" \
  -d "client_id=tu-client-id-web" \
  -d "username=test@lumini.dev" \
  -d "password=Saitim1234" | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. Probar contra el backend
curl -s http://localhost:8000/api/v1/auth/keycloak-debug/ \
  -H "Authorization: Bearer $TOKEN"
```

Respuesta esperada:

```json
{
  "auth_method": "keycloak",
  "user_id": 2,
  "email": "test@lumini.dev",
  "keycloak_claims": {
    "sub": "a3318245-...",
    "groups": ["/PE/Friopacking/PlannerLima"],
    "realm_access": {"roles": ["ADMIN"]},
    "email": "test@lumini.dev"
  }
}
```

Verificar que el auth legacy sigue funcionando:

```bash
# Login con simplejwt
LEGACY=$(curl -s -X POST http://localhost:8000/api/v1/auth/login/ \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"tu-password"}' \
  | python -c "import sys,json; print(json.load(sys.stdin)['access'])")

curl -s http://localhost:8000/api/v1/auth/keycloak-debug/ \
  -H "Authorization: Bearer $LEGACY"
```

Debe mostrar `"auth_method": "simplejwt"`.

---

## 10. Paso 8 — Probar con Postman

### Obtener token de Keycloak

1. **POST** `http://localhost:8080/realms/lumini/protocol/openid-connect/token`
2. Body → **x-www-form-urlencoded** (NO raw/json, Keycloak no acepta JSON en el token endpoint):

| Key          | Value                 |
|--------------|-----------------------|
| grant_type   | password              |
| client_id    | tu-client-id-web      |
| username     | test@lumini.dev       |
| password     | Saitim1234            |

3. Copiar `access_token` del response.

### Usar el token

1. En el request al backend, ir a la pestana **Authorization**
2. Type: **Bearer Token**
3. Pegar el token (sin la palabra "Bearer")

> **NO usar la pestana Headers manualmente**. Postman a veces no envia el header Authorization si se agrega manualmente. Usar siempre la pestana Authorization con tipo Bearer Token.

---

## 11. Problemas conocidos y soluciones

### realm-export.json no crea scopes built-in

**Problema**: Keycloak 26 con `--import-realm` crea el realm pero NO genera los scopes OIDC estandar (openid, profile, email, roles, web-origins) si el archivo JSON tiene un `clientScopes` parcial. Los tokens resultantes no contienen `sub`, `email`, ni `realm_access`.

**Sintoma**: El token decodificado solo muestra `"scope": "lumini-groups"` sin claims de identidad.

**Solucion**: NO usar `--import-realm`. Crear el realm via la Admin REST API con `setup-realm.sh`. Un realm creado por API recibe automaticamente todos los scopes built-in.

---

### Import circular con rest_framework.views

**Problema**: Si el archivo que contiene las clases de `DEFAULT_AUTHENTICATION_CLASSES` importa `rest_framework.views.APIView` a nivel de modulo, Django crashea al arrancar con:

```
ImportError: cannot import name 'APIView' from partially initialized module
'rest_framework.views' (most likely due to a circular import)
```

Esto pasa porque DRF importa las auth classes durante su propia inicializacion, y si esas clases re-importan DRF, se forma un ciclo.

**Solucion**: El archivo `keycloak.py` (que tiene las clases DualAuth*) solo debe importar `rest_framework_simplejwt.authentication` y `lumini_auth.authentication`. Cualquier view (como KeycloakDebugView) va en `views.py`, que se importa despues de que DRF ya esta inicializado.

---

### DRF corta la cadena de auth al primer error

**Problema**: Si usas `KeycloakJWTAuthentication` y `JWTAuthentication` directamente en `DEFAULT_AUTHENTICATION_CLASSES`, DRF se detiene en el primer `AuthenticationFailed`. Si llega un token simplejwt, Keycloak lo rechaza con excepcion, y DRF nunca prueba simplejwt. Resultado: `401 Unauthorized` para tokens legacy.

**Solucion**: Usar las clases wrapper `DualAuthKeycloakJWT` y `DualAuthSimpleJWT` que capturan excepciones y retornan `None`. DRF interpreta `None` como "este auth no aplica, probar el siguiente".

```
Request → DualAuthKeycloakJWT → falla? return None
                                        ↓
         DualAuthSimpleJWT   → falla? return None
                                        ↓
         401 Unauthorized (ningun auth funciono)
```

---

### Token de Keycloak no tiene sub

**Problema**: El scope `openid` no esta asignado como default scope del cliente. Sin `openid`, Keycloak emite un token OAuth2 puro (sin claims OIDC como `sub`, `email`, `preferred_username`).

**Sintoma**: `Token is missing the "sub" claim` en los logs del backend.

**Solucion**: Verificar que el cliente tenga `openid` como default scope. Si usas `setup-realm.sh`, esto se configura automaticamente. Si necesitas verificar manualmente:

```bash
# Obtener admin token
TOKEN=$(curl -s -X POST http://localhost:8080/realms/master/protocol/openid-connect/token \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=admin" -d "password=admin" \
  | python -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Listar scopes del realm
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/admin/realms/lumini/client-scopes \
  | python -c "import sys,json; [print(s['name']) for s in json.load(sys.stdin)]"
```

Deberias ver: `openid`, `profile`, `email`, `roles`, `web-origins`, `lumini-groups`, etc.

---

### Postman no envia el header Authorization

**Problema**: Al agregar `Authorization: Bearer ...` en la pestana Headers de Postman, a veces el header no se envia realmente.

**Solucion**: Usar la pestana **Authorization** → Type **Bearer Token** → pegar solo el token. O probar con curl para descartar problemas de Postman:

```bash
curl -v http://localhost:8000/tu-endpoint/ \
  -H "Authorization: Bearer TU_TOKEN_AQUI"
```

El flag `-v` muestra los headers enviados para confirmar.

---

## 12. Provisioner custom

Si tu modelo User tiene campos extra que quieras sincronizar desde Keycloak (como un campo `rol`, `team`, `department`, etc.), crea un provisioner custom.

Ejemplo para un backend que tiene `User.rol` con choices:

```python
# tu_app/keycloak.py (agregar al archivo existente)

from typing import Any

# Mapeo: Keycloak realm role → tu campo User.rol
_ROLE_MAP = {
    "SUPER_ADMIN": "SUPER_ADMIN",
    "DEVELOPER":   "DESARROLLADOR",
    "ADMIN":       "ADMINISTRADOR",
    "SUPERVISOR":  "SUPERVISOR",
}
_ROLE_PRIORITY = ("SUPER_ADMIN", "DEVELOPER", "ADMIN", "SUPERVISOR")
_DEFAULT_ROL = "SUPERVISOR"


def provision_custom_user(claims: dict[str, Any]):
    from lumini_auth.authentication import default_provision_user

    # Paso 1: crear/buscar el usuario (logica estandar)
    user = default_provision_user(claims)

    # Paso 2: sincronizar campo custom desde claims
    realm_roles = set((claims.get("realm_access") or {}).get("roles") or [])
    new_rol = _DEFAULT_ROL
    for kc_role in _ROLE_PRIORITY:
        if kc_role in realm_roles:
            new_rol = _ROLE_MAP[kc_role]
            break

    if user.rol != new_rol:
        user.rol = new_rol
        user.save(update_fields=["rol"])

    return user
```

Registrar en settings.py:

```python
LUMINI_KEYCLOAK_PROVISIONER = "tu_app.keycloak.provision_custom_user"
```

Si tu User no tiene campos custom, no necesitas provisioner. El default crea el usuario con email, first_name, last_name y password inutilizable.

---

## 13. Limpieza post-migracion

Cuando todos los usuarios esten en Keycloak y ya no se usen tokens simplejwt:

### settings.py

```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "lumini_auth.authentication.KeycloakJWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": ("rest_framework.permissions.IsAuthenticated",),
}
```

### INSTALLED_APPS

Quitar:
```python
"rest_framework_simplejwt",
"rest_framework_simplejwt.token_blacklist",
```

### requirements.txt

Quitar:
```
djangorestframework_simplejwt==X.X.X
```

### Codigo

- Borrar `DualAuthSimpleJWT` y `DualAuthKeycloakJWT` de `keycloak.py`
- Borrar rutas de login/register/refresh/logout (Keycloak los maneja)
- Borrar `KeycloakDebugView`
- Borrar serializers de token (CustomTokenObtainPairSerializer, etc.)

---

## 14. Referencia: claims del token Keycloak

Token de ejemplo decodificado:

```json
{
  "exp": 1775757978,
  "iat": 1775757678,
  "iss": "http://localhost:8080/realms/lumini",
  "sub": "a3318245-2a74-4372-8d40-bb1ed31f8319",
  "typ": "Bearer",
  "azp": "friopacking-planner-web",
  "scope": "email lumini-groups profile",
  "email": "test@lumini.dev",
  "email_verified": true,
  "name": "Test User",
  "given_name": "Test",
  "family_name": "User",
  "preferred_username": "test@lumini.dev",
  "groups": ["/PE/Friopacking/PlannerLima"],
  "realm_access": {
    "roles": ["default-roles-lumini", "ADMIN"]
  },
  "resource_access": {
    "account": {
      "roles": ["manage-account", "view-profile"]
    }
  }
}
```

### Como leer los claims desde codigo Django

```python
# En cualquier view
def get(self, request):
    claims = getattr(request, "keycloak_claims", None)
    if claims:
        # Claims disponibles:
        sub = claims["sub"]                           # UUID del usuario en Keycloak
        email = claims["email"]                       # Email
        groups = claims.get("groups", [])             # ["/PE/Friopacking/PlannerLima"]
        realm_roles = claims["realm_access"]["roles"] # ["ADMIN", ...]

# Usando los helpers de lumini_auth
from lumini_auth.permissions import has_realm_role, in_any_subgroup
from lumini_auth.groups import parse_group_path

has_realm_role(request, "ADMIN")           # True/False
in_any_subgroup(request, "/PE/")           # True si esta en algun grupo de Peru
parse_group_path("/PE/Friopacking/PlannerLima")
# → {"country": "PE", "company": "Friopacking", "project": "PlannerLima"}
```

### Permission classes disponibles

```python
from lumini_auth.permissions import (
    IsRealmAdmin,              # Requiere realm role ADMIN
    IsRealmSuperAdmin,         # Requiere realm role SUPER_ADMIN
    HasRealmRole,              # Factory: HasRealmRole("SUPERVISOR")
    HasClientRole,             # Factory: HasClientRole("hermetica-web", "module_calendar")
    InGroupSubtree,            # Factory: InGroupSubtree("/PE/Friopacking/")
)

class MiVista(APIView):
    permission_classes = [IsRealmAdmin]
    # ...

class VistaHermetica(APIView):
    permission_classes = [HasClientRole("hermetica-web", "module_calendar")]
    # ...
```
