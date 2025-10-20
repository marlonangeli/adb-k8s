#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${ROOT_DIR}/scripts/vcluster/common.sh"

STEP="argocd"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl helm git sed
ensure_helm

vc::load_defaults

ARGOCD_NAMESPACE="argocd"
ARGOCD_HOSTNAME=$(resolve_hostname "${ARGOCD_HOST_OVERRIDE:-}" "argocd")
save_state_var "ARGOCD_HOSTNAME" "${ARGOCD_HOSTNAME}"

values_file=$(mktemp)
register_tmp "${values_file}"
cat >"${values_file}" <<EOF
global:
  image:
    repository: quay.io/argoproj/argocd
server:
  extraArgs:
    - --insecure
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - ${ARGOCD_HOSTNAME}
    tls: []
  service:
    type: ClusterIP
configs:
  cm:
    timeout.reconciliation: 30s
  params:
    server.insecure: "true"
EOF

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  -f "${values_file}"

wait_rollout "${ARGOCD_NAMESPACE}" deployment argocd-server
wait_rollout "${ARGOCD_NAMESPACE}" deployment argocd-repo-server
wait_rollout "${ARGOCD_NAMESPACE}" deployment argocd-application-controller

log "Argo CD disponível via http://${ARGOCD_HOSTNAME} (TLS desabilitado por padrão)."

kubectl apply -f "${ROOT_DIR}/manifests/argocd/project-tenants.yaml"

register_cluster_secret() {
  local cluster="$1"
  local kubeconfig_path="$2"

  [[ -f "${kubeconfig_path}" ]] || {
    log "kubeconfig não encontrado para ${cluster} (${kubeconfig_path}); ignorando."
    return
  }

  if ! kubectl --kubeconfig "${kubeconfig_path}" get namespace default >/dev/null 2>&1; then
    log "não foi possível consultar o cluster ${cluster} com o kubeconfig ${kubeconfig_path}; verifique conectividade."
    return
  fi

  local server_url
  server_url=$(kubectl config view --kubeconfig "${kubeconfig_path}" -o jsonpath='{.clusters[0].cluster.server}')
  if [[ -z "${server_url}" ]]; then
    log "não foi possível extrair o endpoint kube-apiserver do kubeconfig ${kubeconfig_path}"
    return
  fi

  if kubectl -n "${ARGOCD_NAMESPACE}" get secret "cluster-${cluster}" >/dev/null 2>&1; then
    local existing_server
    existing_server=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret "cluster-${cluster}" -o jsonpath='{.data.server}' 2>/dev/null || true)
    if [[ -n "${existing_server}" ]]; then
      existing_server="$(echo "${existing_server}" | base64 -d 2>/dev/null || true)"
    fi
    if [[ "${existing_server}" == "${server_url}" ]]; then
      log "cluster ${cluster} já registrado no Argo CD (${server_url}); mantendo configuração atual."
      return
    fi
    log "cluster ${cluster} registrado anteriormente com endpoint ${existing_server:-desconhecido}; atualizando para ${server_url}."
  fi

  kubectl -n "${ARGOCD_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${cluster}
  labels:
    argocd.argoproj.io/secret-type: cluster
    adb.tenancy/cluster: ${cluster}
type: Opaque
stringData:
  name: ${cluster}
  server: ${server_url}
  config: |
    {}
  kubeconfig: |
$(sed 's/^/    /' "${kubeconfig_path}")
EOF
  log "cluster ${cluster} registrado no Argo CD."
}

# Determina lista de tenants privados
declare -a TENANT_IDS
if [[ -n "${VCLUSTER_TENANTS:-}" ]]; then
  IFS=' ' read -r -a TENANT_IDS <<<"${VCLUSTER_TENANTS}"
elif [[ -n "${TENANTS:-}" ]]; then
  IFS=' ' read -r -a TENANT_IDS <<<"${TENANTS}"
else
  mapfile -t TENANT_IDS < <(find "${STATE_DIR}" -maxdepth 1 -name 'kubeconfig-*' -printf '%f\n' 2>/dev/null | sed 's/^kubeconfig-//' | sed 's/\.yaml$//' | grep -v '^'"${SHARED_VCLUSTER_NAME}"'$' || true)
fi

SHARED_CLUSTER_NAME="${VCLUSTER_SHARED_NAME:-${SHARED_VCLUSTER_NAME:-shared}}"

# Registra todos os clusters conhecidos (tenants + shared)
declare -A CLUSTER_CONFIGS=()
for cluster in "${TENANT_IDS[@]}" "${SHARED_CLUSTER_NAME}"; do
  [[ -n "${cluster}" ]] || continue
  state_key="$(vc::state_key "${cluster}")"
  kubeconfig_path="${!state_key:-${STATE_DIR}/kubeconfig-${cluster}.yaml}"
  register_cluster_secret "${cluster}" "${kubeconfig_path}"
  CLUSTER_CONFIGS["${cluster}"]="${kubeconfig_path}"
done

# Obtém informações dos repositórios Git
ADB_API_REPO_URL="${ADB_API_REPO_URL:-$(git -C "${ROOT_DIR}/adb-api-3" remote get-url origin 2>/dev/null || true)}"
INTERPOLATION_REPO_URL="${INTERPOLATION_REPO_URL:-$(git -C "${ROOT_DIR}/adb-interpolation-api" remote get-url origin 2>/dev/null || true)}"

if [[ -z "${ADB_API_REPO_URL}" || -z "${INTERPOLATION_REPO_URL}" ]]; then
  log "não foi possível determinar as URLs remotas dos repositórios das aplicações. Configure ADB_API_REPO_URL e INTERPOLATION_REPO_URL em env/secrets."
  exit 1
fi

ADB_API_REVISION="${ADB_API_REVISION:-main}"
ADB_API_PATH_ROOT="${ADB_API_PATH_ROOT:-k8s/tenants}"
TENANT_APP_NAMESPACE="${TENANT_APP_NAMESPACE:-${TENANT_TARGET_NAMESPACE}}"

for tenant in "${TENANT_IDS[@]}"; do
  [[ -n "${tenant}" ]] || continue
  export ARGOCD_APP_NAME="tenant-${tenant}-adb-api"
  export TENANT_ID="${tenant}"
  export TENANT_CLUSTER_NAME="${tenant}"
  export TENANT_NAMESPACE="${TENANT_APP_NAMESPACE}"
  export ADB_API_REPO_URL
  export ADB_API_REVISION
  export ADB_API_PATH="${ADB_API_PATH_ROOT}/${tenant}"

  if [[ ! -d "${ROOT_DIR}/adb-api-3/${ADB_API_PATH}" ]]; then
    log "overlay ${ADB_API_PATH} não encontrado em adb-api-3; pulei a Application do tenant ${tenant}."
    continue
  fi

  manifest=$(render_template "${ROOT_DIR}/manifests/argocd/application-tenant.yaml")
  kubectl apply -f "${manifest}"
done

INTERPOLATION_REPO_REVISION="${INTERPOLATION_REPO_REVISION:-main}"
INTERPOLATION_PATH="${INTERPOLATION_PATH:-k8s/overlays/shared}"
INTERPOLATION_NAMESPACE="${INTERPOLATION_NAMESPACE:-processing}"
export INTERPOLATION_APP_NAME="shared-interpolation"
export INTERPOLATION_REPO_URL
export INTERPOLATION_REVISION="${INTERPOLATION_REPO_REVISION}"
export INTERPOLATION_PATH
export INTERPOLATION_CLUSTER_NAME="${SHARED_CLUSTER_NAME}"
export INTERPOLATION_NAMESPACE

manifest=$(render_template "${ROOT_DIR}/manifests/argocd/application-interpolation.yaml")
kubectl apply -f "${manifest}"

log "Aplicações GitOps cadastradas no Argo CD."

ok "${STEP}"
