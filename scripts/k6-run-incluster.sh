#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE=""
JOB_NAME=""
SCRIPT_PATH=""
ARTIFACT_DIR=""
TARGET_ENV_NAME=""
TARGET_ENV_VALUE=""
TARGET_SERVICE=""
TTL_SECONDS="86400"
K6_IMAGE="grafana/k6:1.7.1"
K6_CPU_REQUEST="20m"
K6_MEMORY_REQUEST="64Mi"
K6_CPU_LIMIT="200m"
K6_MEMORY_LIMIT="256Mi"
WAIT_TIMEOUT="30m"
SNAPSHOT_SCOPE=""
PROMETHEUS_QUERY_WINDOW="${K6_PROMETHEUS_QUERY_WINDOW:-30m}"
PROMETHEUS_QUERY_NAMESPACE="${K6_PROMETHEUS_QUERY_NAMESPACE:-monitoring}"
PROMETHEUS_QUERY_SERVICE="${K6_PROMETHEUS_QUERY_SERVICE:-kube-prometheus-stack-prometheus}"
PROMETHEUS_QUERY_LOCAL_PORT="${K6_PROMETHEUS_QUERY_LOCAL_PORT:-}"
PROMETHEUS_QUERY_URL="${K6_PROMETHEUS_QUERY_URL:-}"
K6_PROMETHEUS_REMOTE_WRITE_ENABLED="${K6_PROMETHEUS_REMOTE_WRITE_ENABLED:-1}"
K6_PROMETHEUS_RW_SERVER_URL="${K6_PROMETHEUS_RW_SERVER_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write}"
K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-avg,min,max,p(90),p(95),p(99)}"
K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
K6_PROMETHEUS_RW_STALE_MARKERS="${K6_PROMETHEUS_RW_STALE_MARKERS:-false}"
K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM="${K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM:-}"
PROMETHEUS_PORT_FORWARD_PID=""

declare -a EXTRA_ENV_VARS=()

usage() {
  cat <<'EOF'
Run a k6 scenario inside Kubernetes and collect TCC-ready artifacts.

Usage:
  scripts/k6-run-incluster.sh \
    --namespace <host-namespace> \
    --job-name <job-name> \
    --script <tests/k6/...js> \
    --artifact-dir <output-dir> \
     --target-env <ENV_NAME> \
     --target-url <service-url> \
     --target-service <service-name> \
     [--snapshot-scope all|shared|abc|xyz|none] \
     [--env KEY=VALUE]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --job-name)
      JOB_NAME="$2"
      shift 2
      ;;
    --script)
      SCRIPT_PATH="$2"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="$2"
      shift 2
      ;;
    --target-env)
      TARGET_ENV_NAME="$2"
      shift 2
      ;;
    --target-url)
      TARGET_ENV_VALUE="$2"
      shift 2
      ;;
    --target-service)
      TARGET_SERVICE="$2"
      shift 2
      ;;
    --ttl-seconds)
      TTL_SECONDS="$2"
      shift 2
      ;;
    --image)
      K6_IMAGE="$2"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --snapshot-scope)
      SNAPSHOT_SCOPE="$2"
      shift 2
      ;;
    --prometheus-rw-url)
      K6_PROMETHEUS_RW_SERVER_URL="$2"
      shift 2
      ;;
    --prometheus-query-url)
      PROMETHEUS_QUERY_URL="$2"
      shift 2
      ;;
    --prometheus-window)
      PROMETHEUS_QUERY_WINDOW="$2"
      shift 2
      ;;
    --no-prometheus)
      K6_PROMETHEUS_REMOTE_WRITE_ENABLED="0"
      shift
      ;;
    --env)
      EXTRA_ENV_VARS+=("$2")
      shift 2
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

for required in NAMESPACE JOB_NAME SCRIPT_PATH ARTIFACT_DIR TARGET_ENV_NAME TARGET_ENV_VALUE TARGET_SERVICE; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required option: ${required}" >&2
    usage >&2
    exit 1
  fi
done

if [[ -f "${ROOT_DIR}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/env.sh"
fi

if [[ -f "${ROOT_DIR}/secrets.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/secrets.env"
fi

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

append_env_block() {
  local env_name="$1"
  local env_value="$2"
  printf '            - name: %s\n              value: %s\n' "${env_name}" "$(json_quote "${env_value}")"
}

append_arg_block() {
  local arg_value="$1"
  printf '            - %s\n' "$(json_quote "${arg_value}")"
}

cleanup_local_processes() {
  if [[ -n "${PROMETHEUS_PORT_FORWARD_PID}" ]]; then
    kill "${PROMETHEUS_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_local_processes EXIT

infer_snapshot_scope() {
  case "${NAMESPACE}" in
    vcluster-shared) printf 'shared' ;;
    vcluster-abc) printf 'abc' ;;
    vcluster-xyz) printf 'xyz' ;;
    *) printf 'all' ;;
  esac
}

wait_for_job_finish() {
  local deadline_seconds="$1"
  local start_epoch current_epoch complete_status failed_status
  start_epoch="$(date +%s)"

  while true; do
    complete_status="$(mise exec -- kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed_status="$(mise exec -- kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    if [[ "${complete_status}" == "True" ]]; then
      return 0
    fi
    if [[ "${failed_status}" == "True" ]]; then
      return 1
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= deadline_seconds )); then
      return 124
    fi

    sleep 3
  done
}

duration_to_seconds() {
  local raw_value="$1"
  case "${raw_value}" in
    *h) printf '%s' "$(( ${raw_value%h} * 3600 ))" ;;
    *m) printf '%s' "$(( ${raw_value%m} * 60 ))" ;;
    *s) printf '%s' "${raw_value%s}" ;;
    *) printf '%s' "${raw_value}" ;;
  esac
}

available_local_port() {
  python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
}

wait_for_prometheus() {
  local prometheus_url="$1"
  local attempt

  for attempt in $(seq 1 30); do
    if python3 - "${prometheus_url}" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

url = sys.argv[1].rstrip('/') + '/api/v1/status/buildinfo'
with urllib.request.urlopen(url, timeout=2) as response:
    raise SystemExit(0 if response.status == 200 else 1)
PY
    then
      return 0
    fi
    sleep 1
  done

  return 1
}

start_prometheus_query_port_forward() {
  if [[ -n "${PROMETHEUS_QUERY_URL}" ]]; then
    printf '%s' "${PROMETHEUS_QUERY_URL}"
    return 0
  fi

  local local_port
  local_port="${PROMETHEUS_QUERY_LOCAL_PORT:-$(available_local_port)}"
  PROMETHEUS_QUERY_URL="http://127.0.0.1:${local_port}"

  mise exec -- kubectl -n "${PROMETHEUS_QUERY_NAMESPACE}" port-forward \
    --address 127.0.0.1 \
    "svc/${PROMETHEUS_QUERY_SERVICE}" \
    "${local_port}:9090" >"${run_dir}/prometheus-port-forward.log" 2>&1 &
  PROMETHEUS_PORT_FORWARD_PID="$!"

  if ! wait_for_prometheus "${PROMETHEUS_QUERY_URL}"; then
    echo "WARN: Prometheus query port-forward did not become ready; reports may show n/a." >&2
  fi

  printf '%s' "${PROMETHEUS_QUERY_URL}"
}

save_redacted_job() {
  mise exec -- kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o json | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
sensitive_terms = ("TOKEN", "PASSWORD", "SECRET", "KEY")

for container in payload.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
    for env in container.get("env", []):
        name = env.get("name", "")
        if any(term in name.upper() for term in sensitive_terms) and "value" in env:
            env["value"] = "REDACTED"

print(json.dumps(payload, indent=2))
' >"${run_dir}/job.json"
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${ARTIFACT_DIR%/}/${timestamp}-${JOB_NAME}"
mkdir -p "${run_dir}"
test_id="${timestamp}-${JOB_NAME}"
SNAPSHOT_SCOPE="${SNAPSHOT_SCOPE:-$(infer_snapshot_scope)}"

pre_dir="${run_dir}/snapshots"
mkdir -p "${pre_dir}"
"${ROOT_DIR}/scripts/k6-baseline-snapshot.sh" --output-dir "${pre_dir}" --label pre --scope "${SNAPSHOT_SCOPE}"

K6_ROOT_CONFIGMAP="${JOB_NAME}-root"
K6_LIB_CONFIGMAP="${JOB_NAME}-lib"
K6_SHARED_CONFIGMAP="${JOB_NAME}-shared"
K6_PAYLOAD_CONFIGMAP="${JOB_NAME}-payloads"

mise exec -- kubectl -n "${NAMESPACE}" create configmap "${K6_ROOT_CONFIGMAP}" \
  --from-file=tenant-smoke.js="${ROOT_DIR}/tests/k6/tenant-smoke.js" \
  --from-file=tenant-ramp.js="${ROOT_DIR}/tests/k6/tenant-ramp.js" \
  --from-file=shared-interpolation.js="${ROOT_DIR}/tests/k6/shared-interpolation.js" \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f - >/dev/null

mise exec -- kubectl -n "${NAMESPACE}" create configmap "${K6_LIB_CONFIGMAP}" \
  --from-file=k6-common.js="${ROOT_DIR}/tests/k6/lib/k6-common.js" \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f - >/dev/null

mise exec -- kubectl -n "${NAMESPACE}" create configmap "${K6_SHARED_CONFIGMAP}" \
  --from-file=root-smoke.js="${ROOT_DIR}/tests/k6/shared-interpolation/root-smoke.js" \
  --from-file=kriging.js="${ROOT_DIR}/tests/k6/shared-interpolation/kriging.js" \
  --from-file=idw-grid.js="${ROOT_DIR}/tests/k6/shared-interpolation/idw-grid.js" \
  --from-file=isi-grid.js="${ROOT_DIR}/tests/k6/shared-interpolation/isi-grid.js" \
  --from-file=isi-geostatistics.js="${ROOT_DIR}/tests/k6/shared-interpolation/isi-geostatistics.js" \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f - >/dev/null

mise exec -- kubectl -n "${NAMESPACE}" create configmap "${K6_PAYLOAD_CONFIGMAP}" \
  --from-file=kriging.json="${ROOT_DIR}/tests/k6/shared-interpolation/payloads/kriging.json" \
  --from-file=idw_grid.json="${ROOT_DIR}/tests/k6/shared-interpolation/payloads/idw_grid.json" \
  --from-file=isi_idw.json="${ROOT_DIR}/tests/k6/shared-interpolation/payloads/isi_idw.json" \
  --from-file=isi_geostatistics_2.json="${ROOT_DIR}/tests/k6/shared-interpolation/payloads/isi_geostatistics_2.json" \
  --dry-run=client -o yaml | mise exec -- kubectl apply -f - >/dev/null

mise exec -- kubectl -n "${NAMESPACE}" label configmap \
  "${K6_ROOT_CONFIGMAP}" \
  "${K6_LIB_CONFIGMAP}" \
  "${K6_SHARED_CONFIGMAP}" \
  "${K6_PAYLOAD_CONFIGMAP}" \
  app=k6-runner \
  "adb.tcc/run-name=${JOB_NAME}" \
  "adb.tcc/target-service=${TARGET_SERVICE}" \
  --overwrite >/dev/null

K6_EXTRA_ENV_BLOCK=""
for env_pair in "${EXTRA_ENV_VARS[@]}"; do
  env_name="${env_pair%%=*}"
  env_value="${env_pair#*=}"
  K6_EXTRA_ENV_BLOCK+="$(append_env_block "${env_name}" "${env_value}")"$'\n'
done

K6_OUTPUT_ARGS_BLOCK=""
if [[ "${K6_PROMETHEUS_REMOTE_WRITE_ENABLED}" == "1" ]]; then
  K6_OUTPUT_ARGS_BLOCK+="$(append_arg_block "--out")"$'\n'
  K6_OUTPUT_ARGS_BLOCK+="$(append_arg_block "experimental-prometheus-rw")"$'\n'
  K6_EXTRA_ENV_BLOCK+="$(append_env_block K6_PROMETHEUS_RW_SERVER_URL "${K6_PROMETHEUS_RW_SERVER_URL}")"$'\n'
  K6_EXTRA_ENV_BLOCK+="$(append_env_block K6_PROMETHEUS_RW_TREND_STATS "${K6_PROMETHEUS_RW_TREND_STATS}")"$'\n'
  K6_EXTRA_ENV_BLOCK+="$(append_env_block K6_PROMETHEUS_RW_PUSH_INTERVAL "${K6_PROMETHEUS_RW_PUSH_INTERVAL}")"$'\n'
  K6_EXTRA_ENV_BLOCK+="$(append_env_block K6_PROMETHEUS_RW_STALE_MARKERS "${K6_PROMETHEUS_RW_STALE_MARKERS}")"$'\n'
  if [[ -n "${K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM}" ]]; then
    K6_EXTRA_ENV_BLOCK+="$(append_env_block K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM "${K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM}")"$'\n'
  fi
fi

export K6_NAMESPACE="${NAMESPACE}"
export K6_JOB_NAME="${JOB_NAME}"
export K6_SCRIPT="${SCRIPT_PATH#tests/k6/}"
export K6_TEST_ID="${test_id}"
export K6_TTL_SECONDS="${TTL_SECONDS}"
export K6_IMAGE="${K6_IMAGE}"
export K6_TARGET_SERVICE="${TARGET_SERVICE}"
export K6_TARGET_SCOPE="${SNAPSHOT_SCOPE}"
export K6_RUN_NAME_VALUE="$(json_quote "${JOB_NAME}")"
export K6_TARGET_SERVICE_VALUE="$(json_quote "${TARGET_SERVICE}")"
export K6_TARGET_ENV_NAME="${TARGET_ENV_NAME}"
export K6_TARGET_ENV_VALUE="$(json_quote "${TARGET_ENV_VALUE}")"
export K6_EXTRA_ENV_BLOCK K6_OUTPUT_ARGS_BLOCK
export K6_CPU_REQUEST K6_MEMORY_REQUEST K6_CPU_LIMIT K6_MEMORY_LIMIT
export K6_ROOT_CONFIGMAP K6_LIB_CONFIGMAP K6_SHARED_CONFIGMAP K6_PAYLOAD_CONFIGMAP

mise exec -- kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
envsubst <"${ROOT_DIR}/manifests/k6/k6-runner-job.yaml" | mise exec -- kubectl apply -f - >/dev/null

set +e
wait_for_job_finish "$(duration_to_seconds "${WAIT_TIMEOUT}")"
job_status="$?"
set -e

pod_name="$(mise exec -- kubectl -n "${NAMESPACE}" get pods -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${pod_name}" ]]; then
  mise exec -- kubectl -n "${NAMESPACE}" logs "${pod_name}" >"${run_dir}/k6.log" 2>&1 || true
  mise exec -- kubectl -n "${NAMESPACE}" describe pod "${pod_name}" >"${run_dir}/k6-pod-describe.txt" 2>&1 || true
fi
mise exec -- kubectl -n "${NAMESPACE}" get pods -l "job-name=${JOB_NAME}" -o wide >"${run_dir}/pods.txt" 2>&1 || true
save_redacted_job || true

"${ROOT_DIR}/scripts/k6-baseline-snapshot.sh" --output-dir "${pre_dir}" --label post --scope "${SNAPSHOT_SCOPE}"

prometheus_url=""
if [[ "${K6_PROMETHEUS_REMOTE_WRITE_ENABLED}" == "1" ]]; then
  prometheus_url="$(start_prometheus_query_port_forward)"
fi

python3 "${ROOT_DIR}/scripts/k6-artifact-report.py" \
  --run-dir "${run_dir}" \
  --test-id "${test_id}" \
  --run-name "${JOB_NAME}" \
  --service "${TARGET_SERVICE}" \
  --target-url "${TARGET_ENV_VALUE}" \
  --scope "${SNAPSHOT_SCOPE}" \
  --prometheus-url "${prometheus_url}" \
  --prometheus-window "${PROMETHEUS_QUERY_WINDOW}"

if [[ "${K6_KEEP_RESOURCES:-0}" != "1" ]]; then
  mise exec -- kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  mise exec -- kubectl -n "${NAMESPACE}" delete configmap "${K6_ROOT_CONFIGMAP}" "${K6_LIB_CONFIGMAP}" "${K6_SHARED_CONFIGMAP}" "${K6_PAYLOAD_CONFIGMAP}" --ignore-not-found >/dev/null 2>&1 || true
fi

printf 'k6 artifacts saved to %s\n' "${run_dir}"

if [[ "${job_status}" != "0" ]]; then
  echo "k6 job failed or timed out; artifacts saved to ${run_dir}" >&2
  exit "${job_status}"
fi
