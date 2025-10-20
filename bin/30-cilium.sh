#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="cilium"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_cilium_cli

CILIUM_VERSION="v1.18.2"
log "Aplicando Cilium (${CILIUM_VERSION})"
cilium_flags=(
  --version "${CILIUM_VERSION}"
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${CP_IP}"
  --set k8sServicePort=6443
  --set ipam.mode=cluster-pool
  --set cluster.name=lab-cluster
  --set cluster.id=1
  --set l7Proxy=true
  --set bpf.masquerade=true
  --set prometheus.enabled=true
  --set operator.prometheus.enabled=true
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.relay.tolerations[0].key=node-role.kubernetes.io/control-plane
  --set hubble.relay.tolerations[0].operator=Exists
  --set hubble.relay.resources.requests.cpu=50m
  --set hubble.relay.resources.requests.memory=96Mi
  --set hubble.relay.resources.limits.cpu=200m
  --set hubble.relay.resources.limits.memory=192Mi
  --set hubble.ui.enabled=true
  --set hubble.ui.tolerations[0].key=node-role.kubernetes.io/control-plane
  --set hubble.ui.tolerations[0].operator=Exists
  --set hubble.ui.backend.resources.requests.cpu=50m
  --set hubble.ui.backend.resources.requests.memory=96Mi
  --set hubble.ui.backend.resources.limits.cpu=200m
  --set hubble.ui.backend.resources.limits.memory=192Mi
  --set hubble.ui.frontend.resources.requests.cpu=25m
  --set hubble.ui.frontend.resources.requests.memory=80Mi
  --set hubble.ui.frontend.resources.limits.cpu=150m
  --set hubble.ui.frontend.resources.limits.memory=160Mi
  --set hubble.metrics.enabled="{dns;drop;tcp;flow;port-distribution;icmp;http}"
)

cilium_service_monitor_pending=0
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  cilium_flags+=(--set prometheus.serviceMonitor.enabled=true)
  log "ServiceMonitor CRD presente; habilitando integração de monitoramento do Cilium."
else
  cilium_flags+=(--set prometheus.serviceMonitor.enabled=false)
  cilium_service_monitor_pending=1
  log "ServiceMonitor CRD não encontrado; instalando Cilium sem ServiceMonitor e reagendando habilitação após observability."
fi

cilium_cmd=(cilium install)
if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  log "Cilium já instalado; aplicando upgrade com novos parâmetros."
  cilium_cmd=(cilium upgrade)
fi

"${cilium_cmd[@]}" "${cilium_flags[@]}"

cilium status --wait
if (( cilium_service_monitor_pending )); then
  save_state_var "CILIUM_SERVICE_MONITOR_PENDING" "1"
else
  save_state_var "CILIUM_SERVICE_MONITOR_PENDING" "0"
fi
ok "${STEP}"
