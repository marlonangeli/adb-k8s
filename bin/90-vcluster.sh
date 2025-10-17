#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="vcluster"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst
ensure_vcluster_cli

IFS=' ' read -r -a TENANT_IDS <<<"${TENANTS:-tenant-a}"

SHARED_VCLUSTER_NAME="${SHARED_VCLUSTER_NAME:-shared}"
SHARED_VCLUSTER_NAMESPACE="${SHARED_VCLUSTER_NAMESPACE:-vcluster-shared}"
ENABLE_SHARED_VCLUSTER="${ENABLE_SHARED_VCLUSTER:-1}"

INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido; execute o passo do ingress primeiro."; exit 1; }

monitoring_namespace_available=1
if ! kubectl get ns monitoring >/dev/null 2>&1; then
  monitoring_namespace_available=0
  log "namespace monitoring não encontrado; kubeconfigs dos vclusters não serão publicados para observabilidade."
fi

# Limites e solicitações padrão para o plano de controle virtual dedicado de cada função
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

state_key() {
  local cluster="$1"
  local key="VCLUSTER_${cluster^^}_KUBECONFIG"
  key="${key//-/_}"
  echo "${key}"
}

ensure_namespace() {
  local namespace="$1"
  local tenant="$2"
  local role="$3"
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl create namespace "${namespace}"
  fi
  kubectl label namespace "${namespace}" \
    "adb.tenancy/tenant=${tenant}" \
    "adb.tenancy/role=${role}" \
    --overwrite
}

build_values_file() {
  local cluster_name="$1"
  local namespace="$2"
  local profile="$3"
  local tmp
  tmp=$(mktemp)
  register_tmp "${tmp}"

  local api_request_cpu api_request_memory api_limit_cpu api_limit_memory
  local controller_request_cpu controller_request_memory controller_limit_cpu controller_limit_memory
  local scheduler_request_cpu scheduler_request_memory scheduler_limit_cpu scheduler_limit_memory
  local syncer_request_cpu syncer_request_memory syncer_limit_cpu syncer_limit_memory

  if [[ "${profile}" == "private" ]]; then
    api_request_cpu="${PRIVATE_API_REQUEST_CPU}"
    api_request_memory="${PRIVATE_API_REQUEST_MEMORY}"
    api_limit_cpu="${PRIVATE_API_LIMIT_CPU}"
    api_limit_memory="${PRIVATE_API_LIMIT_MEMORY}"
    controller_request_cpu="${PRIVATE_CONTROLLER_MANAGER_REQUEST_CPU}"
    controller_request_memory="${PRIVATE_CONTROLLER_MANAGER_REQUEST_MEMORY}"
    controller_limit_cpu="${PRIVATE_CONTROLLER_MANAGER_LIMIT_CPU}"
    controller_limit_memory="${PRIVATE_CONTROLLER_MANAGER_LIMIT_MEMORY}"
    scheduler_request_cpu="${PRIVATE_SCHEDULER_REQUEST_CPU}"
    scheduler_request_memory="${PRIVATE_SCHEDULER_REQUEST_MEMORY}"
    scheduler_limit_cpu="${PRIVATE_SCHEDULER_LIMIT_CPU}"
    scheduler_limit_memory="${PRIVATE_SCHEDULER_LIMIT_MEMORY}"
    syncer_request_cpu="${PRIVATE_SYNCER_REQUEST_CPU}"
    syncer_request_memory="${PRIVATE_SYNCER_REQUEST_MEMORY}"
    syncer_limit_cpu="${PRIVATE_SYNCER_LIMIT_CPU}"
    syncer_limit_memory="${PRIVATE_SYNCER_LIMIT_MEMORY}"
  else
    api_request_cpu="${SHARED_API_REQUEST_CPU}"
    api_request_memory="${SHARED_API_REQUEST_MEMORY}"
    api_limit_cpu="${SHARED_API_LIMIT_CPU}"
    api_limit_memory="${SHARED_API_LIMIT_MEMORY}"
    controller_request_cpu="${SHARED_CONTROLLER_MANAGER_REQUEST_CPU}"
    controller_request_memory="${SHARED_CONTROLLER_MANAGER_REQUEST_MEMORY}"
    controller_limit_cpu="${SHARED_CONTROLLER_MANAGER_LIMIT_CPU}"
    controller_limit_memory="${SHARED_CONTROLLER_MANAGER_LIMIT_MEMORY}"
    scheduler_request_cpu="${SHARED_SCHEDULER_REQUEST_CPU}"
    scheduler_request_memory="${SHARED_SCHEDULER_REQUEST_MEMORY}"
    scheduler_limit_cpu="${SHARED_SCHEDULER_LIMIT_CPU}"
    scheduler_limit_memory="${SHARED_SCHEDULER_LIMIT_MEMORY}"
    syncer_request_cpu="${SHARED_SYNCER_REQUEST_CPU}"
    syncer_request_memory="${SHARED_SYNCER_REQUEST_MEMORY}"
    syncer_limit_cpu="${SHARED_SYNCER_LIMIT_CPU}"
    syncer_limit_memory="${SHARED_SYNCER_LIMIT_MEMORY}"
  fi

  cat >"${tmp}" <<EOF
controlPlane:
  distro: k8s
syncer:
  targetNamespace: ${namespace}
  extraArgs:
    - --enable-host-dns
  resources:
    requests:
      cpu: ${syncer_request_cpu}
      memory: ${syncer_request_memory}
    limits:
      cpu: ${syncer_limit_cpu}
      memory: ${syncer_limit_memory}
api:
  resources:
    requests:
      cpu: ${api_request_cpu}
      memory: ${api_request_memory}
    limits:
      cpu: ${api_limit_cpu}
      memory: ${api_limit_memory}
controllerManager:
  resources:
    requests:
      cpu: ${controller_request_cpu}
      memory: ${controller_request_memory}
    limits:
      cpu: ${controller_limit_cpu}
      memory: ${controller_limit_memory}
scheduler:
  resources:
    requests:
      cpu: ${scheduler_request_cpu}
      memory: ${scheduler_request_memory}
    limits:
      cpu: ${scheduler_limit_cpu}
      memory: ${scheduler_limit_memory}
EOF
  echo "${tmp}"
}

ensure_monitoring_secret() {
  local cluster_name="$1"
  local tenant="$2"
  local role="$3"
  local kubeconfig_path="$4"
  (( monitoring_namespace_available )) || return 0

  kubectl -n monitoring create secret generic "vcluster-${cluster_name}-kubeconfig" \
    --from-file=kubeconfig="${kubeconfig_path}" \
    --dry-run=client -o yaml | kubectl apply -f -

  if ! kubectl -n monitoring label secret "vcluster-${cluster_name}-kubeconfig" \
    "adb.tenancy/tenant=${tenant}" \
    "adb.tenancy/role=${role}" \
    --overwrite >/dev/null 2>&1; then
    log "falha ao rotular secret vcluster-${cluster_name}-kubeconfig para monitoramento"
  fi
}

apply_private_network_policies() {
  local namespace="$1"
  kubectl apply -n "${namespace}" -f - <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-private-egress
spec:
  endpointSelector: {}
  egressDeny:
  - toEntities:
    - all
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-private-essential-egress
spec:
  endpointSelector: {}
  egress:
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "${namespace}"
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "kube-system"
        "k8s:k8s-app": "kube-dns"
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"
  - toCIDRSet:
    - cidr: "${INGRESS_IP}/32"
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      - port: "443"
        protocol: TCP
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "${SHARED_VCLUSTER_NAMESPACE}"
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-private-ingress
spec:
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "${namespace}"
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "ingress-nginx"
EOF
}

apply_shared_network_policies() {
  local namespace="$1"
  kubectl apply -n "${namespace}" -f - <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-shared
spec:
  endpointSelector: {}
  ingressDeny:
  - fromEntities:
    - all
  egressDeny:
  - toEntities:
    - all
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: allow-shared-traffic
spec:
  endpointSelector: {}
  ingress:
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "${namespace}"
  - fromEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "ingress-nginx"
  egress:
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "${namespace}"
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "ingress-nginx"
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "kube-system"
        "k8s:k8s-app": "kube-dns"
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"
EOF
}

apply_network_policies() {
  local namespace="$1"
  local profile="$2"
  if [[ "${profile}" == "private" ]]; then
    apply_private_network_policies "${namespace}"
  else
    apply_shared_network_policies "${namespace}"
  fi
}

provision_vcluster() {
  local tenant="$1"
  local cluster_name="$2"
  local namespace="$3"
  local profile="$4"

  ensure_namespace "${namespace}" "${tenant}" "${profile}"
  local values_file
  values_file=$(build_values_file "${cluster_name}" "${namespace}" "${profile}")

  local existed=0
  local kubeconfig_tmp
  kubeconfig_tmp=$(mktemp)
  register_tmp "${kubeconfig_tmp}"
  if vcluster connect "${cluster_name}" -n "${namespace}" --update-current=false --print >"${kubeconfig_tmp}" 2>/dev/null; then
    existed=1
    log "vcluster ${cluster_name} (${namespace}) já existe; reutilizando configuração atual."
  else
    rm -f "${kubeconfig_tmp}"
    kubeconfig_tmp=""
    log "criando vcluster ${cluster_name} (${namespace})"
    vcluster create "${cluster_name}" -n "${namespace}" --connect=false --expose -f "${values_file}"
    kubeconfig_tmp=$(mktemp)
    register_tmp "${kubeconfig_tmp}"
    vcluster connect "${cluster_name}" -n "${namespace}" --update-current=false --print >"${kubeconfig_tmp}"
  fi

  [[ -f "${kubeconfig_tmp}" ]] || { log "não foi possível obter o kubeconfig do vcluster ${cluster_name}"; exit 1; }

  local kubeconfig_path="${STATE_DIR}/kubeconfig-${cluster_name}.yaml"
  mkdir -p "$(dirname "${kubeconfig_path}")"
  mv "${kubeconfig_tmp}" "${kubeconfig_path}"
  chmod 0600 "${kubeconfig_path}"

  save_state_var "$(state_key "${cluster_name}")" "${kubeconfig_path}"
  ensure_monitoring_secret "${cluster_name}" "${tenant}" "${profile}" "${kubeconfig_path}"
  apply_network_policies "${namespace}" "${profile}"

  log "vcluster ${cluster_name} (${profile}) pronto; kubeconfig salvo em ${kubeconfig_path}"
}

for tenant in "${TENANT_IDS[@]}"; do
  [[ -n "${tenant}" ]] || continue
  provision_vcluster "${tenant}" "${tenant}" "vcluster-${tenant}" "private"
done

if [[ "${ENABLE_SHARED_VCLUSTER}" == "1" ]]; then
  provision_vcluster "shared" "${SHARED_VCLUSTER_NAME}" "${SHARED_VCLUSTER_NAMESPACE}" "shared"
fi

if ((${#TENANT_IDS[@]})); then
  save_state_var "VCLUSTER_TENANTS" "${TENANT_IDS[*]}"
fi
if [[ "${ENABLE_SHARED_VCLUSTER}" == "1" ]]; then
  save_state_var "VCLUSTER_SHARED_NAME" "${SHARED_VCLUSTER_NAME}"
  save_state_var "VCLUSTER_SHARED_NAMESPACE" "${SHARED_VCLUSTER_NAMESPACE}"
fi

HUBBLE_HOSTNAME=$(resolve_hostname "${HUBBLE_HOST_OVERRIDE:-}" "hubble")
HUBBLE_LOCAL_HOSTNAME=$(local_sslip_host "hubble")
save_state_var "HUBBLE_HOSTNAME" "${HUBBLE_HOSTNAME}"
save_state_var "HUBBLE_LOCAL_HOSTNAME" "${HUBBLE_LOCAL_HOSTNAME}"

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

ok "${STEP}"
