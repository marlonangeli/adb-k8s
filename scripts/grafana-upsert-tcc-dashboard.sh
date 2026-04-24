#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"
DASHBOARD_FILE="${DASHBOARD_FILE:-${ROOT_DIR}/grafana/tcc-pod-compute-dashboard.json}"
GRAFANA_URL="${GRAFANA_URL:-http://144.22.151.206}"

if [[ -f "${ROOT_DIR}/secrets.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/secrets.env"
fi

if [[ -f "${STATE_DIR}/dynamic.env" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dynamic.env" || true
fi

: "${GRAFANA_ADMIN_USER:?defina GRAFANA_ADMIN_USER em secrets.env}"
: "${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD em secrets.env}"

if [[ -n "${GRAFANA_HOSTNAME:-}" ]]; then
  case "${GRAFANA_HOSTNAME}" in
    *.*.*.*)
      GRAFANA_URL="http://${GRAFANA_HOSTNAME}"
      ;;
  esac
fi

if [[ ! -f "${DASHBOARD_FILE}" ]]; then
  echo "ERROR: dashboard file not found: ${DASHBOARD_FILE}" >&2
  exit 1
fi

payload="$(python - <<'PY' "${DASHBOARD_FILE}"
import json
import sys

dashboard_path = sys.argv[1]
with open(dashboard_path, 'r', encoding='utf-8') as handle:
    dashboard = json.load(handle)

print(json.dumps({
    'dashboard': dashboard,
    'overwrite': True,
}))
PY
)"

curl -fsS \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "${payload}" \
  "${GRAFANA_URL}/api/dashboards/db"

printf '\nDashboard upserted: %s/d/tcc-pod-compute\n' "${GRAFANA_URL}"
