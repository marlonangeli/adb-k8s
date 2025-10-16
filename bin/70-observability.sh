#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="observability"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_helm
: "${GRAFANA_ADMIN_USER:?defina GRAFANA_ADMIN_USER em secrets.env}"
: "${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD em secrets.env}"

GRAFANA_HOSTNAME=$(resolve_hostname "${GRAFANA_HOST_OVERRIDE:-}" "grafana")

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create ns monitoring || true

helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
  --set grafana.adminUser="${GRAFANA_ADMIN_USER}" \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=nginx \
  --set grafana.ingress.hosts="[\"${GRAFANA_HOSTNAME}\"]"

save_state_var "GRAFANA_HOSTNAME" "${GRAFANA_HOSTNAME}"
log "Grafana disponível em http://${GRAFANA_HOSTNAME}"

ok "${STEP}"
