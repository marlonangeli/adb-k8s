#!/bin/bash
# shellcheck disable=SC2034

# Cluster IP plan
export CP_IP="192.168.30.52"
export WORKERS=("192.168.30.53" "192.168.30.54")

# Networking
export POD_CIDR="10.10.0.0/16"
export SVC_CIDR="10.96.0.0/12"

# MetalLB
export LB_POOL_START="192.168.30.100"
export LB_POOL_END="192.168.30.120"
export INGRESS_VIP="192.168.30.101"

# Hostnames úteis (sem domínio)
export RANCHER_HOST="rancher.${INGRESS_VIP}.sslip.io"
export GRAFANA_HOST="grafana.${INGRESS_VIP}.sslip.io"
export LONGHORN_HOST="longhorn.${INGRESS_VIP}.sslip.io"
export HUBBLE_HOST="hubble.${INGRESS_VIP}.sslip.io"

# Estado / logs
export STATE_DIR="/var/opt/cluster-state"
export LOG_FILE="/var/log/cluster-install.log"
