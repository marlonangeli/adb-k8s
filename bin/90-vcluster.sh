#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="vcluster"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

VC_MANUAL_EXECUTION="${VC_MANUAL_EXECUTION:-1}"

require_commands kubectl envsubst
source "${ROOT_DIR}/scripts/vcluster/common.sh"

vc::ensure_prereqs
INGRESS_IP="${VC_INGRESS_IP}"

prompt_manual_execution() {
  local message="$1"; shift
  local -a cmd=("$@")

  if [[ "${VC_MANUAL_EXECUTION}" == "0" ]]; then
    log "${message} Execução automática habilitada (VC_MANUAL_EXECUTION=0)."
    "${cmd[@]}"
    return
  fi

  log "${message}"
  printf '  '
  local token
  for token in "${cmd[@]}"; do
    printf '%q ' "${token}"
  done
  printf '\n'

  if [[ ! -t 0 ]]; then
    log "terminal não interativo: execute o comando manualmente e rode novamente, ou use VC_MANUAL_EXECUTION=0 para execução automática."
    return 1
  fi

  read -rp $'Execute o comando acima em outro terminal e pressione ENTER para continuar...\n> ' _
}

IFS=' ' read -r -a TENANT_IDS <<<"${TENANTS:-tenant-a}"
vc::debug "Tenants alvo: ${TENANT_IDS[*]:-<nenhum>} ENABLE_SHARED_VCLUSTER=${ENABLE_SHARED_VCLUSTER}"

SHARED_VCLUSTER_NAME="${SHARED_VCLUSTER_NAME:-shared}"
SHARED_VCLUSTER_NAMESPACE="${SHARED_VCLUSTER_NAMESPACE:-vcluster-shared}"
ENABLE_SHARED_VCLUSTER="${ENABLE_SHARED_VCLUSTER:-1}"

VC_FORCE_RECREATE="${VC_FORCE_RECREATE:-0}"
VC_RESUME_FROM="${VC_RESUME_FROM:-}"
vc_resume_reached=0
if [[ -z "${VC_RESUME_FROM}" ]]; then
  vc_resume_reached=1
fi

for tenant in "${TENANT_IDS[@]}"; do
  [[ -n "${tenant}" ]] || continue
  cluster="${tenant}"
  state_key="$(vc::state_key "${cluster}")"
  if (( ! vc_resume_reached )); then
    if [[ "${cluster}" == "${VC_RESUME_FROM}" ]]; then
      vc_resume_reached=1
    else
      log "pulando ${cluster}; aguardando VC_RESUME_FROM=${VC_RESUME_FROM}"
      continue
    fi
  fi
  if [[ "${VC_FORCE_RECREATE}" != "1" ]] && vc::cluster_completed "${cluster}"; then
    log "vcluster ${cluster} já concluído anteriormente; pulando (VC_FORCE_RECREATE=1 para recriar)."
    continue
  fi
  vc::debug "Processando tenant ${tenant} (cluster=${cluster}) namespace=vcluster-${cluster}"
  [[ "${VC_FORCE_RECREATE}" == "1" ]] && vc::clear_cluster_checkpoint "${cluster}"
  kubeconfig_path="${STATE_DIR}/kubeconfig-${cluster}.yaml"
  before_ts=""
  if [[ -f "${kubeconfig_path}" ]]; then
    before_ts=$(stat -c %Y "${kubeconfig_path}" 2>/dev/null || echo "")
  fi
  create_cmd=(
    bash "${ROOT_DIR}/scripts/vcluster/create.sh"
    --tenant "${tenant}"
    --cluster "${cluster}"
    --namespace "vcluster-${cluster}"
    --profile private
    --state-key "${state_key}"
  )
  if ! prompt_manual_execution "Execução manual necessária para o vcluster ${cluster}." "${create_cmd[@]}"; then
    save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
    vc::clear_cluster_checkpoint "${cluster}"
    log "não foi possível concluir a etapa manual do vcluster ${cluster}."
    exit 1
  fi
  if [[ ! -f "${kubeconfig_path}" ]]; then
    save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
    vc::clear_cluster_checkpoint "${cluster}"
    log "kubeconfig não encontrado em ${kubeconfig_path}; confirme se o comando foi executado com sucesso."
    exit 1
  fi
  after_ts=$(stat -c %Y "${kubeconfig_path}" 2>/dev/null || echo "")
  if [[ -n "${before_ts}" && -n "${after_ts}" && "${after_ts}" == "${before_ts}" ]]; then
    save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
    vc::clear_cluster_checkpoint "${cluster}"
    log "kubeconfig em ${kubeconfig_path} não foi atualizado; verifique os resultados do comando manual."
    exit 1
  fi
  save_state_var "VCLUSTER_LAST_SUCCEEDED" "${cluster}"
  vc::mark_cluster_completed "${cluster}"
  log "kubeconfig para ${cluster}: ${kubeconfig_path}"
  api_host_key=$(vc::state_key "${cluster}" "API_HOST")
  interpolation_host_key=$(vc::state_key "${cluster}" "INTERPOLATION_HOST")
  api_host="${!api_host_key:-}"
  interpolation_host="${!interpolation_host_key:-}"
  if [[ -n "${api_host}" ]]; then
    log "host da API do tenant ${cluster}: http://${api_host}"
  fi
  if [[ -n "${interpolation_host}" ]]; then
    log "host de interpolação observado pelo tenant ${cluster}: http://${interpolation_host}"
  fi
done

if [[ "${ENABLE_SHARED_VCLUSTER}" == "1" ]]; then
  cluster="${SHARED_VCLUSTER_NAME}"
  state_key="$(vc::state_key "${cluster}")"
  if (( ! vc_resume_reached )); then
    if [[ "${cluster}" == "${VC_RESUME_FROM}" ]]; then
      vc_resume_reached=1
    else
      log "pulando ${cluster}; aguardando VC_RESUME_FROM=${VC_RESUME_FROM}"
      cluster=""
    fi
  fi
  if [[ -n "${cluster}" ]]; then
    vc::debug "Processando vcluster compartilhado ${cluster} namespace=${SHARED_VCLUSTER_NAMESPACE}"
    if [[ "${VC_FORCE_RECREATE}" != "1" ]] && vc::cluster_completed "${cluster}"; then
      log "vcluster ${cluster} já concluído anteriormente; pulando (VC_FORCE_RECREATE=1 para recriar)."
    else
      [[ "${VC_FORCE_RECREATE}" == "1" ]] && vc::clear_cluster_checkpoint "${cluster}"
      kubeconfig_path="${STATE_DIR}/kubeconfig-${cluster}.yaml"
      before_shared=""
      if [[ -f "${kubeconfig_path}" ]]; then
        before_shared=$(stat -c %Y "${kubeconfig_path}" 2>/dev/null || echo "")
      fi
      shared_cmd=(
        bash "${ROOT_DIR}/scripts/vcluster/create.sh"
        --tenant "shared"
        --cluster "${cluster}"
        --namespace "${SHARED_VCLUSTER_NAMESPACE}"
        --profile shared
        --state-key "${state_key}"
      )
      if ! prompt_manual_execution "Execução manual necessária para o vcluster compartilhado ${cluster}." "${shared_cmd[@]}"; then
        save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
        vc::clear_cluster_checkpoint "${cluster}"
        log "não foi possível concluir a etapa manual do vcluster compartilhado ${cluster}."
        exit 1
      fi
      if [[ ! -f "${kubeconfig_path}" ]]; then
        save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
        vc::clear_cluster_checkpoint "${cluster}"
        log "kubeconfig não encontrado em ${kubeconfig_path}; confirme a execução do comando manual."
        exit 1
      fi
      after_shared=$(stat -c %Y "${kubeconfig_path}" 2>/dev/null || echo "")
      if [[ -n "${before_shared}" && -n "${after_shared}" && "${after_shared}" == "${before_shared}" ]]; then
        save_state_var "VCLUSTER_LAST_FAILED" "${cluster}"
        vc::clear_cluster_checkpoint "${cluster}"
        log "kubeconfig em ${kubeconfig_path} não foi atualizado; verifique a execução manual."
        exit 1
      fi
      save_state_var "VCLUSTER_LAST_SUCCEEDED" "${cluster}"
      vc::mark_cluster_completed "${cluster}"
      log "kubeconfig para ${cluster}: ${kubeconfig_path}"
      shared_host_key=$(vc::state_key "${cluster}" "INTERPOLATION_HOST")
      shared_host="${!shared_host_key:-}"
      if [[ -n "${shared_host}" ]]; then
        log "host da API de interpolação compartilhada: http://${shared_host}"
      fi
    fi
  fi
fi

if [[ -n "${VC_RESUME_FROM}" && ${vc_resume_reached} -eq 0 ]]; then
  log "VC_RESUME_FROM=${VC_RESUME_FROM} não encontrado entre os clusters avaliados."
  exit 1
fi

if ((${#TENANT_IDS[@]})); then
  save_state_var "VCLUSTER_TENANTS" "${TENANT_IDS[*]}"
fi
if [[ "${ENABLE_SHARED_VCLUSTER}" == "1" ]]; then
  save_state_var "VCLUSTER_SHARED_NAME" "${SHARED_VCLUSTER_NAME}"
  save_state_var "VCLUSTER_SHARED_NAMESPACE" "${SHARED_VCLUSTER_NAMESPACE}"
fi

if [[ "${ENABLE_HUBBLE_INGRESS:-0}" == "1" ]]; then
  HUBBLE_HOSTNAME=$(resolve_hostname "${HUBBLE_HOST_OVERRIDE:-}" "hubble")
  HUBBLE_LOCAL_HOSTNAME=$(local_sslip_host "hubble")
  save_state_var "HUBBLE_HOSTNAME" "${HUBBLE_HOSTNAME}"
  save_state_var "HUBBLE_LOCAL_HOSTNAME" "${HUBBLE_LOCAL_HOSTNAME}"

  if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
    hubble_host_was_set=0
    if [[ ${HUBBLE_HOST+x} ]]; then
      hubble_host_was_set=1
      prev_hubble_host="${HUBBLE_HOST}"
    fi
    apply_certificate "kube-system" "hubble-tls" "hubble-tls" "${INGRESS_IP}" \
      "${HUBBLE_HOSTNAME}" "${HUBBLE_LOCAL_HOSTNAME}"

    hubble_local_host_was_set=0
    if [[ ${HUBBLE_LOCAL_HOST+x} ]]; then
      hubble_local_host_was_set=1
      prev_hubble_local_host="${HUBBLE_LOCAL_HOST}"
    fi
    export HUBBLE_HOST="${HUBBLE_HOSTNAME}"
    export HUBBLE_LOCAL_HOST="${HUBBLE_LOCAL_HOSTNAME}"
    hubble_ingress=$(render_template "${ROOT_DIR}/manifests/hubble.ingress.yaml")
    if (( hubble_host_was_set )); then
      export HUBBLE_HOST="${prev_hubble_host}"
    else
      unset HUBBLE_HOST
    fi
    if (( hubble_local_host_was_set )); then
      export HUBBLE_LOCAL_HOST="${prev_hubble_local_host}"
    else
      unset HUBBLE_LOCAL_HOST
    fi
    kubectl apply -f "${hubble_ingress}"
    log "Hubble UI disponível em https://${HUBBLE_HOSTNAME} e https://${HUBBLE_LOCAL_HOSTNAME}"
  else
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  ingressClassName: ${VCLUSTER_INGRESS_CLASS}
  rules:
  - host: ${HUBBLE_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hubble-ui
            port:
              number: 80
  - host: ${HUBBLE_LOCAL_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hubble-ui
            port:
              number: 80
EOF
    log "Hubble UI disponível em http://${HUBBLE_HOSTNAME} e http://${HUBBLE_LOCAL_HOSTNAME}"
  fi
else
  log "ENABLE_HUBBLE_INGRESS=0: publicação de Ingress do Hubble desabilitada no fluxo OKE."
fi

ok "${STEP}"
