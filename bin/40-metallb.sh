#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="metallb"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl envsubst


METALLB_VERSION="v0.15.2"
log "Aplicando MetalLB (${METALLB_VERSION})"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml
wait_rollout metallb-system deploy controller

template=$(render_template "${ROOT_DIR}/manifests/metallb-pool.yaml")
kubectl apply -f "${template}"

ok "${STEP}"
