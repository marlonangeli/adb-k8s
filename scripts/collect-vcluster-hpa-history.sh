#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"
OBS_DIR="${OBS_DIR:-${STATE_DIR}/observability}"
HISTORY_FILE="${HPA_HISTORY_FILE:-${OBS_DIR}/hpa-history.jsonl}"
METRICS_FILE="${HPA_METRICS_FILE:-${OBS_DIR}/hpa-metrics.prom}"
INTERVAL_SECONDS="${HPA_HISTORY_INTERVAL_SECONDS:-15}"
RETENTION_LINES="${HPA_HISTORY_RETENTION_LINES:-2000}"
PID_FILE="${HPA_HISTORY_PID_FILE:-${OBS_DIR}/hpa-history.pid}"
EXPORTER_NAMESPACE="${HPA_EXPORTER_NAMESPACE:-monitoring}"
EXPORTER_CONFIGMAP_NAME="${HPA_EXPORTER_CONFIGMAP_NAME:-vcluster-hpa-exporter}"
EXPORTER_DEPLOYMENT_NAME="${HPA_EXPORTER_DEPLOYMENT_NAME:-vcluster-hpa-exporter}"
EXPORTER_SERVICE_NAME="${HPA_EXPORTER_SERVICE_NAME:-vcluster-hpa-exporter}"
EXPORTER_SERVICE_MONITOR_NAME="${HPA_EXPORTER_SERVICE_MONITOR_NAME:-vcluster-hpa-exporter}"

ABC_KUBECONFIG="${ABC_KUBECONFIG:-${STATE_DIR}/kubeconfig-abc.yaml}"
XYZ_KUBECONFIG="${XYZ_KUBECONFIG:-${STATE_DIR}/kubeconfig-xyz.yaml}"
SHARED_KUBECONFIG="${SHARED_KUBECONFIG:-${STATE_DIR}/kubeconfig-shared.yaml}"

usage() {
  cat <<'EOF'
Collect vCluster HPA history into JSONL for Grafana dashboard snapshots.

Usage:
  scripts/collect-vcluster-hpa-history.sh [--once]
  scripts/collect-vcluster-hpa-history.sh --daemon

Options:
  --once     Collect one sample and exit
  --daemon   Run collector in background and save PID file
EOF
}

collect_mode="loop"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      collect_mode="once"
      shift
      ;;
    --daemon)
      collect_mode="daemon"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "${OBS_DIR}"

ensure_mise() {
  if ! command -v mise >/dev/null 2>&1; then
    echo "ERROR: mise command not found in PATH" >&2
    exit 1
  fi
}

ensure_file() {
  local file_path="$1"
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: kubeconfig not found: ${file_path}" >&2
    exit 1
  fi
}

ensure_exporter_resources() {
  mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${EXPORTER_CONFIGMAP_NAME}
  namespace: ${EXPORTER_NAMESPACE}
  labels:
    app: vcluster-hpa-exporter
    release: kube-prometheus-stack
data:
  metrics.prom: |
    # waiting for hpa collector
    adb_vcluster_hpa_collector_up 0
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${EXPORTER_DEPLOYMENT_NAME}
  namespace: ${EXPORTER_NAMESPACE}
  labels:
    app: vcluster-hpa-exporter
    release: kube-prometheus-stack
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vcluster-hpa-exporter
  template:
    metadata:
      labels:
        app: vcluster-hpa-exporter
        release: kube-prometheus-stack
    spec:
      containers:
        - name: exporter
          image: docker.io/library/python:3.12-alpine
          imagePullPolicy: IfNotPresent
          command:
            - python
            - -c
            - |
              from http.server import BaseHTTPRequestHandler, HTTPServer
              from pathlib import Path

              METRICS = Path('/data/metrics.prom')

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      if self.path != '/metrics':
                          self.send_response(404)
                          self.end_headers()
                          return
                      body = METRICS.read_text(encoding='utf-8') if METRICS.exists() else 'adb_vcluster_hpa_collector_up 0\n'
                      payload = body.encode('utf-8')
                      self.send_response(200)
                      self.send_header('Content-Type', 'text/plain; version=0.0.4')
                      self.send_header('Content-Length', str(len(payload)))
                      self.end_headers()
                      self.wfile.write(payload)

              HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
          ports:
            - name: http-metrics
              containerPort: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 96Mi
          volumeMounts:
            - name: metrics-data
              mountPath: /data
              readOnly: true
      volumes:
        - name: metrics-data
          configMap:
            name: ${EXPORTER_CONFIGMAP_NAME}
---
apiVersion: v1
kind: Service
metadata:
  name: ${EXPORTER_SERVICE_NAME}
  namespace: ${EXPORTER_NAMESPACE}
  labels:
    app: vcluster-hpa-exporter
    release: kube-prometheus-stack
spec:
  selector:
    app: vcluster-hpa-exporter
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${EXPORTER_SERVICE_MONITOR_NAME}
  namespace: ${EXPORTER_NAMESPACE}
  labels:
    app: vcluster-hpa-exporter
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: vcluster-hpa-exporter
      release: kube-prometheus-stack
  namespaceSelector:
    matchNames:
      - ${EXPORTER_NAMESPACE}
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 15s
EOF
}

publish_metrics() {
  mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" create configmap "${EXPORTER_CONFIGMAP_NAME}" \
    --from-file=metrics.prom="${METRICS_FILE}" \
    --dry-run=client -o yaml | mise exec -- kubectl apply -f - >/dev/null
}

trim_history() {
  python - <<'PY' "${HISTORY_FILE}" "${RETENTION_LINES}"
from pathlib import Path
import sys

path = Path(sys.argv[1])
limit = int(sys.argv[2])

if not path.exists():
    raise SystemExit(0)

lines = path.read_text(encoding='utf-8').splitlines()
if len(lines) <= limit:
    raise SystemExit(0)

path.write_text('\n'.join(lines[-limit:]) + '\n', encoding='utf-8')
PY
}

collect_once() {
  python - <<'PY' "${ABC_KUBECONFIG}" "${XYZ_KUBECONFIG}" "${SHARED_KUBECONFIG}" "${HISTORY_FILE}" "${METRICS_FILE}"
from datetime import datetime, timezone
from pathlib import Path
import json
import subprocess
import sys

clusters = [
    ("abc", sys.argv[1], "app", "adb-api"),
    ("xyz", sys.argv[2], "app", "adb-api"),
    ("shared", sys.argv[3], "processing", "adb-interpolation-api"),
]
history_path = Path(sys.argv[4])
metrics_path = Path(sys.argv[5])
timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def run_json(kubeconfig, namespace, hpa_name):
    return subprocess.check_output([
        'mise', 'exec', '--', 'kubectl',
        '--kubeconfig', kubeconfig,
        '-n', namespace,
        'get', 'hpa', hpa_name,
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

with history_path.open('a', encoding='utf-8') as handle:
    metrics_lines = [
        '# HELP adb_vcluster_hpa_current_replicas Current HPA replicas inside vClusters.',
        '# TYPE adb_vcluster_hpa_current_replicas gauge',
        '# HELP adb_vcluster_hpa_desired_replicas Desired HPA replicas inside vClusters.',
        '# TYPE adb_vcluster_hpa_desired_replicas gauge',
        '# HELP adb_vcluster_hpa_min_replicas Min HPA replicas inside vClusters.',
        '# TYPE adb_vcluster_hpa_min_replicas gauge',
        '# HELP adb_vcluster_hpa_max_replicas Max HPA replicas inside vClusters.',
        '# TYPE adb_vcluster_hpa_max_replicas gauge',
        '# HELP adb_vcluster_hpa_cpu_utilization_percent Current HPA cpu utilization percent inside vClusters.',
        '# TYPE adb_vcluster_hpa_cpu_utilization_percent gauge',
        '# HELP adb_vcluster_hpa_cpu_target_percent Target HPA cpu utilization percent inside vClusters.',
        '# TYPE adb_vcluster_hpa_cpu_target_percent gauge',
        '# HELP adb_vcluster_hpa_memory_utilization_percent Current HPA memory utilization percent inside vClusters.',
        '# TYPE adb_vcluster_hpa_memory_utilization_percent gauge',
        '# HELP adb_vcluster_hpa_memory_target_percent Target HPA memory utilization percent inside vClusters.',
        '# TYPE adb_vcluster_hpa_memory_target_percent gauge',
        '# HELP adb_vcluster_hpa_scaling_active ScalingActive condition from the vCluster HPA.',
        '# TYPE adb_vcluster_hpa_scaling_active gauge',
        '# HELP adb_vcluster_hpa_collector_up Whether the background collector completed the current scrape.',
        '# TYPE adb_vcluster_hpa_collector_up gauge',
    ]

    for cluster, kubeconfig, namespace, hpa_name in clusters:
        payload = json.loads(run_json(kubeconfig, namespace, hpa_name))
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

        record = {
            'timestamp': timestamp,
            'cluster': cluster,
            'namespace': namespace,
            'hpa': hpa_name,
            'currentReplicas': status.get('currentReplicas'),
            'desiredReplicas': status.get('desiredReplicas'),
            'minReplicas': spec.get('minReplicas'),
            'maxReplicas': spec.get('maxReplicas'),
            'cpuCurrentUtilization': metrics.get('cpu', {}).get('utilization'),
            'cpuCurrentValue': metrics.get('cpu', {}).get('value'),
            'cpuTargetUtilization': targets.get('cpu'),
            'memoryCurrentUtilization': metrics.get('memory', {}).get('utilization'),
            'memoryCurrentValue': metrics.get('memory', {}).get('value'),
            'memoryTargetUtilization': targets.get('memory'),
            'scalingActive': next((c.get('status') for c in status.get('conditions', []) if c.get('type') == 'ScalingActive'), 'Unknown'),
            'scalingReason': next((c.get('reason') for c in status.get('conditions', []) if c.get('type') == 'ScalingActive'), 'Unknown'),
        }
        handle.write(json.dumps(record) + '\n')

        labels = f'cluster="{cluster}",namespace="{namespace}",hpa="{hpa_name}"'
        metrics_lines.append(f'adb_vcluster_hpa_current_replicas{{{labels}}} {record["currentReplicas"]}')
        metrics_lines.append(f'adb_vcluster_hpa_desired_replicas{{{labels}}} {record["desiredReplicas"]}')
        metrics_lines.append(f'adb_vcluster_hpa_min_replicas{{{labels}}} {record["minReplicas"]}')
        metrics_lines.append(f'adb_vcluster_hpa_max_replicas{{{labels}}} {record["maxReplicas"]}')

        if record['cpuCurrentUtilization'] is not None:
            metrics_lines.append(f'adb_vcluster_hpa_cpu_utilization_percent{{{labels}}} {record["cpuCurrentUtilization"]}')
        if record['cpuTargetUtilization'] is not None:
            metrics_lines.append(f'adb_vcluster_hpa_cpu_target_percent{{{labels}}} {record["cpuTargetUtilization"]}')
        if record['memoryCurrentUtilization'] is not None:
            metrics_lines.append(f'adb_vcluster_hpa_memory_utilization_percent{{{labels}}} {record["memoryCurrentUtilization"]}')
        if record['memoryTargetUtilization'] is not None:
            metrics_lines.append(f'adb_vcluster_hpa_memory_target_percent{{{labels}}} {record["memoryTargetUtilization"]}')

        scaling_active = 1 if str(record['scalingActive']).lower() == 'true' else 0
        reason = str(record['scalingReason']).replace('"', '\\"')
        metrics_lines.append(f'adb_vcluster_hpa_scaling_active{{{labels},reason="{reason}"}} {scaling_active}')

    metrics_lines.append('adb_vcluster_hpa_collector_up 1')
    metrics_path.write_text('\n'.join(metrics_lines) + '\n', encoding='utf-8')
PY
}

ensure_mise
ensure_file "${ABC_KUBECONFIG}"
ensure_file "${XYZ_KUBECONFIG}"
ensure_file "${SHARED_KUBECONFIG}"
ensure_exporter_resources

if [[ "${collect_mode}" == "daemon" ]]; then
  if [[ -f "${PID_FILE}" ]]; then
    existing_pid="$(<"${PID_FILE}")"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" >/dev/null 2>&1; then
      echo "Collector already running with PID ${existing_pid}" >&2
      exit 0
    fi
  fi

  nohup "${BASH_SOURCE[0]}" >"${OBS_DIR}/hpa-history.log" 2>&1 &
  collector_pid=$!
  printf '%s\n' "${collector_pid}" >"${PID_FILE}"
  printf 'Started HPA collector in background (PID %s)\n' "${collector_pid}"
  exit 0
fi

if [[ "${collect_mode}" == "once" ]]; then
  collect_once
  trim_history
  publish_metrics
  exit 0
fi

while true; do
  collect_once
  trim_history
  publish_metrics
  sleep "${INTERVAL_SECONDS}"
done
