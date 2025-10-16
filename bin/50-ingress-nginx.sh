#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="ingress-nginx"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

curl -sL "https://get.helm.sh/helm-$(curl -s https://get.helm.sh/helm-latest-version)-linux-amd64.tar.gz" \
  | tar -xz && install -m 0755 linux-amd64/helm /usr/local/bin/helm && rm -rf linux-amd64

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl create ns ingress-nginx || true

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/ingress-nginx.values.yaml" > "${render_dir}/ingress-nginx.values.yaml"
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  -f "${render_dir}/ingress-nginx.values.yaml"

ok "${STEP}"
