#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP_RUNNING="true"
CHILD_PID=""
RETRY_DELAY_SECONDS="${PORT_FORWARD_RETRY_DELAY_SECONDS:-2}"

usage() {
  cat <<'EOF'
Keep kubectl port-forward running for shared or tenant service.

Usage:
  scripts/port-forward-service-loop.sh <service> [local-port]

Examples:
  scripts/port-forward-service-loop.sh shared
  scripts/port-forward-service-loop.sh abc
  scripts/port-forward-service-loop.sh xyz 4002

Environment:
  PORT_FORWARD_RETRY_DELAY_SECONDS   Delay before reconnect (default: 2)

Notes:
  - Reuses scripts/port-forward-service.sh
  - Restarts when port-forward exits unexpectedly
  - Stop with Ctrl+C
EOF
}

require_positive_integer() {
  local value="$1"
  local label="$2"

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${label} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

validate_port() {
  local value="$1"
  local label="$2"

  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "ERROR: ${label} must be a valid TCP port: ${value}" >&2
    exit 1
  fi
}

stop_child() {
  if [[ -n "${CHILD_PID}" ]] && kill -0 "${CHILD_PID}" >/dev/null 2>&1; then
    kill "${CHILD_PID}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  stop_child

  if [[ -n "${CHILD_PID}" ]]; then
    wait "${CHILD_PID}" 2>/dev/null || true
  fi
}

request_stop() {
  KEEP_RUNNING="false"
  stop_child
}

is_interrupt_exit_code() {
  local exit_code="$1"

  [[ "${exit_code}" -eq 130 || "${exit_code}" -eq 143 ]]
}

run_port_forward() {
  local service="$1"
  local local_port="${2:-}"
  local -a args=("${service}")

  if [[ -n "${local_port}" ]]; then
    args+=("${local_port}")
  fi

  "${SCRIPT_DIR}/port-forward-service.sh" "${args[@]}" &
  CHILD_PID=$!

  if wait "${CHILD_PID}"; then
    CHILD_PID=""
    return 0
  fi

  local exit_code=$?
  CHILD_PID=""
  return "${exit_code}"
}

main() {
  local service="${1:-}"
  local local_port="${2:-}"
  local exit_code="0"

  case "${service}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  if [[ -z "${service}" ]]; then
    usage >&2
    exit 1
  fi

  require_positive_integer "${RETRY_DELAY_SECONDS}" "PORT_FORWARD_RETRY_DELAY_SECONDS"

  if [[ -n "${local_port}" ]]; then
    validate_port "${local_port}" "local port"
  fi

  trap request_stop INT TERM
  trap cleanup EXIT

  while [[ "${KEEP_RUNNING}" == "true" ]]; do
    printf 'Starting port-forward loop for %s\n' "${service}" >&2

    if run_port_forward "${service}" "${local_port}"; then
      exit_code=0
    else
      exit_code=$?
    fi

    if [[ "${KEEP_RUNNING}" != "true" ]] || is_interrupt_exit_code "${exit_code}"; then
      break
    fi

    printf 'Port-forward stopped with exit code %s. Restarting in %ss...\n' "${exit_code}" "${RETRY_DELAY_SECONDS}" >&2
    sleep "${RETRY_DELAY_SECONDS}"
  done
}

main "$@"
