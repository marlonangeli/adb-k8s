#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="vcluster"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

if ! command -v vcluster >/dev/null 2>&1; then
  curl -L -o /usr/local/bin/vcluster \
    "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
  chmod +x /usr/local/bin/vcluster
fi

for NS in vcluster-tenant-a vcluster-shared; do
  kubectl create ns "${NS}" || true
done

cat >/tmp/vc.values.yaml <<'EOF'
controlPlane: { distro: k8s }
syncer:
  targetNamespace: REPLACE_NS
api: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
controllerManager: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
scheduler: { resources: { requests: { cpu: 50m,  memory: 64Mi } } }
EOF

sed "s/REPLACE_NS/vcluster-tenant-a/" /tmp/vc.values.yaml >/tmp/vc-a.yaml
vcluster create tenant-a -n vcluster-tenant-a --connect=false --expose -f /tmp/vc-a.yaml
vcluster connect tenant-a -n vcluster-tenant-a --update-current=false --print > /root/kubeconfig-tenant-a.yaml

sed "s/REPLACE_NS/vcluster-shared/" /tmp/vc.values.yaml >/tmp/vc-sh.yaml
vcluster create shared -n vcluster-shared --connect=false --expose -f /tmp/vc-sh.yaml

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
  - toCIDRSet: [ { cidr: "${INGRESS_VIP}/32" } ]
    toPorts:
    - ports: [ { port: "80", protocol: TCP }, { port: "443", protocol: TCP } ]
EOF

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/hubble.ingress.yaml" > "${render_dir}/hubble.ingress.yaml"
kubectl apply -f "${render_dir}/hubble.ingress.yaml"

ok "${STEP}"
