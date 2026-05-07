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

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${ARTIFACT_DIR%/}/${timestamp}-${JOB_NAME}"
mkdir -p "${run_dir}"

pre_dir="${run_dir}/snapshots"
mkdir -p "${pre_dir}"
"${ROOT_DIR}/scripts/k6-baseline-snapshot.sh" --output-dir "${pre_dir}" --label pre

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

K6_EXTRA_ENV_BLOCK=""
for env_pair in "${EXTRA_ENV_VARS[@]}"; do
  env_name="${env_pair%%=*}"
  env_value="${env_pair#*=}"
  K6_EXTRA_ENV_BLOCK+="$(append_env_block "${env_name}" "${env_value}")"$'\n'
done

export K6_NAMESPACE="${NAMESPACE}"
export K6_JOB_NAME="${JOB_NAME}"
export K6_SCRIPT="${SCRIPT_PATH#tests/k6/}"
export K6_TTL_SECONDS="${TTL_SECONDS}"
export K6_IMAGE="${K6_IMAGE}"
export K6_TARGET_SERVICE="${TARGET_SERVICE}"
export K6_RUN_NAME_VALUE="$(json_quote "${JOB_NAME}")"
export K6_TARGET_SERVICE_VALUE="$(json_quote "${TARGET_SERVICE}")"
export K6_TARGET_ENV_NAME="${TARGET_ENV_NAME}"
export K6_TARGET_ENV_VALUE="$(json_quote "${TARGET_ENV_VALUE}")"
export K6_EXTRA_ENV_BLOCK
export K6_CPU_REQUEST K6_MEMORY_REQUEST K6_CPU_LIMIT K6_MEMORY_LIMIT
export K6_ROOT_CONFIGMAP K6_LIB_CONFIGMAP K6_SHARED_CONFIGMAP K6_PAYLOAD_CONFIGMAP

envsubst <"${ROOT_DIR}/manifests/k6/k6-runner-job.yaml" | mise exec -- kubectl apply -f - >/dev/null

if ! mise exec -- kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT}"; then
  mise exec -- kubectl -n "${NAMESPACE}" get pods -l "job-name=${JOB_NAME}" -o wide >"${run_dir}/failed-pods.txt" 2>&1 || true
  pod_name="$(mise exec -- kubectl -n "${NAMESPACE}" get pods -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod_name}" ]]; then
    mise exec -- kubectl -n "${NAMESPACE}" logs "${pod_name}" >"${run_dir}/k6.log" 2>&1 || true
    mise exec -- kubectl -n "${NAMESPACE}" describe pod "${pod_name}" >"${run_dir}/k6-pod-describe.txt" 2>&1 || true
  fi
  echo "k6 job failed or timed out; debug artifacts saved to ${run_dir}" >&2
  exit 1
fi

pod_name="$(mise exec -- kubectl -n "${NAMESPACE}" get pods -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}')"
mise exec -- kubectl -n "${NAMESPACE}" logs "${pod_name}" >"${run_dir}/k6.log"
mise exec -- kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o yaml >"${run_dir}/job.yaml"

copy_artifact() {
  local artifact_name="$1"
  local local_path="$2"

  if mise exec -- kubectl -n "${NAMESPACE}" cp "${pod_name}:/results/${artifact_name}" "${local_path}" >/dev/null 2>&1; then
    return 0
  fi

  if mise exec -- kubectl -n "${NAMESPACE}" exec "${pod_name}" -- test -f "/results/${artifact_name}" >/dev/null 2>&1; then
    mise exec -- kubectl -n "${NAMESPACE}" exec "${pod_name}" -- cat "/results/${artifact_name}" >"${local_path}"
    return 0
  fi

  return 1
}

for artifact in metrics.json summary-export.json summary.json summary.md summary.txt metadata.json html-report.html; do
  copy_artifact "${artifact}" "${run_dir}/${artifact}" || true
done

"${ROOT_DIR}/scripts/k6-baseline-snapshot.sh" --output-dir "${pre_dir}" --label post
python3 "${ROOT_DIR}/scripts/k6-artifact-report.py" --run-dir "${run_dir}"

if [[ "${K6_KEEP_RESOURCES:-0}" != "1" ]]; then
  mise exec -- kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  mise exec -- kubectl -n "${NAMESPACE}" delete configmap "${K6_ROOT_CONFIGMAP}" "${K6_LIB_CONFIGMAP}" "${K6_SHARED_CONFIGMAP}" "${K6_PAYLOAD_CONFIGMAP}" --ignore-not-found >/dev/null 2>&1 || true
fi

printf 'k6 artifacts saved to %s\n' "${run_dir}"
