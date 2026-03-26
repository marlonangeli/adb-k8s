#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

if [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
  log "PLATFORM_MODE=oke: etapa bare-metal desabilitada (20-kubeadm-init)."
  ok "kubeadm-init"
  exit 0
fi

need_root

STEP="kubeadm-init"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

kubeadm config images pull
kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --skip-phases=addon/kube-proxy

mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"

kubeadm token create --print-join-command | tee ~/join-worker.sh
chmod +x ~/join-worker.sh

log "execute ~/join-worker.sh nos workers: ${WORKERS[*]}"
ok "${STEP}"
