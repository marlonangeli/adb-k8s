#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="rancher"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl openssl
ensure_helm
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create ns cattle-system || true

RANCHER_HOSTNAME=$(resolve_hostname "${RANCHER_HOST_OVERRIDE:-}" "rancher")
INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }

TLS_KEY=$(mktemp)
TLS_CRT=$(mktemp)
register_tmp "${TLS_KEY}"
register_tmp "${TLS_CRT}"
if ! kubectl -n cattle-system get secret rancher-tls >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
    -subj "/CN=${RANCHER_HOSTNAME}" \
    -addext "subjectAltName=DNS:${RANCHER_HOSTNAME},IP:${INGRESS_IP}"
  kubectl -n cattle-system create secret tls rancher-tls \
    --key "${TLS_KEY}" --cert "${TLS_CRT}"
fi

helm upgrade -i rancher rancher-latest/rancher -n cattle-system \
  --set hostname="${RANCHER_HOSTNAME}" \
  --set ingress.tls.source=secret \
  --set privateCA=true

kubectl -n cattle-system patch ingress rancher -p '{"spec":{"tls":[{"hosts":["'"${RANCHER_HOSTNAME}"'"],"secretName":"rancher-tls"}]}}'

save_state_var "RANCHER_HOSTNAME" "${RANCHER_HOSTNAME}"
log "Rancher disponível em https://${RANCHER_HOSTNAME}"

ok "${STEP}"
