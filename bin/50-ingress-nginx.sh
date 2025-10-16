#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="ingress-nginx"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst
ensure_helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl create ns ingress-nginx || true

values_file=$(render_template "${ROOT_DIR}/manifests/ingress-nginx.values.yaml")
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  -f "${values_file}"
wait_rollout ingress-nginx deploy ingress-nginx-controller

if ip=$(wait_for_lb_ip ingress-nginx ingress-nginx-controller 300); then
  save_state_var "ASSIGNED_INGRESS_IP" "${ip}"
  log "Ingress LoadBalancer IP: ${ip}"
else
  log "não foi possível obter o IP do LoadBalancer do ingress dentro do tempo esperado"
  exit 1
fi

ok "${STEP}"
