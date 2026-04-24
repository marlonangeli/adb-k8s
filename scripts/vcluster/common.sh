#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${ROOT_DIR}/bin/lib.sh"

# shellcheck disable=SC2034 # exported for helper scripts
VC_STEP_NAME="${VC_STEP_NAME:-vcluster}"
: "${VC_PROGRESS_DIR:=${STATE_DIR}/vcluster-progress}"
: "${VC_DEBUG:=1}"

VC_COLOR_YELLOW=$'\033[33m'
VC_COLOR_RESET=$'\033[0m'

vc::debug() {
  (( VC_DEBUG )) || return 0
  local timestamp msg
  timestamp="$(date +'%F %T')"
  msg="[vc-debug] $*"
  printf '%s[%s] %s%s\n' "${VC_COLOR_YELLOW}" "${timestamp}" "${msg}" "${VC_COLOR_RESET}" >&2
  printf '[%s] %s\n' "${timestamp}" "${msg}" >>"${LOG_FILE}"
}

vc::phase() {
  local cluster="$1" step="$2"
  mkdir -p "${VC_PROGRESS_DIR}"
  printf '%s\n' "${step}" >"${VC_PROGRESS_DIR}/${cluster}.phase"
}

vc::phase_fail() {
  local cluster="$1" msg="$2"
  mkdir -p "${VC_PROGRESS_DIR}"
  printf '%s\n' "${msg}" >"${VC_PROGRESS_DIR}/${cluster}.error"
}

vc::load_defaults() {
  : "${TENANT_NAMESPACE_PREFIX:=vcluster-}"
  : "${TENANT_TARGET_NAMESPACE:=app}"
  : "${SHARED_VCLUSTER_NAME:=shared}"
  : "${SHARED_VCLUSTER_NAMESPACE:=vcluster-shared}"
  : "${ENABLE_SHARED_VCLUSTER:=1}"

  : "${PRIVATE_API_REQUEST_CPU:=200m}"
  : "${PRIVATE_API_REQUEST_MEMORY:=256Mi}"
  : "${PRIVATE_API_LIMIT_CPU:=600m}"
  : "${PRIVATE_API_LIMIT_MEMORY:=512Mi}"
  : "${PRIVATE_CONTROLLER_MANAGER_REQUEST_CPU:=150m}"
  : "${PRIVATE_CONTROLLER_MANAGER_REQUEST_MEMORY:=192Mi}"
  : "${PRIVATE_CONTROLLER_MANAGER_LIMIT_CPU:=400m}"
  : "${PRIVATE_CONTROLLER_MANAGER_LIMIT_MEMORY:=384Mi}"
  : "${PRIVATE_SCHEDULER_REQUEST_CPU:=100m}"
  : "${PRIVATE_SCHEDULER_REQUEST_MEMORY:=128Mi}"
  : "${PRIVATE_SCHEDULER_LIMIT_CPU:=300m}"
  : "${PRIVATE_SCHEDULER_LIMIT_MEMORY:=256Mi}"
  : "${PRIVATE_SYNCER_REQUEST_CPU:=200m}"
  : "${PRIVATE_SYNCER_REQUEST_MEMORY:=256Mi}"
  : "${PRIVATE_SYNCER_LIMIT_CPU:=500m}"
  : "${PRIVATE_SYNCER_LIMIT_MEMORY:=512Mi}"
  : "${PRIVATE_CONTROL_PLANE_REPLICAS:=1}"
  : "${PRIVATE_CONTROL_PLANE_REQUEST_CPU:=450m}"
  : "${PRIVATE_CONTROL_PLANE_REQUEST_MEMORY:=576Mi}"
  : "${PRIVATE_CONTROL_PLANE_LIMIT_CPU:=1300m}"
  : "${PRIVATE_CONTROL_PLANE_LIMIT_MEMORY:=1152Mi}"
  : "${PRIVATE_CONTROL_PLANE_K8S_VERSION:=}"

  : "${SHARED_API_REQUEST_CPU:=250m}"
  : "${SHARED_API_REQUEST_MEMORY:=320Mi}"
  : "${SHARED_API_LIMIT_CPU:=700m}"
  : "${SHARED_API_LIMIT_MEMORY:=640Mi}"
  : "${SHARED_CONTROLLER_MANAGER_REQUEST_CPU:=180m}"
  : "${SHARED_CONTROLLER_MANAGER_REQUEST_MEMORY:=256Mi}"
  : "${SHARED_CONTROLLER_MANAGER_LIMIT_CPU:=450m}"
  : "${SHARED_CONTROLLER_MANAGER_LIMIT_MEMORY:=448Mi}"
  : "${SHARED_SCHEDULER_REQUEST_CPU:=120m}"
  : "${SHARED_SCHEDULER_REQUEST_MEMORY:=160Mi}"
  : "${SHARED_SCHEDULER_LIMIT_CPU:=320m}"
  : "${SHARED_SCHEDULER_LIMIT_MEMORY:=320Mi}"
  : "${SHARED_SYNCER_REQUEST_CPU:=220m}"
  : "${SHARED_SYNCER_REQUEST_MEMORY:=256Mi}"
  : "${SHARED_SYNCER_LIMIT_CPU:=520m}"
  : "${SHARED_SYNCER_LIMIT_MEMORY:=512Mi}"
  : "${SHARED_CONTROL_PLANE_REPLICAS:=1}"
  : "${SHARED_CONTROL_PLANE_REQUEST_CPU:=550m}"
  : "${SHARED_CONTROL_PLANE_REQUEST_MEMORY:=736Mi}"
  : "${SHARED_CONTROL_PLANE_LIMIT_CPU:=1470m}"
  : "${SHARED_CONTROL_PLANE_LIMIT_MEMORY:=1408Mi}"
  : "${SHARED_CONTROL_PLANE_K8S_VERSION:=}"

  : "${VCLUSTER_SERVICE_TYPE:=LoadBalancer}"
  : "${VCLUSTER_INGRESS_CLASS:=native-oci}"
  : "${VCLUSTER_ENABLE_INGRESS:=0}"
  : "${VCLUSTER_HOST_TEMPLATE:=vcluster-[cluster].[slug].${BASE_DOMAIN:-adb.internal}}"
  : "${VCLUSTER_LOAD_BALANCER_TYPE:=nlb}"
  : "${VCLUSTER_LOAD_BALANCER_INTERNAL:=true}"
  : "${VCLUSTER_LB_SECURITY_RULE_MODE:=NSG}"
  : "${SHARED_INTERPOLATION_HOST:=}"
  : "${VC_DISABLE_NETWORK_POLICIES:=0}"
}

vc::make_host() {
  local cluster="$1" slug="$2"
  local template host
  template="${VCLUSTER_HOST_TEMPLATE}"
  host="${template//[cluster]/${cluster}}"
  host="${host//[slug]/${slug}}"
  printf '%s\n' "${host}"
}

vc::ensure_prereqs() {
  vc::load_defaults
  require_commands kubectl envsubst
  ensure_vcluster_cli
  require_commands vcluster

  mkdir -p "${VC_PROGRESS_DIR}"

  : "${VC_TENANT_MANIFEST_ROOT:=${ROOT_DIR}/adb-api-3/k8s/tenants}"
  : "${VC_INTERPOLATION_OVERLAY_DIR:=${ROOT_DIR}/adb-interpolation-api/k8s/overlays/shared}"

  VC_INGRESS_IP="$(current_ingress_ip || true)"
  if [[ -n "${VC_INGRESS_IP}" ]]; then
    vc::debug "Ingress IP detectado: ${VC_INGRESS_IP}"
    VC_INGRESS_SLUG="$(sslip_slug "${VC_INGRESS_IP}")"
    vc::debug "Slug do ingress: ${VC_INGRESS_SLUG}"
  else
    VC_INGRESS_SLUG="internal"
    vc::debug "Ingress IP não definido; usando slug padrão '${VC_INGRESS_SLUG}'"
  fi
  vc::debug "TENANT_NAMESPACE_PREFIX=${TENANT_NAMESPACE_PREFIX} TARGET_NAMESPACE=${TENANT_TARGET_NAMESPACE}"

  VC_K8S_API_IP="$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -n "${VC_K8S_API_IP}" ]]; then
    vc::debug "ClusterIP do serviço kubernetes: ${VC_K8S_API_IP}"
  else
    log "Não foi possível descobrir o ClusterIP do serviço kubernetes; verifique permissões."
  fi

  if kubectl get ns monitoring >/dev/null 2>&1; then
    VC_MONITORING_READY=1
    vc::debug "Namespace monitoring encontrado; secrets serão publicados."
  else
    VC_MONITORING_READY=0
    log "namespace monitoring não encontrado; kubeconfigs dos vclusters não serão publicados para observabilidade."
  fi
}

vc::discover_shared_interpolation_host() {
  local shared_kubeconfig="${VCLUSTER_SHARED_KUBECONFIG:-${STATE_DIR}/kubeconfig-${SHARED_VCLUSTER_NAME}.yaml}"
  local host

  if [[ -f "${shared_kubeconfig}" ]]; then
    host="$(kubectl --kubeconfig "${shared_kubeconfig}" -n processing get svc adb-interpolation-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${host}" && "${host}" != "<no value>" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi

    host="$(kubectl --kubeconfig "${shared_kubeconfig}" -n processing get svc adb-interpolation-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${host}" && "${host}" != "<no value>" ]]; then
      printf '%s\n' "${host}"
      return 0
    fi
  fi

  if [[ -n "${SHARED_INTERPOLATION_HOST}" ]]; then
    printf '%s\n' "${SHARED_INTERPOLATION_HOST}"
    return 0
  fi

  printf '%s\n' 'adb-interpolation-api.processing.svc.cluster.local'
}

vc::cluster_checkpoint() {
  local cluster="$1"
  printf '%s/%s.ok\n' "${VC_PROGRESS_DIR}" "${cluster}"
}

vc::cluster_completed() {
  local cluster="$1"
  local checkpoint
  checkpoint="$(vc::cluster_checkpoint "${cluster}")"
  [[ -f "${checkpoint}" ]]
}

vc::mark_cluster_completed() {
  local cluster="$1"
  mkdir -p "${VC_PROGRESS_DIR}"
  touch "$(vc::cluster_checkpoint "${cluster}")"
  vc::debug "Checkpoint registrado para ${cluster}"
}

vc::clear_cluster_checkpoint() {
  local cluster="$1"
  local checkpoint
  checkpoint="$(vc::cluster_checkpoint "${cluster}")"
  if [[ -f "${checkpoint}" ]]; then
    rm -f "${checkpoint}"
    vc::debug "Checkpoint removido para ${cluster}"
  fi
}

vc::state_key() {
  local cluster="$1"
  local suffix="${2:-KUBECONFIG}"
  local key="VCLUSTER_${cluster^^}_${suffix}"
  key="${key//-/_}"
  printf '%s\n' "${key}"
}

vc::hostname_for_cluster() {
  local cluster="$1"
  local slug="${VC_INGRESS_SLUG:-internal}"
  vc::debug "cluster: ${cluster}"
  vc::debug "VC_INGRESS_SLUG: ${VC_INGRESS_SLUG}"
  vc::debug "slug: ${slug}"
  local host
  host="$(vc::make_host "${cluster}" "${slug}")"
  vc::debug "host: ${host}"
  printf '%s\n' "${host}"
}

vc::validate_cluster_name() {
  local cluster="$1"
  if [[ ! "${cluster}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    log "nome inválido para vcluster: ${cluster}. Utilize apenas minúsculas, números e hífens."
    exit 1
  fi
}

vc::ensure_namespace() {
  local namespace="$1"
  local tenant="$2"
  local role="$3"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    vc::debug "Criando namespace ${namespace} para tenant=${tenant} role=${role}"
    kubectl create namespace "${namespace}" >/dev/null
  else
    vc::debug "Namespace ${namespace} já existe; aplicando rótulos para tenant=${tenant} role=${role}"
  fi
  kubectl label namespace "${namespace}" \
    "adb.tenancy/tenant=${tenant}" \
    "adb.tenancy/role=${role}" \
    --overwrite >/dev/null
}

vc::values_for_profile() {
  local profile="$1"
  local namespace="$2"
  local host="${3:-}"
  local cp_request_cpu cp_request_memory cp_limit_cpu cp_limit_memory cp_replicas cp_k8s_version
  local syncer_request_cpu syncer_request_memory syncer_limit_cpu syncer_limit_memory
  local ingress_enabled="false"
  (( VCLUSTER_ENABLE_INGRESS )) && ingress_enabled="true"
  if [[ -n "${host}" ]]; then
    vc::debug "Configurando host do vcluster para ${host}"
  fi

  if [[ "${profile}" == "private" ]]; then
    cp_replicas="${PRIVATE_CONTROL_PLANE_REPLICAS}"
    cp_request_cpu="${PRIVATE_CONTROL_PLANE_REQUEST_CPU}"
    cp_request_memory="${PRIVATE_CONTROL_PLANE_REQUEST_MEMORY}"
    cp_limit_cpu="${PRIVATE_CONTROL_PLANE_LIMIT_CPU}"
    cp_limit_memory="${PRIVATE_CONTROL_PLANE_LIMIT_MEMORY}"
    cp_k8s_version="${PRIVATE_CONTROL_PLANE_K8S_VERSION}"
    syncer_request_cpu="${PRIVATE_SYNCER_REQUEST_CPU}"
    syncer_request_memory="${PRIVATE_SYNCER_REQUEST_MEMORY}"
    syncer_limit_cpu="${PRIVATE_SYNCER_LIMIT_CPU}"
    syncer_limit_memory="${PRIVATE_SYNCER_LIMIT_MEMORY}"
  else
    cp_replicas="${SHARED_CONTROL_PLANE_REPLICAS}"
    cp_request_cpu="${SHARED_CONTROL_PLANE_REQUEST_CPU}"
    cp_request_memory="${SHARED_CONTROL_PLANE_REQUEST_MEMORY}"
    cp_limit_cpu="${SHARED_CONTROL_PLANE_LIMIT_CPU}"
    cp_limit_memory="${SHARED_CONTROL_PLANE_LIMIT_MEMORY}"
    cp_k8s_version="${SHARED_CONTROL_PLANE_K8S_VERSION}"
    syncer_request_cpu="${SHARED_SYNCER_REQUEST_CPU}"
    syncer_request_memory="${SHARED_SYNCER_REQUEST_MEMORY}"
    syncer_limit_cpu="${SHARED_SYNCER_LIMIT_CPU}"
    syncer_limit_memory="${SHARED_SYNCER_LIMIT_MEMORY}"
  fi
  vc::debug "Gerando values para profile=${profile} namespace=${namespace} (cp requests=${cp_request_cpu}/${cp_request_memory})"

  local tmpdir tmp
  tmpdir="${STATE_DIR}/vcluster-values"
  mkdir -p "${tmpdir}"
  tmp=$(mktemp "${tmpdir}/${profile}.${namespace}.XXXX.yaml")
  register_tmp "${tmp}"

  {
    cat <<EOF
controlPlane:
  distro:
    k8s:
      enabled: true
EOF
    if [[ -n "${cp_k8s_version}" ]]; then
      cat <<EOF
      version: ${cp_k8s_version}
EOF
    fi
    cat <<EOF
  coredns:
    deployment:
      image: ${VCLUSTER_COREDNS_IMAGE}

  statefulSet:
    highAvailability:
      replicas: ${cp_replicas}
    persistence:
      volumeClaim:
        enabled: false
    resources:
      requests:
        cpu: ${cp_request_cpu}
        memory: ${cp_request_memory}
      limits:
        cpu: ${cp_limit_cpu}
        memory: ${cp_limit_memory}

  service:
    enabled: true
    spec:
      type: ${VCLUSTER_SERVICE_TYPE}
EOF
    if [[ "${VCLUSTER_SERVICE_TYPE}" == "LoadBalancer" ]]; then
      cat <<EOF
    annotations:
      oci.oraclecloud.com/load-balancer-type: "${VCLUSTER_LOAD_BALANCER_TYPE}"
      oci-network-load-balancer.oraclecloud.com/internal: "${VCLUSTER_LOAD_BALANCER_INTERNAL}"
      oci.oraclecloud.com/security-rule-management-mode: "${VCLUSTER_LB_SECURITY_RULE_MODE}"
EOF
    fi
    if [[ -n "${host}" ]]; then
      cat <<EOF
  # proxy:
  #   extraSANs:
  #     - ${host}
  ingress:
    enabled: ${ingress_enabled}
    host: ${host}
    spec:
      ingressClassName: ${VCLUSTER_INGRESS_CLASS}
EOF
    fi
    cat <<EOF

sync:
  toHost:
    services:
      enabled: true
    endpoints:
      enabled: true
    pods:
      enabled: true
      rewriteHosts:
        enabled: true
    configMaps:
      enabled: true
      all: false
    secrets:
      enabled: true
      all: false
    persistentVolumeClaims:
      enabled: true
    ingresses:
      enabled: ${ingress_enabled}
  fromHost:
    events:
      enabled: true
    ingressClasses:
      enabled: ${ingress_enabled}
EOF
  } >"${tmp}"
  printf '%s\n' "${tmp}"
}

vc::vcluster_service_name() {
  local namespace="$1"
  local cluster="$2"
  local selector="vcluster.loft.sh/managed-by=${cluster}"
  local svc="" candidates first=""

  if kubectl -n "${namespace}" get svc "${cluster}" >/dev/null 2>&1; then
    svc="${cluster}"
  elif kubectl -n "${namespace}" get svc "vcluster-${cluster}" >/dev/null 2>&1; then
    svc="vcluster-${cluster}"
  else
    candidates=$(kubectl -n "${namespace}" get svc -l "app=vcluster,release=${cluster}" -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [[ -z "${candidates}" ]]; then
      candidates=$(kubectl -n "${namespace}" get svc -l "${selector}" -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    fi
    if [[ -n "${candidates}" ]]; then
      while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        svc="${candidate}"
        break
      done <<<"${candidates}"
    fi
    if [[ -z "${svc}" ]]; then
      svc=$(kubectl -n "${namespace}" get svc -l "app=vcluster,release=${cluster}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [[ -z "${svc}" ]]; then
      svc=$(kubectl -n "${namespace}" get svc -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
  fi

  if [[ -z "${svc}" ]]; then
    if kubectl -n "${namespace}" get svc "${cluster}" >/dev/null 2>&1; then
      svc="${cluster}"
    elif kubectl -n "${namespace}" get svc "vcluster-${cluster}" >/dev/null 2>&1; then
      svc="vcluster-${cluster}"
    fi
  fi
  vc::debug "Service associado a ${cluster}/${namespace}: ${svc:-nenhum}"
  printf '%s\n' "${svc}"
}

vc::discover_service_ip() {
  local namespace="$1"
  local cluster="$2"
  local svc="" ip external_ip cluster_ip

  for attempt in {1..12}; do
    svc=$(vc::vcluster_service_name "${namespace}" "${cluster}")
    [[ -n "${svc}" ]] && break
    vc::debug "Service principal ainda não disponível para ${cluster}; aguardando..."
    sleep 5
  done
  if [[ -z "${svc}" ]]; then
    vc::debug "Nenhum Service encontrado para ${cluster} em ${namespace}"
    return 1
  fi

  vc::debug "Aguardando IP para Service ${namespace}/${svc}"
  external_ip=$(wait_for_lb_ip "${namespace}" "${svc}" 180 || true)
  cluster_ip=$(kubectl -n "${namespace}" get svc "${svc}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

  if [[ -n "${external_ip}" ]]; then
    ip="${external_ip}"
    vc::debug "IP externo detectado para ${cluster}: ${external_ip}"
  elif [[ -n "${cluster_ip}" ]]; then
    ip="${cluster_ip}"
    vc::debug "Utilizando ClusterIP ${cluster_ip} para ${cluster}"
  else
    vc::debug "Não foi possível determinar IP para ${cluster}/${namespace}"
    return 1
  fi

  if [[ -n "${cluster_ip}" ]]; then
    save_state_var "$(vc::state_key "${cluster}" "SERVICE_CLUSTER_IP")" "${cluster_ip}"
  fi

  printf '%s\n' "${ip}"
}

vc::ensure_tenant_overlay() {
  local tenant="$1"
  local service_ip="$2"
  local shared_host="${3:-}"

  local api_host interpolation_host
  api_host="adb-api.${TENANT_TARGET_NAMESPACE}.svc.cluster.local"
  if [[ -n "${shared_host}" ]]; then
    interpolation_host="${shared_host}"
  else
    interpolation_host="$(vc::discover_shared_interpolation_host)"
  fi

  if [[ ! -d "${VC_TENANT_MANIFEST_ROOT}" ]]; then
    vc::debug "VC_TENANT_MANIFEST_ROOT inexistente (${VC_TENANT_MANIFEST_ROOT}); pulando atualização de overlay para ${tenant}."
    printf '%s %s\n' "${api_host}" "${interpolation_host}"
    return 0
  fi

  local overlay_dir

  overlay_dir="${VC_TENANT_MANIFEST_ROOT}/${tenant}"
  mkdir -p "${overlay_dir}"
  vc::debug "Atualizando overlay do tenant ${tenant} em ${overlay_dir} (Service IP=${service_ip})"

  local kustom_file="${overlay_dir}/kustomization.yaml"
  cat >"${kustom_file}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${TENANT_TARGET_NAMESPACE}
resources:
  - ../../base
generatorOptions:
  disableNameSuffixHash: true
configMapGenerator:
  - name: app-settings
    behavior: replace
    envs:
      - app.env
secretGenerator:
  - name: db-credentials
    behavior: replace
    envs:
      - secrets.env
patches:
  - path: configmap-routing-patch.yaml
EOF

  cat >"${overlay_dir}/app.env" <<EOF
# Arquivo gerado automaticamente por scripts/vcluster/create.sh
TENANT_ID=${tenant}
PUBLIC_BASE_URL=http://${api_host}
INTERPOLATION_BASE_URL=http://${interpolation_host}
INTERPOLATION_LOAD_BALANCER_MODE=least_conn
JAVA_OPTS=-Xms256m -Xmx768m
JPA_DDL_AUTO=none
HIBERNATE_DIALECT_RUNTIME=org.hibernate.spatial.dialect.postgis.PostgisPG10Dialect
HIBERNATE_DIALECT_SEED=org.hibernate.dialect.PostgreSQLDialect
JPA_DDL_AUTO_SEED=create
SEED_EXTRA_ARGS=
EOF

  if [[ ! -f "${overlay_dir}/secrets.env" ]]; then
    cat >"${overlay_dir}/secrets.env" <<'EOF'
POSTGRES_DB=adb_tenant_sample
POSTGRES_USER=adb_user
POSTGRES_PASSWORD=CHANGE_ME_STRONG_PASSWORD
DB_NAME=adb_tenant_sample
DB_USERNAME=adb_user
DB_PASSWORD=CHANGE_ME_STRONG_PASSWORD
API_TOKEN_KEY=CHANGE_ME_TOKEN
API_TOKEN_EXPIRES=3600
EOF
    log "arquivo ${overlay_dir}/secrets.env criado com valores padrão; ajuste antes do deploy."
  fi

  cat >"${overlay_dir}/configmap-routing-patch.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-settings
data:
  PUBLIC_BASE_URL: http://${api_host}
  INTERPOLATION_BASE_URL: http://${interpolation_host}
EOF

  vc::debug "Hosts do tenant ${tenant}: API=${api_host} Interpolation=${interpolation_host}"
  printf '%s %s\n' "${api_host}" "${interpolation_host}"
}

vc::update_shared_overlay() {
  local service_ip="$1"

  local interpolation_host
  interpolation_host="$(vc::discover_shared_interpolation_host)"

  if [[ ! -d "${VC_INTERPOLATION_OVERLAY_DIR}" ]]; then
    vc::debug "VC_INTERPOLATION_OVERLAY_DIR inexistente (${VC_INTERPOLATION_OVERLAY_DIR}); pulando atualização de overlay compartilhado."
    printf '%s\n' "${interpolation_host}"
    return 0
  fi

  vc::debug "Atualizando overlay compartilhado com Service IP=${service_ip} host=${interpolation_host}"

  cat >"${VC_INTERPOLATION_OVERLAY_DIR}/settings.env" <<EOF
# Arquivo gerado automaticamente por scripts/vcluster/create.sh
PUBLIC_BASE_URL=http://${interpolation_host}
LOAD_BALANCER_MODE=least_conn
MAX_CONCURRENCY=400
EOF

  cat >"${VC_INTERPOLATION_OVERLAY_DIR}/configmap-routing-patch.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: interpolation-settings
data:
  PUBLIC_BASE_URL: http://${interpolation_host}
EOF

  printf '%s\n' "${interpolation_host}"
}

vc::refresh_tenant_overlays() {
  local shared_host="$1"
  [[ -d "${VC_TENANT_MANIFEST_ROOT}" ]] || return 0

  local overlay app_file tenant
  for overlay in "${VC_TENANT_MANIFEST_ROOT}"/*; do
    [[ -d "${overlay}" ]] || continue
    tenant="$(basename "${overlay}")"
    app_file="${overlay}/app.env"
    [[ -f "${app_file}" ]] || continue
    if grep -q '^INTERPOLATION_BASE_URL=' "${app_file}"; then
      sed -i "s#^INTERPOLATION_BASE_URL=.*#INTERPOLATION_BASE_URL=http://${shared_host}#g" "${app_file}"
    else
      printf 'INTERPOLATION_BASE_URL=http://%s\n' "${shared_host}" >>"${app_file}"
    fi
    save_state_var "$(vc::state_key "${tenant}" "INTERPOLATION_HOST")" "${shared_host}"
    vc::debug "Atualizado overlay ${tenant} para usar interpolação ${shared_host}"
  done
}

vc::apply_private_network_policies() {
  local namespace="$1"
  vc::debug "PLATFORM_MODE=oke: políticas de host Cilium removidas para ${namespace}; isolamento mantido por NetworkPolicy nos manifests das aplicações."
}

vc::apply_shared_network_policies() {
  local namespace="$1"
  vc::debug "PLATFORM_MODE=oke: políticas de host Cilium removidas para ${namespace}; compartilhamento controlado por Service interno + NetworkPolicy das aplicações."
}

vc::apply_network_policies() {
  local namespace="$1"
  local profile="$2"
  if (( ${VC_DISABLE_NETWORK_POLICIES:-0} )); then
    vc::debug "VC_DISABLE_NETWORK_POLICIES=1 – pulando políticas de host em ${namespace}"
    return 0
  fi
  if [[ "${profile}" == "private" ]]; then
    vc::apply_private_network_policies "${namespace}"
    vc::debug "Política private aplicada em ${namespace}"
  else
    vc::apply_shared_network_policies "${namespace}"
    vc::debug "Política shared aplicada em ${namespace}"
  fi
}

vc::publish_monitoring_secret() {
  local cluster_name="$1"
  local tenant="$2"
  local role="$3"
  local kubeconfig_path="$4"
  (( VC_MONITORING_READY )) || return 0
  vc::debug "Publicando kubeconfig ${kubeconfig_path} no monitoring para ${cluster_name} (tenant=${tenant}, role=${role})"

  kubectl -n monitoring create secret generic "vcluster-${cluster_name}-kubeconfig" \
    --from-file=kubeconfig="${kubeconfig_path}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n monitoring label secret "vcluster-${cluster_name}-kubeconfig" \
    "adb.tenancy/tenant=${tenant}" \
    "adb.tenancy/role=${role}" \
    --overwrite >/dev/null

  vc::debug "Publicado com sucesso"
}

vc::cleanup_monitoring_secret() {
  local cluster_name="$1"
  (( VC_MONITORING_READY )) || return 0
  if kubectl -n monitoring get secret "vcluster-${cluster_name}-kubeconfig" >/dev/null 2>&1; then
    vc::debug "Removendo secret vcluster-${cluster_name}-kubeconfig do monitoring"
    kubectl -n monitoring delete secret "vcluster-${cluster_name}-kubeconfig" >/dev/null
  else
    vc::debug "Nenhum secret de monitoring encontrado para ${cluster_name}"
  fi
}
