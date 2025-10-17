#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="cilium"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_cilium_cli

CILIUM_VERSION="v1.18.2"
log "Aplicando Cilium (${CILIUM_VERSION})"
cilium install \
  --version ${CILIUM_VERSION} \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost="${CP_IP}" --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set cluster.name=lab-cluster \
  --set cluster.id=1 \
  --set l7Proxy=true \
  --set bpf.masquerade=true \
  --set tunnel=vxlan \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns;drop;tcp;flow;port-distribution;icmp;http}"

cilium status --wait
ok "${STEP}"
