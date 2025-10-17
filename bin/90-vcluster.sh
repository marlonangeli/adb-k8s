#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="vcluster"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl sed envsubst
ensure_vcluster_cli

for NS in vcluster-tenant-a vcluster-shared; do
  kubectl create ns "${NS}" || true
done

values_template=$(mktemp)
register_tmp "${values_template}"
cat >"${values_template}" <<'EOF'
controlPlane: { distro: k8s }
syncer:
  targetNamespace: REPLACE_NS
api: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
controllerManager: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
scheduler: { resources: { requests: { cpu: 50m,  memory: 64Mi } } }
EOF

tenant_a_values=$(mktemp)
register_tmp "${tenant_a_values}"
sed "s/REPLACE_NS/vcluster-tenant-a/" "${values_template}" >"${tenant_a_values}"
vcluster create tenant-a -n vcluster-tenant-a --connect=false --expose -f "${tenant_a_values}"
vcluster connect tenant-a -n vcluster-tenant-a --update-current=false --print > /root/kubeconfig-tenant-a.yaml

shared_values=$(mktemp)
register_tmp "${shared_values}"
sed "s/REPLACE_NS/vcluster-shared/" "${values_template}" >"${shared_values}"
vcluster create shared -n vcluster-shared --connect=false --expose -f "${shared_values}"

INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido; execute o passo do ingress primeiro."; exit 1; }

kubectl apply -n vcluster-tenant-a -f - <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata: { name: egress-deny-all }
spec:
  endpointSelector: {}
  egressDeny:
  - toEntities: [ "all" ]
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata: { name: egress-allow-dns-and-ingress }
spec:
  endpointSelector: {}
  egress:
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "kube-system"
        "k8s:k8s-app": "kube-dns"
    toPorts:
    - ports: [{ port: "53", protocol: ANY }]
      rules: { dns: [ { matchPattern: "*" } ] }
  - toCIDRSet: [ { cidr: "${INGRESS_IP}/32" } ]
    toPorts:
    - ports: [ { port: "80", protocol: TCP }, { port: "443", protocol: TCP } ]
EOF

HUBBLE_HOSTNAME=$(resolve_hostname "${HUBBLE_HOST_OVERRIDE:-}" "hubble")
HUBBLE_LOCAL_HOSTNAME=$(local_sslip_host "hubble")
save_state_var "HUBBLE_HOSTNAME" "${HUBBLE_HOSTNAME}"
save_state_var "HUBBLE_LOCAL_HOSTNAME" "${HUBBLE_LOCAL_HOSTNAME}"

hubble_host_was_set=0
if [[ ${HUBBLE_HOST+x} ]]; then
  hubble_host_was_set=1
  prev_hubble_host="${HUBBLE_HOST}"
fi
apply_certificate "kube-system" "hubble-tls" "hubble-tls" "${INGRESS_IP}" \
  "${HUBBLE_HOSTNAME}" "${HUBBLE_LOCAL_HOSTNAME}"

hubble_local_host_was_set=0
if [[ ${HUBBLE_LOCAL_HOST+x} ]]; then
  hubble_local_host_was_set=1
  prev_hubble_local_host="${HUBBLE_LOCAL_HOST}"
fi
export HUBBLE_HOST="${HUBBLE_HOSTNAME}"
export HUBBLE_LOCAL_HOST="${HUBBLE_LOCAL_HOSTNAME}"
hubble_ingress=$(render_template "${ROOT_DIR}/manifests/hubble.ingress.yaml")
if (( hubble_host_was_set )); then
  export HUBBLE_HOST="${prev_hubble_host}"
else
  unset HUBBLE_HOST
fi
if (( hubble_local_host_was_set )); then
  export HUBBLE_LOCAL_HOST="${prev_hubble_local_host}"
else
  unset HUBBLE_LOCAL_HOST
fi
kubectl apply -f "${hubble_ingress}"
log "Hubble UI disponível em https://${HUBBLE_HOSTNAME} e https://${HUBBLE_LOCAL_HOSTNAME}"

ok "${STEP}"
