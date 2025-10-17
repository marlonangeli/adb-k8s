#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="longhorn"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst
ensure_helm
helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create ns longhorn-system || true

helm upgrade -i longhorn longhorn/longhorn -n longhorn-system \
  --set defaultSettings.defaultReplicaCount=2

LONGHORN_HOSTNAME=$(resolve_hostname "${LONGHORN_HOST_OVERRIDE:-}" "longhorn")
LONGHORN_LOCAL_HOSTNAME=$(local_sslip_host "longhorn")
save_state_var "LONGHORN_HOSTNAME" "${LONGHORN_HOSTNAME}"
save_state_var "LONGHORN_LOCAL_HOSTNAME" "${LONGHORN_LOCAL_HOSTNAME}"

INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }
apply_certificate "longhorn-system" "longhorn-tls" "longhorn-tls" "${INGRESS_IP}" \
  "${LONGHORN_HOSTNAME}" "${LONGHORN_LOCAL_HOSTNAME}"

longhorn_host_was_set=0
if [[ ${LONGHORN_HOST+x} ]]; then
  longhorn_host_was_set=1
  prev_longhorn_host="${LONGHORN_HOST}"
fi
longhorn_local_host_was_set=0
if [[ ${LONGHORN_LOCAL_HOST+x} ]]; then
  longhorn_local_host_was_set=1
  prev_longhorn_local_host="${LONGHORN_LOCAL_HOST}"
fi
export LONGHORN_HOST="${LONGHORN_HOSTNAME}"
export LONGHORN_LOCAL_HOST="${LONGHORN_LOCAL_HOSTNAME}"
ingress_file=$(render_template "${ROOT_DIR}/manifests/longhorn.ingress.yaml")
if (( longhorn_host_was_set )); then
  export LONGHORN_HOST="${prev_longhorn_host}"
else
  unset LONGHORN_HOST
fi
if (( longhorn_local_host_was_set )); then
  export LONGHORN_LOCAL_HOST="${prev_longhorn_local_host}"
else
  unset LONGHORN_LOCAL_HOST
fi
kubectl apply -f "${ingress_file}"
log "Longhorn UI disponível em https://${LONGHORN_HOSTNAME} e https://${LONGHORN_LOCAL_HOSTNAME}"

ok "${STEP}"
