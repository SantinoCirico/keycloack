// Lumini Audit Dashboard — vanilla JS client (ES module).
//
// Flow:
//   1. keycloak-js logs the user in (Authorization Code + PKCE).
//   2. We fan out GET /api/v1/audit/logs/ to every configured backend
//      in parallel with the same Bearer token. Each backend returns
//      only its own logs (filtered server-side by LUMINI_AUDIT_SOURCE).
//   3. Results are merged by timestamp desc and rendered in one table.
//   4. "Cargar mas" follows each backend's cursor independently.
//   5. "Exportar CSV" serializes the rendered rows.
//
// keycloak-js v26 ships as ES modules only; imported from ./keycloak.js
// which is served by this same Nginx instance (no build step needed).

import Keycloak from "./keycloak.js";

const cfg = window.LUMINI_CONFIG;
if (!cfg) {
  document.body.textContent = "config.js no cargado";
  throw new Error("LUMINI_CONFIG missing");
}

const state = {
  keycloak: null,
  rows: [],                 // merged rows currently in the table
  nextByBackend: {},        // backend.key -> next cursor URL (or null)
  errorByBackend: {},       // backend.key -> human-readable error
  lastParams: "",           // querystring used for the current dataset
};

// ---------------------------------------------------------------------------
// Keycloak bootstrap
// ---------------------------------------------------------------------------

async function initAuth() {
  state.keycloak = new Keycloak({
    url: cfg.kcUrl,
    realm: cfg.realm,
    clientId: cfg.clientId,
  });

  const authed = await state.keycloak.init({
    onLoad: "login-required",
    pkceMethod: "S256",
    checkLoginIframe: false,
  });

  if (!authed) {
    document.body.textContent = "No autenticado.";
    return false;
  }

  // Refresh the token a few seconds before it expires so fetches don't
  // 401 mid-session. Access token lifespan is 300s per realm config.
  setInterval(() => {
    state.keycloak.updateToken(60).catch(() => state.keycloak.login());
  }, 60_000);

  const email = state.keycloak.tokenParsed?.email
    || state.keycloak.tokenParsed?.preferred_username
    || "desconocido";
  document.getElementById("current-user").textContent = email;

  const logoutBtn = document.getElementById("logout-btn");
  logoutBtn.hidden = false;
  logoutBtn.addEventListener("click", () => state.keycloak.logout());

  return true;
}

// ---------------------------------------------------------------------------
// Filters form
// ---------------------------------------------------------------------------

function renderBackendToggles() {
  const host = document.getElementById("backend-toggles");
  host.innerHTML = "";
  cfg.backends.forEach(b => {
    const lbl = document.createElement("label");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.value = b.key;
    cb.checked = true;
    cb.dataset.backend = b.key;
    lbl.appendChild(cb);
    lbl.appendChild(document.createTextNode(" " + b.label));
    host.appendChild(lbl);
  });
}

function selectedBackends() {
  const keys = Array.from(document.querySelectorAll("[data-backend]:checked"))
    .map(i => i.value);
  return cfg.backends.filter(b => keys.includes(b.key));
}

function readFilters() {
  const methodSelect = document.getElementById("f-method");
  const methods = Array.from(methodSelect.selectedOptions).map(o => o.value);
  const params = new URLSearchParams();
  if (methods.length === 1) params.set("method", methods[0]);
  if (methods.length > 1)   params.set("method_in", methods.join(","));

  const from = document.getElementById("f-from").value;
  if (from) params.set("timestamp_gte", new Date(from).toISOString());
  const to = document.getElementById("f-to").value;
  if (to) params.set("timestamp_lte", new Date(to).toISOString());

  const path = document.getElementById("f-path").value.trim();
  if (path) params.set("path", path);
  const email = document.getElementById("f-user-email").value.trim();
  if (email) params.set("user_email", email);
  const status = document.getElementById("f-status").value.trim();
  if (status) params.set("status_code", status);

  params.set("page_size", "100");
  return params;
}

function resetFilters() {
  document.getElementById("filters-form").reset();
  document.querySelectorAll("[data-backend]").forEach(cb => cb.checked = true);
}

// ---------------------------------------------------------------------------
// Fetch + fan-out
// ---------------------------------------------------------------------------

async function fetchBackend(backend, url) {
  const headers = { Authorization: `Bearer ${state.keycloak.token}` };
  try {
    const res = await fetch(url, { headers });
    if (!res.ok) {
      const msg = res.status === 403
        ? "sin permisos (requiere SUPER_ADMIN o DEVELOPER)"
        : `HTTP ${res.status}`;
      return { backend, results: [], next: null, error: msg };
    }
    const data = await res.json();
    return {
      backend,
      results: (data.results || []).map(r => ({ ...r, _backend: backend.key, _backendLabel: backend.label })),
      next: data.next || null,
      error: null,
    };
  } catch (e) {
    return { backend, results: [], next: null, error: e.message || "offline" };
  }
}

async function loadInitial() {
  const params = readFilters();
  state.lastParams = params.toString();
  state.rows = [];
  state.nextByBackend = {};
  state.errorByBackend = {};

  const backends = selectedBackends();
  setStatus(backends.map(b => ({ key: b.key, label: b.label, state: "loading" })));

  const responses = await Promise.all(backends.map(b =>
    fetchBackend(b, `${b.baseUrl}/api/v1/audit/logs/?${state.lastParams}`)
  ));

  mergeResponses(responses);
  renderTable();
  renderStatusFromResponses(responses);
  updateLoadMore();
}

async function loadMore() {
  const targets = cfg.backends.filter(b => state.nextByBackend[b.key]);
  if (!targets.length) return;

  const responses = await Promise.all(targets.map(b =>
    fetchBackend(b, state.nextByBackend[b.key])
  ));

  mergeResponses(responses);
  renderTable();
  renderStatusFromResponses(responses, /* additive */ true);
  updateLoadMore();
}

function mergeResponses(responses) {
  responses.forEach(r => {
    state.nextByBackend[r.backend.key] = r.next;
    if (r.error) state.errorByBackend[r.backend.key] = r.error;
    else         delete state.errorByBackend[r.backend.key];
    state.rows.push(...r.results);
  });
  state.rows.sort((a, b) => b.timestamp.localeCompare(a.timestamp));
}

function updateLoadMore() {
  const btn = document.getElementById("load-more-btn");
  const hasMore = Object.values(state.nextByBackend).some(Boolean);
  btn.disabled = !hasMore;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

function renderTable() {
  const tbody = document.getElementById("logs-tbody");
  tbody.innerHTML = "";
  const frag = document.createDocumentFragment();

  state.rows.forEach(row => {
    const tr = document.createElement("tr");
    tr.appendChild(cell(formatTimestamp(row.timestamp)));
    tr.appendChild(cell(badge("backend", row._backendLabel || row.project_source || "—")));
    tr.appendChild(cell(row.user?.email || row.user?.username || "anon"));
    tr.appendChild(cell(badge("method-" + row.method, row.method)));
    tr.appendChild(cell(row.path, "path"));
    tr.appendChild(cell(badge(statusClass(row.response_status_code), String(row.response_status_code ?? "—"))));
    tr.appendChild(cell(row.response_time_ms ?? "—"));
    tr.appendChild(cell(row.ip_address || "—"));

    const payloadCell = document.createElement("td");
    if (row.payload) {
      const link = document.createElement("button");
      link.type = "button";
      link.className = "payload-link";
      link.textContent = "ver";
      link.addEventListener("click", () => showPayload(row.payload));
      payloadCell.appendChild(link);
    } else {
      payloadCell.textContent = "—";
    }
    tr.appendChild(payloadCell);

    frag.appendChild(tr);
  });
  tbody.appendChild(frag);

  document.getElementById("row-count").textContent = `${state.rows.length} registros`;
}

function cell(content, cls) {
  const td = document.createElement("td");
  if (cls) td.className = cls;
  if (content instanceof Node) td.appendChild(content);
  else td.textContent = content ?? "";
  return td;
}

function badge(cls, text) {
  const span = document.createElement("span");
  span.className = "badge " + cls;
  span.textContent = text;
  return span;
}

function statusClass(code) {
  if (!code) return "status-2xx";
  if (code < 300) return "status-2xx";
  if (code < 400) return "status-3xx";
  if (code < 500) return "status-4xx";
  return "status-5xx";
}

function formatTimestamp(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleString(undefined, {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

function showPayload(payload) {
  document.getElementById("payload-content").textContent = JSON.stringify(payload, null, 2);
  document.getElementById("payload-dialog").showModal();
}

// ---------------------------------------------------------------------------
// Status pills
// ---------------------------------------------------------------------------

function setStatus(entries) {
  const host = document.getElementById("status-row");
  host.innerHTML = "";
  entries.forEach(e => {
    const pill = document.createElement("span");
    pill.className = "status-pill " + (e.state === "ok" ? "ok" : e.state === "error" ? "error" : "warn");
    const suffix = e.message ? `: ${e.message}` : (e.count !== undefined ? ` (${e.count})` : "");
    pill.textContent = `${e.label}${suffix}`;
    host.appendChild(pill);
  });
}

function renderStatusFromResponses(responses, additive = false) {
  const existing = additive
    ? cfg.backends.map(b => ({ key: b.key, label: b.label, count: countForBackend(b.key), state: state.errorByBackend[b.key] ? "error" : "ok", message: state.errorByBackend[b.key] }))
    : responses.map(r => ({
        key: r.backend.key,
        label: r.backend.label,
        state: r.error ? "error" : "ok",
        message: r.error,
        count: r.results.length,
      }));
  // When not additive, still include backends that weren't queried this round as disabled
  if (!additive) {
    const queried = new Set(responses.map(r => r.backend.key));
    cfg.backends.forEach(b => {
      if (!queried.has(b.key)) existing.push({ key: b.key, label: b.label, state: "warn", message: "no consultado" });
    });
  }
  setStatus(existing);
}

function countForBackend(key) {
  return state.rows.filter(r => r._backend === key).length;
}

// ---------------------------------------------------------------------------
// CSV export
// ---------------------------------------------------------------------------

function exportCsv() {
  if (!state.rows.length) return;
  const header = ["timestamp","backend","user_email","method","path","status","duration_ms","ip"];
  const lines = [header.join(",")];
  state.rows.forEach(r => {
    lines.push([
      r.timestamp,
      r._backend,
      (r.user?.email || r.user?.username || "").replace(/"/g, '""'),
      r.method,
      '"' + (r.path || "").replace(/"/g, '""') + '"',
      r.response_status_code ?? "",
      r.response_time_ms ?? "",
      r.ip_address ?? "",
    ].join(","));
  });
  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `audit-${new Date().toISOString().replace(/[:.]/g, "-")}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------------
// Wire up
// ---------------------------------------------------------------------------

(async function main() {
  const ok = await initAuth();
  if (!ok) return;

  renderBackendToggles();

  document.getElementById("filters-form").addEventListener("submit", async e => {
    e.preventDefault();
    await loadInitial();
  });
  document.getElementById("reset-btn").addEventListener("click", () => {
    resetFilters();
  });
  document.getElementById("load-more-btn").addEventListener("click", loadMore);
  document.getElementById("csv-btn").addEventListener("click", exportCsv);

  await loadInitial();
})();
