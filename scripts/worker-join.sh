#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[worker-join] precisa ser root" >&2
  exit 1
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "[worker-join] kubelet.conf encontrado; assumindo nó já associado ao cluster. Pulando."
  exit 0
fi

if systemctl is-active --quiet kubelet; then
  echo "[worker-join] kubelet ativo; assumindo nó já associado ao cluster. Pulando."
  exit 0
fi

if [[ $# -eq 0 ]]; then
  echo "[worker-join] comando de join não informado" >&2
  exit 1
fi

echo "[worker-join] executando kubeadm join"
kubeadm join "$@"
