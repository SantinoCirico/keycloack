// Runtime config for the Lumini Audit Dashboard.
// Served with Cache-Control: no-store so ops can edit these values in
// place (e.g. point at staging backends) without rebuilding the image.
window.LUMINI_CONFIG = {
  kcUrl: "http://localhost:8080",
  realm: "lumini",
  clientId: "lumini-audit-dashboard",
  backends: [
    { key: "planner",     baseUrl: "http://localhost:8001", label: "Planner" },
    { key: "crm",         baseUrl: "http://localhost:8002", label: "CRM" },
    { key: "hermetica",   baseUrl: "http://localhost:8003", label: "Hermetica" },
    { key: "operaciones", baseUrl: "http://localhost:8004", label: "Operaciones" },
  ],
};
