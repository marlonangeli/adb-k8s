#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"
OBS_DIR="${OBS_DIR:-${STATE_DIR}/observability}"
HISTORY_FILE="${HPA_HISTORY_FILE:-${OBS_DIR}/hpa-history.jsonl}"
METRICS_FILE="${HPA_METRICS_FILE:-${OBS_DIR}/hpa-metrics.prom}"
CACHE_FILE="${HPA_CACHE_FILE:-${OBS_DIR}/hpa-cache.json}"
INTERVAL_SECONDS="${HPA_HISTORY_INTERVAL_SECONDS:-15}"
RETENTION_LINES="${HPA_HISTORY_RETENTION_LINES:-2000}"
PID_FILE="${HPA_HISTORY_PID_FILE:-${OBS_DIR}/hpa-history.pid}"
EXPORTER_NAMESPACE="${HPA_EXPORTER_NAMESPACE:-monitoring}"
EXPORTER_CONFIGMAP_NAME="${HPA_EXPORTER_CONFIGMAP_NAME:-vcluster-hpa-exporter}"
EXPORTER_DEPLOYMENT_NAME="${HPA_EXPORTER_DEPLOYMENT_NAME:-vcluster-hpa-exporter}"
EXPORTER_SERVICE_NAME="${HPA_EXPORTER_SERVICE_NAME:-vcluster-hpa-exporter}"
EXPORTER_SERVICE_MONITOR_NAME="${HPA_EXPORTER_SERVICE_MONITOR_NAME:-vcluster-hpa-exporter}"

ABC_KUBECONFIG="${ABC_KUBECONFIG:-${STATE_DIR}/kubeconfig-abc.yaml}"
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

append_cluster_spec() {
  local -n cluster_specs_ref="$1"
  local cluster="$2"
  local kubeconfig="$3"
  local namespace="$4"
  local hpa_name="$5"

  if [[ ! -f "${kubeconfig}" ]]; then
    echo "WARN: ${cluster} kubeconfig not found; collection will be incomplete: ${kubeconfig}" >&2
  fi

  cluster_specs_ref+=("${cluster}|${kubeconfig}|${namespace}|${hpa_name}")
}

ensure_exporter_resources() {
  mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" apply --validate=false -f - <<EOF
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
              METRICS.parent.mkdir(parents=True, exist_ok=True)
              if not METRICS.exists():
                  METRICS.write_text('adb_vcluster_hpa_collector_up 0\n', encoding='utf-8')

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
      volumes:
        - name: metrics-data
          emptyDir: {}
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

  mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" \
    rollout status "deployment/${EXPORTER_DEPLOYMENT_NAME}" --timeout=90s
}

publish_metrics() {
  local pod_name

  pod_name="$(mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" get pod \
    -l app=vcluster-hpa-exporter \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"

  if [[ -z "${pod_name}" ]]; then
    echo "WARN: no running HPA exporter pod found" >&2
    return 1
  fi

  mise exec -- kubectl -n "${EXPORTER_NAMESPACE}" exec -i "${pod_name}" -- \
    sh -c 'cat > /data/metrics.prom.tmp && mv /data/metrics.prom.tmp /data/metrics.prom' <"${METRICS_FILE}" >/dev/null
}

try_ensure_exporter_resources() {
  if ensure_exporter_resources >/dev/null; then
    return 0
  fi

  echo "WARN: failed to ensure HPA exporter resources; will retry later" >&2
  return 1
}

try_publish_metrics() {
  if publish_metrics; then
    return 0
  fi

  echo "WARN: failed to publish HPA metrics to exporter pod; will retry later" >&2
  return 1
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
  local -a cluster_specs=()

  append_cluster_spec cluster_specs abc "${ABC_KUBECONFIG}" app adb-api
  append_cluster_spec cluster_specs shared "${SHARED_KUBECONFIG}" processing adb-interpolation-api

  if ((${#cluster_specs[@]} == 0)); then
    echo "ERROR: no vCluster kubeconfigs available for HPA collection" >&2
    return 1
  fi

  python - <<'PY' "${HISTORY_FILE}" "${METRICS_FILE}" "${cluster_specs[@]}"
from datetime import datetime, timezone
from pathlib import Path
import json
import subprocess
import sys

history_path = Path(sys.argv[1])
metrics_path = Path(sys.argv[2])
timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def parse_spec(raw_spec):
    cluster, kubeconfig, namespace, hpa_name = raw_spec.split('|', 3)
    return cluster, kubeconfig, namespace, hpa_name

clusters = [parse_spec(item) for item in sys.argv[3:]]

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
    collected_count = 0
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
        collected_count += 1

        labels = f'cluster="{cluster}",exported_namespace="{namespace}",hpa="{hpa_name}"'
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

    all_clusters_collected = collected_count == len(clusters)
    metrics_lines.append(f'adb_vcluster_hpa_collector_up {1 if all_clusters_collected else 0}')
    metrics_path.write_text('\n'.join(metrics_lines) + '\n', encoding='utf-8')

    if not all_clusters_collected:
        raise SystemExit(1)
PY
}

ensure_mise

if [[ "${collect_mode}" == "daemon" ]]; then
  if [[ -f "${PID_FILE}" ]]; then
    existing_pid="$(<"${PID_FILE}")"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" >/dev/null 2>&1; then
      echo "Collector already running with PID ${existing_pid}" >&2
      exit 0
    fi
  fi

  printf '\n[%s] starting HPA collector daemon\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${OBS_DIR}/hpa-history.log"
  nohup "${BASH_SOURCE[0]}" >>"${OBS_DIR}/hpa-history.log" 2>&1 &
  collector_pid=$!
  printf '%s\n' "${collector_pid}" >"${PID_FILE}"
  printf 'Started HPA collector in background (PID %s)\n' "${collector_pid}"
  exit 0
fi

if [[ "${collect_mode}" == "once" ]]; then
  collect_once
  trim_history
  ensure_exporter_resources >/dev/null
  publish_metrics
  exit
fi

while true; do
  if collect_once; then
    trim_history || echo "WARN: failed to trim HPA history" >&2
  else
    echo "WARN: HPA collection failed; wrote collector_up=0 and will retry" >&2
  fi

  if try_ensure_exporter_resources; then
    try_publish_metrics || true
  fi
  sleep "${INTERVAL_SECONDS}"
done
