#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="observability"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create ns monitoring || true

helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
  --set grafana.adminPassword='admin' \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=nginx \
  --set grafana.ingress.hosts="[\"${GRAFANA_HOST}\"]"

ok "${STEP}"
