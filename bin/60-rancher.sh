#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="rancher"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create ns cattle-system || true

TLS_KEY=$(mktemp)
TLS_CRT=$(mktemp)
if ! kubectl -n cattle-system get secret rancher-tls >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
    -subj "/CN=${RANCHER_HOST}" \
    -addext "subjectAltName=DNS:${RANCHER_HOST},IP:${INGRESS_VIP}"
  kubectl -n cattle-system create secret tls rancher-tls \
    --key "${TLS_KEY}" --cert "${TLS_CRT}"
fi

helm upgrade -i rancher rancher-latest/rancher -n cattle-system \
  --set hostname="${RANCHER_HOST}" \
  --set ingress.tls.source=secret \
  --set privateCA=true

kubectl -n cattle-system patch ingress rancher -p '{"spec":{"tls":[{"hosts":["'"${RANCHER_HOST}"'"],"secretName":"rancher-tls"}]}}'

ok "${STEP}"
