#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="longhorn"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst
ensure_helm
: "${LONGHORN_DEFAULT_REPLICA_COUNT:=2}"
: "${LONGHORN_STORAGECLASS_NAME:=longhorn-2}"

if [[ "${PLATFORM_MODE:-baremetal}" != "oke" ]]; then
  if ! donep "ingress-nginx"; then
    log "ingress-nginx ainda não foi provisionado; execute bin/50-ingress-nginx.sh antes deste passo."
    exit 1
  fi

  if ! ING_IP_TMP=$(current_ingress_ip 2>/dev/null); then
    log "Ingress IP não conhecido. Execute bin/50-ingress-nginx.sh e aguarde a atribuição do IP antes de instalar o Longhorn."
    exit 1
  fi
  INGRESS_IP="${ING_IP_TMP}"
fi

helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create ns longhorn-system || true

helm upgrade -i longhorn longhorn/longhorn -n longhorn-system \
  --set-string defaultSettings.defaultReplicaCount="${LONGHORN_DEFAULT_REPLICA_COUNT}" \
  --set longhornManager.resources.requests.cpu=120m \
  --set longhornManager.resources.requests.memory=160Mi \
  --set longhornManager.resources.limits.cpu=350m \
  --set longhornManager.resources.limits.memory=320Mi \
  --set longhornUI.resources.requests.cpu=40m \
  --set longhornUI.resources.requests.memory=96Mi \
  --set longhornUI.resources.limits.cpu=150m \
  --set longhornUI.resources.limits.memory=192Mi \
  --set csi.attacher.resources.requests.cpu=40m \
  --set csi.attacher.resources.requests.memory=64Mi \
  --set csi.attacher.resources.limits.cpu=120m \
  --set csi.attacher.resources.limits.memory=128Mi \
  --set csi.provisioner.resources.requests.cpu=40m \
  --set csi.provisioner.resources.requests.memory=64Mi \
  --set csi.provisioner.resources.limits.cpu=150m \
  --set csi.provisioner.resources.limits.memory=160Mi \
  --set csi.resizer.resources.requests.cpu=30m \
  --set csi.resizer.resources.requests.memory=48Mi \
  --set csi.resizer.resources.limits.cpu=100m \
  --set csi.resizer.resources.limits.memory=96Mi \
  --set csi.snapshotter.resources.requests.cpu=30m \
  --set csi.snapshotter.resources.requests.memory=48Mi \
  --set csi.snapshotter.resources.limits.cpu=100m \
  --set csi.snapshotter.resources.limits.memory=96Mi

kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${LONGHORN_STORAGECLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "${LONGHORN_DEFAULT_REPLICA_COUNT}"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: ext4
  dataLocality: disabled
  unmapMarkSnapChainRemoved: ignored
  disableRevisionCounter: "true"
  dataEngine: v1
  backupTargetName: default
EOF

kubectl annotate storageclass longhorn storageclass.kubernetes.io/is-default-class="false" --overwrite >/dev/null 2>&1 || true
kubectl annotate storageclass "${LONGHORN_STORAGECLASS_NAME}" storageclass.kubernetes.io/is-default-class="true" --overwrite >/dev/null

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

if [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
  longhorn_exposure_label="publico"
  if [[ "${LONGHORN_LB_INTERNAL}" == "true" ]]; then
    longhorn_exposure_label="interno"
  fi
  longhorn_patch_payload=$(cat <<EOF
{
  "spec": {
    "type": "LoadBalancer"
  },
  "metadata": {
    "annotations": {
      "oci.oraclecloud.com/load-balancer-type": "${LONGHORN_LB_TYPE}",
      "oci-network-load-balancer.oraclecloud.com/internal": "${LONGHORN_LB_INTERNAL}",
      "oci.oraclecloud.com/security-rule-management-mode": "${LONGHORN_LB_SECURITY_RULE_MODE}"
    }
  }
}
EOF
)
  kubectl -n longhorn-system patch svc longhorn-frontend --type merge -p "${longhorn_patch_payload}"
  longhorn_endpoint="$(wait_for_lb_ip longhorn-system longhorn-frontend 300 || true)"
  if [[ -n "${longhorn_endpoint}" ]]; then
    save_state_var "LONGHORN_HOSTNAME" "${longhorn_endpoint}"
    log "Longhorn UI disponível em http://${longhorn_endpoint} (LoadBalancer ${longhorn_exposure_label} OKE)."
  else
    log "Longhorn instalado; endpoint LoadBalancer OKE não disponível no tempo esperado."
  fi
  ok "${STEP}"
  exit 0
fi

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
