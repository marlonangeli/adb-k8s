#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Uso: $(basename "$0") --cluster <nome> [opções]

Remove um vCluster e os artefatos auxiliares gerados pela automação.

Opções:
  --cluster <nome>        Nome do vCluster (obrigatório)
  --namespace <ns>        Namespace host onde o vCluster está presente
                          (default: \${TENANT_NAMESPACE_PREFIX}<cluster>)
  --state-key <nome>      Chave a remover do dynamic.env (default: derivado do nome)
  --delete-namespace      Remove o namespace host após deletar o vCluster (default)
  --keep-namespace        Mantém o namespace host
  --keep-monitoring-secret
                          Mantém o secret de kubeconfig na namespace monitoring
  --help                  Mostra esta ajuda
EOF
}

cluster=""
namespace=""
state_key=""
delete_namespace=1
remove_monitoring_secret=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      cluster="$2"; shift 2 ;;
    --namespace)
      namespace="$2"; shift 2 ;;
    --state-key)
      state_key="$2"; shift 2 ;;
    --delete-namespace)
      delete_namespace=1; shift ;;
    --keep-namespace)
      delete_namespace=0; shift ;;
    --keep-monitoring-secret)
      remove_monitoring_secret=0; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "opção desconhecida: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

[[ -n "${cluster}" ]] || { echo "informe --cluster" >&2; usage >&2; exit 1; }

vc::ensure_prereqs

[[ -n "${namespace}" ]] || namespace="${TENANT_NAMESPACE_PREFIX}${cluster}"
[[ -n "${state_key}" ]] || state_key="$(vc::state_key "${cluster}")"
vc::debug "Iniciando remoção do vcluster: cluster=${cluster} namespace=${namespace} stateKey=${state_key} deleteNamespace=${delete_namespace} removeMonitoringSecret=${remove_monitoring_secret}"

if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
  log "namespace ${namespace} não encontrado; nada a remover."
  vc::debug "Namespace ${namespace} ausente; encerrando remoção lógica."
else
  vc::debug "Namespace ${namespace} presente; executando vcluster delete ${cluster}"
  if ! vcluster delete "${cluster}" -n "${namespace}" --delete-namespace=false >/dev/null 2>&1; then
    log "vcluster ${cluster} não encontrado em ${namespace}; prosseguindo com a limpeza manual."
    vc::debug "vcluster delete retornou código de erro para ${cluster}; provável ausente."
  else
    log "vcluster ${cluster} removido de ${namespace}"
  fi
fi

if (( delete_namespace )); then
  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    vc::debug "Excluindo namespace ${namespace} (wait=false)"
    kubectl delete namespace "${namespace}" --wait=false
    log "namespace ${namespace} marcada para remoção."
  fi
else
  vc::debug "Mantendo namespace ${namespace} conforme solicitado"
fi

kubeconfig_path="${STATE_DIR}/kubeconfig-${cluster}.yaml"
if [[ -f "${kubeconfig_path}" ]]; then
  vc::debug "Removendo kubeconfig local ${kubeconfig_path}"
  rm -f "${kubeconfig_path}"
  log "kubeconfig ${kubeconfig_path} removido."
else
  vc::debug "Nenhum kubeconfig encontrado em ${kubeconfig_path}"
fi

remove_state_var "${state_key}"
vc::debug "Variável de estado ${state_key} removida de ${DYNAMIC_ENV}"
remove_state_var "$(vc::state_key "${cluster}" "SERVICE_IP")"
remove_state_var "$(vc::state_key "${cluster}" "HOST")"
remove_state_var "$(vc::state_key "${cluster}" "API_HOST")"
remove_state_var "$(vc::state_key "${cluster}" "INTERPOLATION_HOST")"

if (( remove_monitoring_secret )); then
  vc::debug "Removendo secret de monitoring do cluster ${cluster}"
  vc::cleanup_monitoring_secret "${cluster}"
else
  vc::debug "Secret de monitoring preservado para ${cluster}"
fi

log "limpeza concluída para o vcluster ${cluster}."
