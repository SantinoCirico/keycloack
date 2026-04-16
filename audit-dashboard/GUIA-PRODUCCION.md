# Guía de despliegue del Audit Dashboard a producción

Paso a paso para migrar el dashboard y sus 4 endpoints de backend desde `http://localhost:*` a los dominios reales de producción.

## Mapa de URLs: local → producción

| Componente          | Local (actual)          | Producción (ejemplo)                                                      |
| ------------------- | ----------------------- | ------------------------------------------------------------------------- |
| Keycloak            | `http://localhost:8080` | `https://auth.lumini.dev`                                                 |
| Dashboard           | `http://localhost:8090` | `https://audit.lumini.dev`                                                |
| planner-backend     | `http://localhost:8001` | `https://planner-backend.lumini.dev`                                      |
| crm-backend         | `http://localhost:8002` | `https://crm-backend.lumini.dev`                                          |
| hermetica-backend   | `http://localhost:8003` | `https://lu-hermetica-comercial-webapp-1030749271093.us-central1.run.app` |
| operaciones-backend | `http://localhost:8004` | `https://friopacking-backend-337748371520.us-central1.run.app`            |

Ajusta los dominios de la columna "Producción" a los que realmente uses. Los que aparecen son los que ya están referenciados en los `settings.py` y en `realm-export.json`.

---

## Paso 0 — Prerrequisitos

- DNS: registros A/CNAME apuntando `audit.lumini.dev` al proveedor de hosting elegido (Cloud Run, GKE, GCS+CDN, VM, etc.).
- Certificados TLS: gestionados por el proveedor (Cloud Run emite automático), por Cert-Manager (GKE) o por Let's Encrypt manual (VM con Nginx).
- Acceso al realm `lumini` de Keycloak en producción con credenciales de admin.
- Pipelines de CI/CD de los 4 backends listos para aceptar una nueva versión de `lumini-auth` (v0.4.0).

---

## Paso 1 — Configuración runtime del dashboard (`config.js`)

El archivo [keycloack/audit-dashboard/config.js](./config.js) se sirve con `Cache-Control: no-store` (ver [nginx.conf](./nginx.conf)). Esto significa que puedes sustituirlo en el servidor y el próximo request del usuario lo recoge sin rebuild ni redeploy del resto de la aplicación.

Para producción, reemplaza su contenido por:

```js
window.LUMINI_CONFIG = {
  kcUrl: "https://auth.lumini.dev",
  realm: "lumini",
  clientId: "lumini-audit-dashboard",
  backends: [
    {
      key: "planner",
      baseUrl: "https://planner-backend.lumini.dev",
      label: "Planner",
    },
    { key: "crm", baseUrl: "https://crm-backend.lumini.dev", label: "CRM" },
    {
      key: "hermetica",
      baseUrl:
        "https://lu-hermetica-comercial-webapp-1030749271093.us-central1.run.app",
      label: "Hermetica",
    },
    {
      key: "operaciones",
      baseUrl: "https://friopacking-backend-337748371520.us-central1.run.app",
      label: "Operaciones",
    },
  ],
};
```

Estrategia recomendada: **no commitear** `config.js` de producción en el repo. En su lugar, genera dos variantes:

- `config.local.js` (la que hoy tienes, para dev).
- `config.prod.js` (URLs de producción).

Tu pipeline de build copia la adecuada a `config.js` antes de empacar la imagen. Ejemplo en Dockerfile:

```Dockerfile
FROM nginx:1.27-alpine
COPY keycloack/audit-dashboard/ /usr/share/nginx/html/
COPY keycloack/audit-dashboard/nginx.conf /etc/nginx/conf.d/default.conf
ARG ENV=prod
RUN cp /usr/share/nginx/html/config.${ENV}.js /usr/share/nginx/html/config.js
```

---

## Paso 2 — Actualizar cliente OIDC `lumini-audit-dashboard` en Keycloak

El cliente ya trae los valores de producción en [realm-export.json](../realm-export.json) (`https://audit.lumini.dev/*` en `redirectUris` y `webOrigins`). Si tu realm de producción fue creado desde ese export, **no hay que hacer nada**.

Si ya existe y está desalineado, corrígelo:

1. Admin Console → realm `lumini` → **Clients** → abre `lumini-audit-dashboard`.
2. **Valid redirect URIs**: asegúrate de tener `https://audit.lumini.dev/*`. Si el dashboard dev coexiste, mantén también `http://localhost:8090/*`.
3. **Valid post logout redirect URIs**: `+` (inherit) o explícitamente `https://audit.lumini.dev/*`.
4. **Web origins**: `https://audit.lumini.dev` (sin wildcard).
5. **Save**.

> Si tienes más de un entorno (staging, prod), crea un cliente por entorno: `lumini-audit-dashboard-staging` y `lumini-audit-dashboard`. Añade cada `clientId` a `DEFAULT_AUDIENCE_ALLOWLIST` en [config.py](../../lumini-auth/src/lumini_auth/config.py) y publica la nueva versión de `lumini-auth`.

---

## Paso 3 — Ajustar `KEYCLOAK_BASE_URL` en los 4 backends

Cada backend lee `KEYCLOAK_BASE_URL` del entorno (ver `configure_keycloak(...)` en sus `settings.py`). En producción cambia el valor vía variables de entorno del servicio:

| Backend             | Variable            | Valor prod                |
| ------------------- | ------------------- | ------------------------- |
| planner-backend     | `KEYCLOAK_BASE_URL` | `https://auth.lumini.dev` |
| crm-backend         | `KEYCLOAK_BASE_URL` | `https://auth.lumini.dev` |
| hermetica-backend   | `KEYCLOAK_BASE_URL` | `https://auth.lumini.dev` |
| operaciones-backend | `KEYCLOAK_BASE_URL` | `https://auth.lumini.dev` |

También `KEYCLOAK_REALM=lumini` (ya es el default) y `KEYCLOAK_CLIENT_ID=<su_cliente_backend>` (ya lo tienen configurado).

No hace falta cambiar código — `configure_keycloak()` deriva `issuer`, `JWKS_ENDPOINT`, etc. a partir de `KEYCLOAK_BASE_URL`.

---

## Paso 4 — Ajustar CORS en los 4 backends

### planner-backend

[planner-backend/core/settings.py](../../planner-backend/core/settings.py) lee `CORS_ALLOWED_ORIGINS` de `.env` (CSV). En la pipeline de producción, asegúrate de que la variable incluya `https://audit.lumini.dev`. Además, un `for _origin ...` defensivo en el código ya añade `https://audit.lumini.dev` aunque el env no lo liste. No requiere cambios de código; sí un redeploy tras aplicar lumini-auth 0.4.0.

### operaciones-backend

[operaciones-backend/friopacking/settings.py](../../operaciones-backend/friopacking/settings.py) tiene el mismo patch defensivo. Si además usas `CORS_ALLOWED_ORIGINS` como env var en Cloud Run, añade `https://audit.lumini.dev` a la lista.

### crm-backend y hermetica-backend

Tienen `CORS_ALLOWED_ORIGINS` hardcodeado con `https://audit.lumini.dev` ya incluido. No hace falta cambiar nada — basta con el redeploy.

### CSRF

El dashboard autentica con `Authorization: Bearer` (no cookies) → CSRF no aplica al endpoint `/api/v1/audit/logs/`. No es necesario añadir `audit.lumini.dev` a `CSRF_TRUSTED_ORIGINS`, pero hacerlo no hace daño por si en el futuro hay formularios.

---

## Paso 5 — Publicar `lumini-auth` v0.4.0 en los 4 backends

Opciones según tu workflow:

### 5a. Si instalas desde path local (`file:../lumini-auth`)

Empaqueta `lumini-auth` junto al código del backend en la imagen Docker. Cada `pip install -e ../lumini-auth` se resuelve en el build.

### 5b. Si publicas a un registro interno (recomendado para producción)

```bash
cd /home/vdiaz/lumini/grupoFP/lumini-auth
python -m build
# El wheel queda en dist/lumini_auth-0.4.0-py3-none-any.whl
# Publícalo en tu PyPI interno (GCP Artifact Registry, Nexus, JFrog, etc.)
```

Actualiza cada `requirements.txt` a `lumini-auth==0.4.0` y redeploya.

### 5c. Verificar tras el deploy

Por cada backend de producción:

```bash
curl -s "https://planner-backend.lumini.dev/api/v1/audit/logs/" -i | head -n 5
# Sin token debe responder 401 con:
#   HTTP/2 401
#   www-authenticate: Bearer realm="api"
```

Un `404` aquí significa que el `include("lumini_auth.urls")` del `urls.py` no se aplicó — revisa el deploy.

---

## Paso 6 — Habilitar TLS estricto en Keycloak

En [realm-export.json](../realm-export.json) el realm tiene `"sslRequired": "none"` (útil para dev). **En producción cambia a `external`**:

```bash
KC="https://auth.lumini.dev"
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=$ADMIN" -d "password=$ADMIN_PASS" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$KC/admin/realms/lumini" -d '{"sslRequired":"external"}'
```

`external` = acepta HTTP solo en red privada (localhost interno para healthchecks); forza HTTPS desde cualquier otro origen.

---

## Paso 7 — Desplegar el dashboard Nginx

Tres opciones según infraestructura. Elige la más cercana a tu stack actual.

### Opción 7a — Cloud Run (si ya usas GCP)

Crea el Dockerfile en `keycloack/audit-dashboard/Dockerfile`:

```Dockerfile
FROM nginx:1.27-alpine
COPY . /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN rm /usr/share/nginx/html/Dockerfile /usr/share/nginx/html/nginx.conf /usr/share/nginx/html/GUIA-*.md
# (ajusta la copia para no incluir archivos innecesarios)
EXPOSE 80
```

Build & deploy:

```bash
cd keycloack/audit-dashboard
gcloud builds submit --tag gcr.io/$PROJECT/lumini-audit-dashboard:0.4.0 .
gcloud run deploy lumini-audit-dashboard \
  --image gcr.io/$PROJECT/lumini-audit-dashboard:0.4.0 \
  --region us-central1 \
  --allow-unauthenticated \
  --port 80
# Mapea el dominio:
gcloud run domain-mappings create --service lumini-audit-dashboard --domain audit.lumini.dev --region us-central1
```

### Opción 7b — GCS bucket + Cloud CDN

```bash
gsutil mb -p $PROJECT -l us-central1 gs://lumini-audit-dashboard
gsutil cp -r keycloack/audit-dashboard/* gs://lumini-audit-dashboard/
gsutil web set -m index.html -e index.html gs://lumini-audit-dashboard
# Crea el load balancer con Cloud CDN delante (vía UI o gcloud).
```

En esta opción el `nginx.conf` **no aplica** — el bucket no ejecuta Nginx. Tienes que configurar:

- Metadata `Cache-Control: no-store` en `config.js` manualmente (`gsutil setmeta`).
- Un rewrite rule en el load balancer para que cualquier path desconocido sirva `/index.html`.

### Opción 7c — Docker Compose en VM

Igual que local: la VM corre `docker compose up -d` con el mismo [docker-compose.yml](../docker-compose.yml). El servicio `audit-dashboard` expone el puerto 80 (mapeado 8090→80). Un Nginx/Caddy delante termina TLS y reenvía a `http://127.0.0.1:8090`.

---

## Paso 8 — Verificación end-to-end en producción

1. **DNS y TLS**

   ```bash
   curl -I https://audit.lumini.dev/ | head -n 5
   # HTTP/2 200
   ```

2. **Cliente OIDC alcanza al IdP**

   ```bash
   curl -I https://auth.lumini.dev/realms/lumini/.well-known/openid-configuration
   # HTTP/2 200
   ```

3. **Preflight CORS desde el origen del dashboard**

   ```bash
   for BE in \
     https://planner-backend.lumini.dev \
     https://crm-backend.lumini.dev \
     https://lu-hermetica-comercial-webapp-1030749271093.us-central1.run.app \
     https://friopacking-backend-337748371520.us-central1.run.app
   do
     echo "== $BE =="
     curl -s -i -X OPTIONS "$BE/api/v1/audit/logs/" \
          -H "Origin: https://audit.lumini.dev" \
          -H "Access-Control-Request-Method: GET" \
          -H "Access-Control-Request-Headers: authorization" | head -n 10
   done
   ```

   Cada respuesta debe incluir `access-control-allow-origin: https://audit.lumini.dev`.

4. **Obtener JWT y probar un GET real**

   ```bash
   TOKEN=$(curl -s -X POST "https://auth.lumini.dev/realms/lumini/protocol/openid-connect/token" \
       -d "client_id=lumini-audit-dashboard" -d "grant_type=password" \
       -d "username=soporte@lumini.dev" -d "password=TuPassword" \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

   curl -s -H "Authorization: Bearer $TOKEN" \
        "https://planner-backend.lumini.dev/api/v1/audit/logs/?page_size=3" | python3 -m json.tool | head -n 40
   ```

   Debe devolver `results: [...]` con logs reales.

5. **Login desde el navegador** en `https://audit.lumini.dev/` — debe redirigir a `https://auth.lumini.dev/realms/lumini/protocol/openid-connect/auth?...`, completar el login, volver al dashboard y renderizar la tabla con los 4 backends.

---

## Paso 9 — Rollback

Si algo falla en producción:

1. **Dashboard caído o mal configurado**: revierte la imagen de Cloud Run al tag anterior (`gcloud run services update-traffic lumini-audit-dashboard --to-revisions=<prev>=100`), o vuelve a subir el `config.js` correcto al bucket.
2. **Un backend rechaza tokens**: quita el `include("lumini_auth.urls")` del `urls.py`, haz redeploy (endpoint deja de existir → 404 no rompe al resto del backend).
3. **Cliente Keycloak mal configurado**: edita desde el Admin Console (cambios en caliente, sin redeploy).
4. **Rol `DEVELOPER` asignado por error**: quítalo desde Users → Role mapping → Remove.

Ningún paso es destructivo de datos. Los audit-logs persisten en la DB de cada backend independientemente del dashboard.

---

## Paso 10 — Post-deploy

- Asignar `SUPER_ADMIN`/`DEVELOPER` a las cuentas autorizadas según el proceso de [GUIA-USUARIOS.md](./GUIA-USUARIOS.md).
- Configurar observabilidad: los audit-logs solo crecen; considera un cron que archive o borre entradas > N meses si el volumen lo amerita.
- Revisar CSP y headers de seguridad en Nginx/LB delante del dashboard.
- Documentar el dominio `audit.lumini.dev` en tu inventario interno de servicios.

---

## Checklist consolidado

- [ ] DNS de `audit.lumini.dev` apuntando al hosting.
- [ ] Certificado TLS válido.
- [ ] `config.js` de producción en el dashboard.
- [ ] Cliente `lumini-audit-dashboard` de Keycloak con redirect/webOrigins de prod.
- [ ] Variables `KEYCLOAK_BASE_URL` en los 4 backends de prod.
- [ ] `lumini-auth==0.4.0` desplegado en los 4 backends.
- [ ] `include("lumini_auth.urls")` en el `urls.py` de los 4 backends.
- [ ] CORS incluye `https://audit.lumini.dev` en los 4 backends.
- [ ] Realm `lumini` con `sslRequired: external`.
- [ ] Nginx/imagen del dashboard corriendo en el hosting.
- [ ] Verificación end-to-end (pasos 8.1 a 8.5) superada.
- [ ] Al menos una cuenta con `SUPER_ADMIN` o `DEVELOPER` para el primer login.
