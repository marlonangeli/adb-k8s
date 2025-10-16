#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="metallb"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
wait_rollout metallb-system deploy controller

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/metallb-pool.yaml" > "${render_dir}/metallb-pool.yaml"
kubectl apply -f "${render_dir}/metallb-pool.yaml"

ok "${STEP}"
