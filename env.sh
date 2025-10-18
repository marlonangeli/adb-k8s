#!/bin/bash
# shellcheck disable=SC2034

# Inventário de nós
export CP_IP="192.168.30.52"
export WORKERS=("192.168.30.53" "192.168.30.54")
export REMOTE_SSH_USER="${REMOTE_SSH_USER:-utfpr}"
REMOTE_DEFAULT_BASE_DIR="/home/${REMOTE_SSH_USER}/adb-k8s"
export REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-${REMOTE_DEFAULT_BASE_DIR}}"
REMOTE_DEFAULT_CONTROL_PATH="${HOME}/.ssh/adb-%C"
export REMOTE_SSH_CONTROL_PATH="${REMOTE_SSH_CONTROL_PATH:-${REMOTE_DEFAULT_CONTROL_PATH}}"
REMOTE_DEFAULT_SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlMaster=auto -o ControlPersist=60 -o ControlPath=${REMOTE_SSH_CONTROL_PATH}"
export REMOTE_SSH_OPTIONS="${REMOTE_SSH_OPTIONS:-${REMOTE_DEFAULT_SSH_OPTIONS}}"

# Networking
export POD_CIDR="10.10.0.0/16"
export SVC_CIDR="10.96.0.0/12"

# MetalLB
export LB_POOL_START="192.168.30.100"
export LB_POOL_END="192.168.30.120"
# Deixe em branco para IP dinâmico; defina para fixar manualmente.
export INGRESS_VIP=""

# Hostnames (opcionais) - sobrescrevem a geração automática baseada no IP do ingress (formato slug: 192-168-30-100)
export RANCHER_HOST_OVERRIDE=""
export GRAFANA_HOST_OVERRIDE=""
export LONGHORN_HOST_OVERRIDE=""
export HUBBLE_HOST_OVERRIDE=""
export INGRESS_HOST_TEMPLATE="%s.%s.sslip.io"

# TLS
export TLS_ENABLED="${TLS_ENABLED:-0}"
export TLS_CLUSTER_ISSUER="${TLS_CLUSTER_ISSUER:-selfsigned-cluster-issuer}"

# Estado / logs
export STATE_DIR="/var/opt/cluster-state"
export LOG_FILE="/var/log/cluster-install.log"
