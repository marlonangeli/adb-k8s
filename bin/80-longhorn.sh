#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="longhorn"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create ns longhorn-system || true

helm upgrade -i longhorn longhorn/longhorn -n longhorn-system \
  --set defaultSettings.defaultReplicaCount=2

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/longhorn.ingress.yaml" > "${render_dir}/longhorn.ingress.yaml"
kubectl apply -f "${render_dir}/longhorn.ingress.yaml"

ok "${STEP}"
