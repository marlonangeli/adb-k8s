#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="longhorn"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst
ensure_helm

if ! donep "ingress-nginx"; then
  log "ingress-nginx ainda não foi provisionado; execute bin/50-ingress-nginx.sh antes deste passo."
  exit 1
fi

if ! ING_IP_TMP=$(current_ingress_ip 2>/dev/null); then
  log "Ingress IP não conhecido. Execute bin/50-ingress-nginx.sh e aguarde a atribuição do IP antes de instalar o Longhorn."
  exit 1
fi
INGRESS_IP="${ING_IP_TMP}"

helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create ns longhorn-system || true

helm upgrade -i longhorn longhorn/longhorn -n longhorn-system \
  --set defaultSettings.defaultReplicaCount=2

log "validando rollout do Longhorn"
wait_rollout longhorn-system deployment longhorn-ui
if kubectl -n longhorn-system get deployment longhorn-driver-deployer >/dev/null 2>&1; then
  wait_rollout longhorn-system deployment longhorn-driver-deployer
fi
if kubectl -n longhorn-system get daemonset longhorn-csi-plugin >/dev/null 2>&1; then
  wait_rollout longhorn-system daemonset longhorn-csi-plugin
fi
if kubectl -n longhorn-system get daemonset longhorn-csi-plugin-provisioner >/dev/null 2>&1; then
  wait_rollout longhorn-system daemonset longhorn-csi-plugin-provisioner
fi

LONGHORN_HOSTNAME=$(resolve_hostname "${LONGHORN_HOST_OVERRIDE:-}" "longhorn")
LONGHORN_LOCAL_HOSTNAME=$(local_sslip_host "longhorn")
save_state_var "LONGHORN_HOSTNAME" "${LONGHORN_HOSTNAME}"
save_state_var "LONGHORN_LOCAL_HOSTNAME" "${LONGHORN_LOCAL_HOSTNAME}"

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
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
else
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  ingressClassName: nginx
  rules:
  - host: ${LONGHORN_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
  - host: ${LONGHORN_LOCAL_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
EOF
  log "Longhorn UI disponível em http://${LONGHORN_HOSTNAME} e http://${LONGHORN_LOCAL_HOSTNAME}"
fi

ok "${STEP}"
