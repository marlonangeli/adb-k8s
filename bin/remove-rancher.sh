#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
need_root

require_commands kubectl helm

NAMESPACE="cattle-system"
RELEASE="rancher"

log "iniciando remoção do Rancher (namespace=${NAMESPACE}, release=${RELEASE})"

if helm -n "${NAMESPACE}" list --short 2>/dev/null | grep -qx "${RELEASE}"; then
  log "desinstalando release Helm ${RELEASE}"
  helm -n "${NAMESPACE}" uninstall "${RELEASE}" || log "falha ao desinstalar via Helm; continuando com remoção manual"
else
  log "release Helm ${RELEASE} não encontrada (já removida?)"
fi

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "removendo namespace ${NAMESPACE}"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
  sleep 5
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log "namespace ${NAMESPACE} ainda em término; removendo finalizers (se existirem)"
    kubectl patch namespace "${NAMESPACE}" -p '{"metadata":{"finalizers": []}}' --type=merge >/dev/null 2>&1 || true
    sleep 3
  fi
else
  log "namespace ${NAMESPACE} não existe"
fi

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "namespace ${NAMESPACE} ainda não terminou de ser removido:"
  kubectl get namespace "${NAMESPACE}" -o yaml

  log "removendo CRDs relacionados ao Rancher"
  kubectl get crd | awk '/cattle/ {print $1}' | xargs -r kubectl delete crd --ignore-not-found
  sleep 5

  cat <<'EOF' | kubectl replace --raw "/api/v1/namespaces/cattle-system/finalize" -f -
{
  "apiVersion": "v1",
  "kind": "Namespace",
  "metadata": { "name": "cattle-system" },
  "spec": { "finalizers": [] }
}
EOF

  exit 1
fi

leftover_resources=$(kubectl get all -A | grep -Ei 'rancher|cattle-system' || true)
leftover_crds=$(kubectl get crd | grep -Ei 'rancher' || true)

if [[ -n "${leftover_resources}" || -n "${leftover_crds}" ]]; then
  log "resíduos do Rancher detectados:"
  [[ -n "${leftover_resources}" ]] && printf '%s\n' "${leftover_resources}"
  [[ -n "${leftover_crds}" ]] && printf '%s\n' "${leftover_crds}"
  exit 1
fi

log "remoção do Rancher concluída sem resíduos detectados."
