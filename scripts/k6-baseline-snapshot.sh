#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_DIR=""
LABEL="snapshot"
SCOPE="all"

usage() {
  cat <<'EOF'
Capture baseline Kubernetes snapshots for TCC k6 evidence.

Usage:
  scripts/k6-baseline-snapshot.sh --output-dir <dir> [--label <name>] [--scope all|shared|abc|none]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --scope)
      SCOPE="$2"
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

if [[ -z "${OUTPUT_DIR}" ]]; then
  echo "--output-dir is required" >&2
  usage >&2
  exit 1
fi

if [[ -f "${ROOT_DIR}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/env.sh"
fi

if [[ -f "${ROOT_DIR}/secrets.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/secrets.env"
fi

mkdir -p "${OUTPUT_DIR}"

run_and_capture() {
  local output_file="$1"
  shift
  mise exec -- "$@" >"${output_file}" 2>&1
}

capture_applications() {
  local app_name="$1"

  if [[ "${app_name}" == "all" ]]; then
    run_and_capture "${OUTPUT_DIR}/${LABEL}-argocd-applications.txt" kubectl -n argocd get applications -A -o wide
  else
    run_and_capture "${OUTPUT_DIR}/${LABEL}-argocd-${app_name}.txt" kubectl -n argocd get application "${app_name}" -o wide
  fi
}

capture_host_namespace() {
  local host_namespace="$1"

  run_and_capture "${OUTPUT_DIR}/${LABEL}-${host_namespace}-top-pods.txt" kubectl top pods -n "${host_namespace}"
  run_and_capture "${OUTPUT_DIR}/${LABEL}-${host_namespace}-services.txt" kubectl -n "${host_namespace}" get svc,pods -o wide
}

capture_vcluster_runtime() {
  local cluster="$1"
  local namespace="$2"
  local extra_resources="$3"
  local kubeconfig="${ROOT_DIR}/.state/cluster-state/kubeconfig-${cluster}.yaml"

  if [[ -f "${kubeconfig}" ]]; then
    run_and_capture "${OUTPUT_DIR}/${LABEL}-${cluster}-runtime.txt" kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get "${extra_resources}" -o wide
  fi
}

case "${SCOPE}" in
  all)
    capture_applications all
    run_and_capture "${OUTPUT_DIR}/${LABEL}-top-nodes.txt" kubectl top nodes
    run_and_capture "${OUTPUT_DIR}/${LABEL}-top-pods.txt" kubectl top pods -A
    run_and_capture "${OUTPUT_DIR}/${LABEL}-host-vcluster-services.txt" kubectl get svc -A
    capture_vcluster_runtime shared processing svc,pods,hpa,endpointslice
    capture_vcluster_runtime abc app svc,pods,hpa
    ;;
  shared)
    capture_applications shared-interpolation
    run_and_capture "${OUTPUT_DIR}/${LABEL}-top-nodes.txt" kubectl top nodes
    capture_host_namespace vcluster-shared
    capture_vcluster_runtime shared processing svc,pods,hpa,endpointslice
    ;;
  abc)
    capture_applications "tenant-${SCOPE}-adb-api"
    run_and_capture "${OUTPUT_DIR}/${LABEL}-top-nodes.txt" kubectl top nodes
    capture_host_namespace "vcluster-${SCOPE}"
    capture_vcluster_runtime "${SCOPE}" app svc,pods,hpa
    ;;
  none)
    ;;
  *)
    echo "Unknown scope: ${SCOPE}" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ -x "${ROOT_DIR}/scripts/collect-vcluster-hpa-history.sh" ]]; then
  "${ROOT_DIR}/scripts/collect-vcluster-hpa-history.sh" --once >/dev/null 2>&1 || true
fi
