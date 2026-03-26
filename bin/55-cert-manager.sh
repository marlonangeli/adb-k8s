#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="cert-manager"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

if [[ "${TLS_ENABLED:-0}" != "1" ]]; then
  log "TLS desabilitado nas variáveis de ambiente; pulando instalação do cert-manager."
  ok "${STEP}"
  exit 0
fi

require_commands kubectl helm
ensure_helm
: "${TLS_CLUSTER_ISSUER:?defina TLS_CLUSTER_ISSUER em env.sh}"

helm repo add jetstack https://charts.jetstack.io
helm repo update

kubectl create ns cert-manager || true
helm upgrade -i cert-manager jetstack/cert-manager -n cert-manager \
  --set crds.enabled=true \
  --set extraArgs[0]=--enable-certificate-owner-ref=true

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=120s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

BOOTSTRAP_ISSUER="${TLS_CLUSTER_ISSUER}-bootstrap"

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${BOOTSTRAP_ISSUER}
spec:
  selfSigned: {}
EOF

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cluster-root-ca
  namespace: cert-manager
spec:
  isCA: true
  secretName: cluster-root-ca
  commonName: cluster-root-ca
  privateKey:
    rotationPolicy: Always
  subject:
    organizations:
    - UTFPR Lab
  issuerRef:
    kind: ClusterIssuer
    name: ${BOOTSTRAP_ISSUER}
EOF

kubectl -n cert-manager wait --for=condition=Ready certificate/cluster-root-ca --timeout=120s

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${TLS_CLUSTER_ISSUER}
spec:
  ca:
    secretName: cluster-root-ca
EOF

if [[ -n "${CERT_MANAGER_ACME_EMAIL:-}" ]]; then
  ACME_ISSUER_NAME="${CERT_MANAGER_ACME_ISSUER_NAME:-letsencrypt-prod}"
  ACME_SERVER="${CERT_MANAGER_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
  if [[ -n "${CERT_MANAGER_ACME_INGRESS_CLASS:-}" ]]; then
    ACME_INGRESS_CLASS="${CERT_MANAGER_ACME_INGRESS_CLASS}"
  elif [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
    ACME_INGRESS_CLASS="${VCLUSTER_INGRESS_CLASS:-native-oci}"
  else
    ACME_INGRESS_CLASS="nginx"
  fi

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ACME_ISSUER_NAME}
spec:
  acme:
    email: ${CERT_MANAGER_ACME_EMAIL}
    server: ${ACME_SERVER}
    privateKeySecretRef:
      name: ${ACME_ISSUER_NAME}-account-key
    solvers:
    - http01:
        ingress:
          class: ${ACME_INGRESS_CLASS}
EOF
  log "ClusterIssuer ACME '${ACME_ISSUER_NAME}' configurado (email ${CERT_MANAGER_ACME_EMAIL}). Ajuste TLS_CLUSTER_ISSUER=${ACME_ISSUER_NAME} em env/secrets se desejar usar certificados públicos."
fi

log "cert-manager instalado com emissor padrão ${TLS_CLUSTER_ISSUER}"
ok "${STEP}"
