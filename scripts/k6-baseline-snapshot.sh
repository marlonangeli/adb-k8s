#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_DIR=""
LABEL="snapshot"

usage() {
  cat <<'EOF'
Capture baseline Kubernetes snapshots for TCC k6 evidence.

Usage:
  scripts/k6-baseline-snapshot.sh --output-dir <dir> [--label <name>]
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

run_and_capture "${OUTPUT_DIR}/${LABEL}-argocd-applications.txt" kubectl -n argocd get applications -A -o wide
run_and_capture "${OUTPUT_DIR}/${LABEL}-top-nodes.txt" kubectl top nodes
run_and_capture "${OUTPUT_DIR}/${LABEL}-top-pods.txt" kubectl top pods -A
run_and_capture "${OUTPUT_DIR}/${LABEL}-host-vcluster-services.txt" kubectl get svc -A

if [[ -f "${ROOT_DIR}/.state/cluster-state/kubeconfig-shared.yaml" ]]; then
  run_and_capture "${OUTPUT_DIR}/${LABEL}-shared-runtime.txt" kubectl --kubeconfig "${ROOT_DIR}/.state/cluster-state/kubeconfig-shared.yaml" -n processing get svc,pods,hpa,endpointslice -o wide
fi

if [[ -f "${ROOT_DIR}/.state/cluster-state/kubeconfig-abc.yaml" ]]; then
  run_and_capture "${OUTPUT_DIR}/${LABEL}-abc-runtime.txt" kubectl --kubeconfig "${ROOT_DIR}/.state/cluster-state/kubeconfig-abc.yaml" -n app get svc,pods,hpa -o wide
fi

if [[ -f "${ROOT_DIR}/.state/cluster-state/kubeconfig-xyz.yaml" ]]; then
  run_and_capture "${OUTPUT_DIR}/${LABEL}-xyz-runtime.txt" kubectl --kubeconfig "${ROOT_DIR}/.state/cluster-state/kubeconfig-xyz.yaml" -n app get svc,pods,hpa -o wide
fi

if [[ -x "${ROOT_DIR}/scripts/collect-vcluster-hpa-history.sh" ]]; then
  "${ROOT_DIR}/scripts/collect-vcluster-hpa-history.sh" --once >/dev/null 2>&1 || true
fi
