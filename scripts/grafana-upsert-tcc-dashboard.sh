#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"
DASHBOARD_FILE="${DASHBOARD_FILE:-${ROOT_DIR}/grafana/tcc-pod-compute-dashboard.json}"
GRAFANA_URL="${GRAFANA_URL:-http://144.22.151.206}"
ABC_KUBECONFIG="${ABC_KUBECONFIG:-${STATE_DIR}/kubeconfig-abc.yaml}"
SHARED_KUBECONFIG="${SHARED_KUBECONFIG:-${STATE_DIR}/kubeconfig-shared.yaml}"
OBS_DIR="${OBS_DIR:-${STATE_DIR}/observability}"

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

append_hpa_snapshot_spec() {
  local -n specs_ref="$1"
  local cluster="$2"
  local kubeconfig="$3"
  local namespace="$4"
  local hpa_name="$5"

  if [[ -f "${kubeconfig}" ]]; then
    specs_ref+=("${cluster}|${kubeconfig}|${namespace}|${hpa_name}")
    return
  fi

  echo "WARN: skipping ${cluster}; kubeconfig not found: ${kubeconfig}" >&2
}

hpa_snapshot_specs=()
append_hpa_snapshot_spec hpa_snapshot_specs abc "${ABC_KUBECONFIG}" app adb-api
append_hpa_snapshot_spec hpa_snapshot_specs shared "${SHARED_KUBECONFIG}" processing adb-interpolation-api

if ((${#hpa_snapshot_specs[@]} == 0)); then
  echo "ERROR: no vCluster kubeconfigs available for HPA dashboard snapshot" >&2
  exit 1
fi

hpa_snapshot_json="$(python - <<'PY' "${hpa_snapshot_specs[@]}"
import json
import subprocess
import sys

def parse_spec(raw_spec):
    cluster, kubeconfig, namespace, hpa_name = raw_spec.split('|', 3)
    return cluster, kubeconfig, namespace, hpa_name

clusters = [parse_spec(item) for item in sys.argv[1:]]

def run_json(kubeconfig, namespace, name):
    return subprocess.check_output([
        'mise', 'exec', '--', 'kubectl',
        '--kubeconfig', kubeconfig,
        '-n', namespace,
        'get', 'hpa', name,
        '-o', 'json',
    ], text=True)

def metric_map(current_metrics):
    metrics = {}
    for item in current_metrics:
        if item.get('type') != 'Resource':
            continue
        resource = item.get('resource', {})
        current = resource.get('current', {})
        metrics[resource.get('name')] = {
            'utilization': current.get('averageUtilization'),
            'value': current.get('averageValue'),
        }
    return metrics

result = []
for cluster, kubeconfig, namespace, hpa_name in clusters:
    try:
        payload = json.loads(run_json(kubeconfig, namespace, hpa_name))
    except subprocess.CalledProcessError as error:
        print(
            f'WARN: skipping {cluster}/{namespace}/{hpa_name}; kubectl failed: {error}',
            file=sys.stderr,
        )
        continue
    status = payload.get('status', {})
    spec = payload.get('spec', {})
    metrics = metric_map(status.get('currentMetrics', []))
    targets = {}
    for item in spec.get('metrics', []):
        if item.get('type') != 'Resource':
            continue
        resource = item.get('resource', {})
        target = resource.get('target', {})
        targets[resource.get('name')] = target.get('averageUtilization')
    result.append({
        'cluster': cluster,
        'namespace': namespace,
        'hpa': hpa_name,
        'currentReplicas': status.get('currentReplicas', '?'),
        'desiredReplicas': status.get('desiredReplicas', '?'),
        'minReplicas': spec.get('minReplicas', '?'),
        'maxReplicas': spec.get('maxReplicas', '?'),
        'cpuCurrentUtilization': metrics.get('cpu', {}).get('utilization'),
        'cpuCurrentValue': metrics.get('cpu', {}).get('value'),
        'cpuTargetUtilization': targets.get('cpu'),
        'memoryCurrentUtilization': metrics.get('memory', {}).get('utilization'),
        'memoryCurrentValue': metrics.get('memory', {}).get('value'),
        'memoryTargetUtilization': targets.get('memory'),
        'scalingActive': next((c.get('status') for c in status.get('conditions', []) if c.get('type') == 'ScalingActive'), 'Unknown'),
        'scalingReason': next((c.get('reason') for c in status.get('conditions', []) if c.get('type') == 'ScalingActive'), 'Unknown'),
    })

print(json.dumps(result))
PY
)"

payload="$(python - <<'PY' "${DASHBOARD_FILE}" "${hpa_snapshot_json}"
import json
import sys

dashboard_path = sys.argv[1]
hpa_snapshot = json.loads(sys.argv[2])

def format_quantity(raw_value):
    if not raw_value:
        return None
    if raw_value.endswith('m'):
        try:
            milli_value = float(raw_value[:-1])
            if milli_value >= 1024 * 1024:
                return f'{milli_value / 1000 / 1024 / 1024:.1f}Mi'
        except ValueError:
            pass
        return raw_value
    return raw_value

def format_metric(current_utilization, target_utilization, current_value):
    if current_utilization is None and target_utilization is None:
        return 'n/a'
    current_part = 'n/a' if current_utilization is None else f'{current_utilization}%'
    target_part = 'n/a' if target_utilization is None else f'{target_utilization}%'
    formatted_value = format_quantity(current_value)
    if formatted_value:
        return f'{current_part} ({formatted_value}) / {target_part}'
    return f'{current_part} / {target_part}'

lines = [
    'Atualizado automaticamente via `grafana-upsert-tcc-dashboard.sh`.',
    '',
    '| vCluster | Namespace | HPA | Atual | Desejado | Min | Max | CPU | Memória | ScalingActive |',
    '|---|---|---|---:|---:|---:|---:|---|---|---|',
]

for item in hpa_snapshot:
    lines.append(
        '| {cluster} | `{namespace}` | `{hpa}` | {currentReplicas} | {desiredReplicas} | {minReplicas} | {maxReplicas} | {cpu} | {memory} | {active} ({reason}) |'.format(
            cluster=item['cluster'],
            namespace=item['namespace'],
            hpa=item['hpa'],
            currentReplicas=item['currentReplicas'],
            desiredReplicas=item['desiredReplicas'],
            minReplicas=item['minReplicas'],
            maxReplicas=item['maxReplicas'],
            cpu=format_metric(item['cpuCurrentUtilization'], item['cpuTargetUtilization'], item['cpuCurrentValue']),
            memory=format_metric(item['memoryCurrentUtilization'], item['memoryTargetUtilization'], item['memoryCurrentValue']),
            active=item['scalingActive'],
            reason=item['scalingReason'],
        )
    )

with open(dashboard_path, 'r', encoding='utf-8') as handle:
    dashboard = json.load(handle)

for panel in dashboard.get('panels', []):
    if panel.get('id') == 6:
        panel.setdefault('options', {})['content'] = '\n'.join(lines)

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
