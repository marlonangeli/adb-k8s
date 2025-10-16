#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="cilium"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
tar -C /usr/local/bin -xzvf cilium-linux-amd64.tar.gz
rm -f cilium-linux-amd64.tar.gz*

cilium install \
  --version v1.18.0 \
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
