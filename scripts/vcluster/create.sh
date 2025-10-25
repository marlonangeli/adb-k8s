#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Uso: $(basename "$0") [opções]

Cria ou atualiza um vCluster dentro do cluster host, aplicando políticas de rede
e publicando o kubeconfig para monitoramento quando o namespace "monitoring"
estiver disponível.

Opções:
  --tenant <id>           Identificador lógico do tenant (default: valor de --cluster)
  --cluster <nome>        Nome do vCluster (default: tenant ID)
  --namespace <ns>        Namespace host onde o vCluster será provisionado
                          (default: \${TENANT_NAMESPACE_PREFIX}<cluster>)
  --profile <private|shared>
                          Perfil de recursos/políticas (default: private)
  --state-key <nome>      Chave utilizada no dynamic.env para salvar o caminho do kubeconfig
  --publish-monitoring    Publica secret no namespace monitoring (default)
  --no-publish-monitoring Não publica secret no namespace monitoring
  --help                  Mostra esta ajuda
EOF
}

tenant=""
cluster=""
namespace=""
profile="private"
state_key=""
publish_monitoring=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      tenant="$2"; shift 2 ;;
    --cluster)
      cluster="$2"; shift 2 ;;
    --namespace)
      namespace="$2"; shift 2 ;;
    --profile)
      profile="$2"; shift 2 ;;
    --state-key)
      state_key="$2"; shift 2 ;;
    --publish-monitoring)
      publish_monitoring=1; shift ;;
    --no-publish-monitoring)
      publish_monitoring=0; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "opção desconhecida: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

[[ "${profile}" == "private" || "${profile}" == "shared" ]] || {
  echo "perfil inválido: ${profile}. Use private ou shared." >&2
  exit 1
}

vc::ensure_prereqs

[[ -n "${cluster}" ]] || cluster="${tenant}"
[[ -n "${cluster}" ]] || { echo "informe --cluster ou --tenant" >&2; exit 1; }
[[ -n "${tenant}" ]] || tenant="${cluster}"
vc::validate_cluster_name "${cluster}"
[[ -n "${namespace}" ]] || namespace="${TENANT_NAMESPACE_PREFIX}${cluster}"

vc::debug "Parâmetros recebidos: tenant=${tenant} cluster=${cluster} namespace=${namespace} profile=${profile}"

vc::ensure_namespace "${namespace}" "${tenant}" "${profile}"

vcluster_host="$(vc::hostname_for_cluster "${cluster}")"
vc::debug "Host sugerido para ${cluster}: ${vcluster_host}"
values_file="$(vc::values_for_profile "${profile}" "${namespace}" "${cluster}" "${vcluster_host}")"
vc::debug "Values temporário gerado em ${values_file}"

kubeconfig_tmp=$(mktemp)
register_tmp "${kubeconfig_tmp}"
existed=0
vc::debug "Validando existência do vcluster ${cluster} em ${namespace}"
if vcluster connect "${cluster}" -n "${namespace}" --print >"${kubeconfig_tmp}" 2>/dev/null; then
  existed=1
  vc::debug "vcluster ${cluster} encontrado; reaproveitando kubeconfig atual"
else
  rm -f "${kubeconfig_tmp}"
  vc::debug "vcluster ${cluster} inexistente; iniciando criação"
  if ! vcluster create "${cluster}" -n "${namespace}" --connect=false --expose -f "${values_file}"; then
    vc::debug "Comando 'vcluster create' falhou para ${cluster}. Conteúdo dos values:"
    vc::debug "$(sed 's/^/    /' "${values_file}")"
    exit 1
  fi
  kubeconfig_tmp=$(mktemp)
  register_tmp "${kubeconfig_tmp}"
  if ! vcluster connect "${cluster}" -n "${namespace}" --print >"${kubeconfig_tmp}"; then
    vc::debug "Falha ao conectar ao vcluster ${cluster} após criação."
    exit 1
  fi
fi

if [[ ! -s "${kubeconfig_tmp}" ]]; then
  vc::debug "Arquivo de kubeconfig vazio para ${cluster}"
  log "não foi possível obter o kubeconfig do vcluster ${cluster}"
  exit 1
fi

kubeconfig_path="${STATE_DIR}/kubeconfig-${cluster}.yaml"
mkdir -p "$(dirname "${kubeconfig_path}")"
mv "${kubeconfig_tmp}" "${kubeconfig_path}"
chmod 0600 "${kubeconfig_path}"
vc::debug "Kubeconfig de ${cluster} salvo em ${kubeconfig_path}"

vc::apply_network_policies "${namespace}" "${profile}"
vc::debug "Políticas de rede aplicadas para namespace ${namespace}"

if (( publish_monitoring )); then
  vc::publish_monitoring_secret "${cluster}" "${tenant}" "${profile}" "${kubeconfig_path}"
else
  vc::debug "Publicação no monitoring desabilitada para ${cluster}"
fi

default_state_key="$(vc::state_key "${cluster}")"
if [[ -n "${state_key}" ]]; then
  save_state_var "${state_key}" "${kubeconfig_path}"
  if [[ "${state_key}" != "${default_state_key}" ]]; then
    save_state_var "${default_state_key}" "${kubeconfig_path}"
  fi
else
  save_state_var "${default_state_key}" "${kubeconfig_path}"
fi

if [[ -n "${vcluster_host}" ]]; then
  save_state_var "$(vc::state_key "${cluster}" "HOST")" "${vcluster_host}"
  vc::debug "Host ${vcluster_host} registrado para ${cluster}"
fi

service_ip=$(vc::discover_service_ip "${namespace}" "${cluster}" || true)
if [[ -n "${service_ip}" ]]; then
  save_state_var "$(vc::state_key "${cluster}" "SERVICE_IP")" "${service_ip}"
  vc::debug "IP do Service detectado (${service_ip}) registrado para ${cluster}"
  if [[ "${profile}" == "private" ]]; then
    shared_key=$(vc::state_key "${SHARED_VCLUSTER_NAME}" "INTERPOLATION_HOST")
    shared_host="${!shared_key:-}"
    read -r api_host interpolation_host < <(vc::ensure_tenant_overlay "${cluster}" "${service_ip}" "${shared_host}")
    save_state_var "$(vc::state_key "${cluster}" "API_HOST")" "${api_host}"
    save_state_var "$(vc::state_key "${cluster}" "INTERPOLATION_HOST")" "${interpolation_host}"
    vc::debug "Overlays do tenant ${cluster} atualizados (API=${api_host}, interpolation=${interpolation_host})"
  else
    shared_host=$(vc::update_shared_overlay "${service_ip}")
    if [[ -n "${shared_host}" ]]; then
      save_state_var "$(vc::state_key "${cluster}" "INTERPOLATION_HOST")" "${shared_host}"
      vc::refresh_tenant_overlays "${shared_host}"
      vc::debug "Overlay compartilhado atualizado com host ${shared_host}"
    fi
  fi
else
  log "não foi possível determinar um IP para o serviço do vcluster ${cluster}; verifique o status do Service."
fi

if (( existed )); then
  log "vcluster ${cluster} (${profile}) atualizado; kubeconfig em ${kubeconfig_path}"
else
  log "vcluster ${cluster} (${profile}) criado; kubeconfig em ${kubeconfig_path}"
fi

vc::debug "Kubeconfig final salvo em ${kubeconfig_path}"
mkdir -p "${STATE_DIR}"
echo "${kubeconfig_path}" > "${STATE_DIR}/last-vcluster-kubeconfig"

exit 0
