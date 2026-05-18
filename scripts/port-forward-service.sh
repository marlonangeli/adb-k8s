#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"

if [[ -f "${STATE_DIR}/dynamic.env" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dynamic.env" || true
fi

usage() {
  cat <<'EOF'
Launch kubectl port-forward for shared or tenant service.

Usage:
  scripts/port-forward-service.sh <service> [local-port]

Services:
  shared   processing/adb-interpolation-api  -> default local port 3000
  abc      app/adb-api                       -> default local port 3001

Examples:
  scripts/port-forward-service.sh shared
  scripts/port-forward-service.sh abc

Notes:
  - Uses kubeconfigs from .state/cluster-state
  - Keeps process attached; run inside tmux if desired
EOF
}

require_mise() {
  if ! command -v mise >/dev/null 2>&1; then
    echo "ERROR: mise command not found in PATH" >&2
    exit 1
  fi
}

require_file() {
  local file_path="$1"
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: kubeconfig not found: ${file_path}" >&2
    exit 1
  fi
}

resolve_target() {
  local target="$1"

  case "${target}" in
    shared)
      KUBECONFIG_PATH="${STATE_DIR}/kubeconfig-shared.yaml"
      TARGET_NAMESPACE="processing"
      TARGET_SERVICE="adb-interpolation-api"
      LOCAL_PORT="${2:-3000}"
      REMOTE_PORT="80"
      ;;
    abc)
      KUBECONFIG_PATH="${STATE_DIR}/kubeconfig-abc.yaml"
      TARGET_NAMESPACE="app"
      TARGET_SERVICE="adb-api"
      LOCAL_PORT="${2:-3001}"
      REMOTE_PORT="80"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown service '${target}'" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main() {
  local target="${1:-}"
  local requested_port="${2:-}"

  if [[ -z "${target}" ]]; then
    usage >&2
    exit 1
  fi

  require_mise
  resolve_target "${target}" "${requested_port}"
  require_file "${KUBECONFIG_PATH}"

  printf 'Port-forward %s -> http://127.0.0.1:%s\n' "${target}" "${LOCAL_PORT}"
  printf 'Kubeconfig: %s\n' "${KUBECONFIG_PATH}"
  printf 'Target: svc/%s namespace %s port %s\n' "${TARGET_SERVICE}" "${TARGET_NAMESPACE}" "${REMOTE_PORT}"

  exec mise exec -- kubectl \
    --kubeconfig "${KUBECONFIG_PATH}" \
    -n "${TARGET_NAMESPACE}" \
    port-forward "svc/${TARGET_SERVICE}" "${LOCAL_PORT}:${REMOTE_PORT}"
}

main "$@"
