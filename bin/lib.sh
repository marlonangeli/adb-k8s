#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/env.sh"

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"

log() { echo "[$(date +'%F %T')] $*" | tee -a "${LOG_FILE}"; }
ok() { touch "${STATE_DIR}/$1.ok"; log "ok: $1"; }
donep() { [[ -f "${STATE_DIR}/$1.ok" ]]; }

need_root() {
  [[ $(id -u) -eq 0 ]] || { echo "precisa ser root"; exit 1; }
}

wait_rollout() { # ns kind name
  kubectl -n "$1" rollout status "$2/$3" --timeout=5m
}

trap 'log "ERRO em linha $LINENO"; exit 1' ERR
