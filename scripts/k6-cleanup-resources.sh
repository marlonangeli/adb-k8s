#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

declare -a NAMESPACES=(vcluster-shared vcluster-abc)
declare -a CUSTOM_NAMESPACES=()

usage() {
  cat <<'EOF'
Delete stale k6 Jobs and ConfigMaps from host vCluster namespaces.

Usage:
  scripts/k6-cleanup-resources.sh [--namespace <name>]...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)
      CUSTOM_NAMESPACES+=("$2")
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

if ((${#CUSTOM_NAMESPACES[@]} > 0)); then
  NAMESPACES=("${CUSTOM_NAMESPACES[@]}")
fi

if [[ -f "${ROOT_DIR}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/env.sh"
fi

cleanup_namespace() {
  local namespace="$1"
  local cm_name

  if ! mise exec -- kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    echo "skip missing namespace: ${namespace}"
    return
  fi

  echo "cleanup k6 resources in ${namespace}"
  mise exec -- kubectl -n "${namespace}" delete job -l app=k6-runner --ignore-not-found >/dev/null 2>&1 || true
  mise exec -- kubectl -n "${namespace}" delete configmap -l app=k6-runner --ignore-not-found >/dev/null 2>&1 || true

  while IFS= read -r cm_name; do
    [[ -n "${cm_name}" ]] || continue
    mise exec -- kubectl -n "${namespace}" delete "${cm_name}" --ignore-not-found >/dev/null 2>&1 || true
  done < <(mise exec -- kubectl -n "${namespace}" get configmap -o name 2>/dev/null | grep -E '^configmap/k6-.+-(root|lib|shared|payloads)$' || true)
}

for namespace in "${NAMESPACES[@]}"; do
  cleanup_namespace "${namespace}"
done
