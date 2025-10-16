#!/bin/bash
# shellcheck disable=SC2034

# Inventário de nós
export CP_IP="192.168.30.52"
export WORKERS=("192.168.30.53" "192.168.30.54")
export REMOTE_SSH_USER="${REMOTE_SSH_USER:-utfpr}"
export REMOTE_SSH_OPTIONS="${REMOTE_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"
REMOTE_DEFAULT_BASE_DIR="/home/${REMOTE_SSH_USER}/adb-k8s"
export REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-${REMOTE_DEFAULT_BASE_DIR}}"

# Networking
export POD_CIDR="10.10.0.0/16"
export SVC_CIDR="10.96.0.0/12"

# MetalLB
export LB_POOL_START="192.168.30.100"
export LB_POOL_END="192.168.30.120"
# Deixe em branco para IP dinâmico; defina para fixar manualmente.
export INGRESS_VIP=""

# Hostnames (opcionais) - sobrescrevem a geração automática baseada no IP do ingress
export RANCHER_HOST_OVERRIDE=""
export GRAFANA_HOST_OVERRIDE=""
export LONGHORN_HOST_OVERRIDE=""
export HUBBLE_HOST_OVERRIDE=""
export INGRESS_HOST_TEMPLATE="%s.%s.sslip.io"

# Estado / logs
export STATE_DIR="/var/opt/cluster-state"
export LOG_FILE="/var/log/cluster-install.log"
