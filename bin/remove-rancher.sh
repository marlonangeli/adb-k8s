#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
require_commands kubectl helm python3

RELEASE="rancher"
PRIMARY_NS="cattle-system"
mapfile -t DISCOVERED_NAMESPACES < <(
  kubectl get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(cattle|fleet|cluster-fleet|local$|p-|user-)' | sort -u
)

finalize_namespace() {
  local ns="$1"
  log "removendo finalizers da namespace ${ns}"
  tmp_file=$(mktemp)
  if kubectl get namespace "${ns}" -o json >"${tmp_file}" 2>/dev/null; then
    python3 - "${tmp_file}" <<'PY' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
if data.get('spec') and data['spec'].get('finalizers'):
    data['spec']['finalizers'] = []
json.dump(data, sys.stdout)
PY
  fi
  kubectl patch namespace "${ns}" --type=merge -p '{"spec":{"finalizers":[]}}' >/dev/null 2>&1 || true
  rm -f "${tmp_file}"
}

delete_namespace() {
  local ns="$1"
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "  limpando recursos na namespace ${ns}"
    kubectl api-resources --verbs=delete --namespaced -o name 2>/dev/null | while read -r res; do
      [[ -z "${res}" ]] && continue
      kubectl -n "${ns}" delete "${res}" --all --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
    done
  fi

  kubectl delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  sleep 5
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "namespace ${ns} ainda em estado Terminating"
    finalize_namespace "${ns}"
  fi
}

log "iniciando remoção do Rancher (release=${RELEASE})"

if helm -n "${PRIMARY_NS}" list --short 2>/dev/null | grep -qx "${RELEASE}"; then
  log "desinstalando release Helm ${RELEASE}"
  helm -n "${PRIMARY_NS}" uninstall "${RELEASE}" || log "falha ao desinstalar via Helm; continuando com remoção manual"
else
  log "release Helm ${RELEASE} não encontrada (já removida?)"
fi

# Remoção das namespaces gerenciadas pelo Rancher/Fleet
declare -A UNIQUE_NS=()
UNIQUE_NS["${PRIMARY_NS}"]=1
for ns in "${DISCOVERED_NAMESPACES[@]}"; do
  UNIQUE_NS["${ns}"]=1
done

for ns in "${!UNIQUE_NS[@]}"; do
  if kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "apagando namespace ${ns}"
    delete_namespace "${ns}"
  else
    log "namespace ${ns} não encontrada"
  fi
done

# Remoção de CRDs ligados ao Rancher/Fleet
log "removendo CRDs relacionados ao Rancher/Fleet (sem aguardar conclusão)"
kubectl get crd | awk '/(\.cattle\.io|fleet\.cattle\.io|rancher\.io)/{print $1}' | sort -u | while read -r crd; do
  [[ -z "${crd}" ]] && continue
  log "  deletando CRD ${crd}"
  kubectl patch crd "${crd}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete crd "${crd}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done

# Remoção de APIService agregadas
log "removendo APIService agregadas do Rancher/Fleet (se existirem)"
kubectl get apiservice | awk '/(fleet\.cattle\.io|management\.cattle\.io|rancher\.io)/{print $1}' | sort -u | while read -r api; do
  [[ -z "${api}" ]] && continue
  log "  deletando APIService ${api}"
  kubectl patch apiservice "${api}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete apiservice "${api}" --ignore-not-found >/dev/null 2>&1 || true
done

# Mutating/Validating webhook configurations
log "removendo MutatingWebhookConfigurations do Rancher/Fleet"
kubectl get mutatingwebhookconfiguration | awk '/(cattle|fleet|rancher)/{print $1}' | sort -u | while read -r mw; do
  [[ -z "${mw}" ]] && continue
  log "  deletando MutatingWebhookConfiguration ${mw}"
  kubectl patch mutatingwebhookconfiguration "${mw}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete mutatingwebhookconfiguration "${mw}" --ignore-not-found >/dev/null 2>&1 || true
done

log "removendo ValidatingWebhookConfigurations do Rancher/Fleet"
kubectl get validatingwebhookconfiguration | awk '/(cattle|fleet|rancher)/{print $1}' | sort -u | while read -r vw; do
  [[ -z "${vw}" ]] && continue
  log "  deletando ValidatingWebhookConfiguration ${vw}"
  kubectl patch validatingwebhookconfiguration "${vw}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete validatingwebhookconfiguration "${vw}" --ignore-not-found >/dev/null 2>&1 || true
done

# Limpeza de ClusterRoles/Bindings com labels do Rancher
log "removendo ClusterRoles e ClusterRoleBindings rotulados com cattle.io"
kubectl get clusterrole -l "app.kubernetes.io/managed-by=rancher" -o name | \
  xargs -r kubectl delete >/dev/null 2>&1 || true
kubectl get clusterrolebinding -l "app.kubernetes.io/managed-by=rancher" -o name | \
  xargs -r kubectl delete >/dev/null 2>&1 || true

sleep 5

attempt=0
while :; do
  leftover_ns=$(kubectl get namespace 2>/dev/null | awk '/Terminating/ && /cattle|fleet|p-|user-|cluster-fleet/ {print $1}' || true)
  if [[ -z "${leftover_ns}" ]]; then
    break
  fi

  if (( attempt >= 1 )); then
    break
  fi

  log "forçando limpeza adicional de namespaces restantes"
  for ns in ${leftover_ns}; do
    delete_namespace "${ns}"
  done
  sleep 5
  ((attempt++))
done

leftover_ns=$(kubectl get namespace 2>/dev/null | awk '/cattle|fleet|p-|user-|cluster-fleet/ {print $1}' || true)
leftover_crds=$(kubectl get crd 2>/dev/null | awk '/(\.cattle\.io|fleet\.cattle\.io|rancher\.io)/ {print $1}' || true)
leftover_workloads=$(kubectl get all -A 2>/dev/null | grep -Ei 'rancher|cattle|fleet' || true)

if [[ -n "${leftover_ns}" || -n "${leftover_crds}" || -n "${leftover_workloads}" ]]; then
  log "resíduos detectados após remoção do Rancher:"
  [[ -n "${leftover_ns}" ]] && { echo "Namespaces:"; printf '  %s\n' ${leftover_ns}; }
  [[ -n "${leftover_crds}" ]] && { echo "CRDs:"; printf '  %s\n' ${leftover_crds}; }
  [[ -n "${leftover_workloads}" ]] && { echo "Recursos:"; printf '%s\n' "${leftover_workloads}"; }
  exit 1
fi

log "remoção do Rancher concluída sem resíduos detectados."
