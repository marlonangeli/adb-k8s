#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
need_root

STEP="join-workers"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

JOIN_SCRIPT_PATH="${JOIN_SCRIPT_PATH:-/root/join-worker.sh}"
[[ -f "${JOIN_SCRIPT_PATH}" ]] || { log "arquivo de join não encontrado: ${JOIN_SCRIPT_PATH}"; exit 1; }

read -ra join_args <<<"$(<"${JOIN_SCRIPT_PATH}")"
(( ${#join_args[@]} )) || { log "comando de join vazio em ${JOIN_SCRIPT_PATH}"; exit 1; }

declare -A existing_nodes=()
while IFS= read -r ip; do
  [[ -z "${ip}" ]] && continue
  existing_nodes["${ip}"]=1
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' || true)

joined_any=false
for host in "${WORKERS[@]}"; do
  if [[ -n "${existing_nodes[${host}]:-}" ]]; then
    log "worker ${host} já presente no cluster; pulando"
    continue
  fi
  log "adicionando worker ${host}"
  run_remote_script "${host}" "scripts/worker-join.sh" "${join_args[@]}"
  joined_any=true
done

if [[ "${joined_any}" == false ]]; then
  log "nenhum worker novo para adicionar"
fi

ok "${STEP}"
