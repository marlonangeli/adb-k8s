#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="rancher"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_helm
: "${RANCHER_ADMIN_PASSWORD:?defina RANCHER_ADMIN_PASSWORD em secrets.env}"
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create ns cattle-system || true

RANCHER_HOSTNAME=$(resolve_hostname "${RANCHER_HOST_OVERRIDE:-}" "rancher")
RANCHER_LOCAL_HOSTNAME=$(local_sslip_host "rancher")
INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }

helm_extra_args=()
if [[ -n "${RANCHER_HELM_KUBE_VERSION_OVERRIDE:-}" ]]; then
  helm_extra_args+=(--kube-version "${RANCHER_HELM_KUBE_VERSION_OVERRIDE}")
else
  server_version_raw=$(kubectl version --short 2>/dev/null | awk '/Server Version:/ {print $3}')
  if [[ -n "${server_version_raw}" ]]; then
    server_semver="${server_version_raw#v}"
    IFS='.' read -r server_major server_minor _ <<<"${server_semver}"
    if [[ -n "${server_major}" && -n "${server_minor}" ]]; then
      if (( server_major > 1 || (server_major == 1 && server_minor >= 34) )); then
        default_override="${RANCHER_HELM_KUBE_VERSION_FALLBACK:-1.33.9}"
        helm_extra_args+=(--kube-version "${default_override}")
        log "cluster Kubernetes ${server_semver} ainda não suportado pelo chart (<1.34); aplicando Rancher com --kube-version ${default_override}. Defina RANCHER_HELM_KUBE_VERSION_OVERRIDE para ajustar."
      fi
    fi
  fi
fi

apply_certificate "cattle-system" "rancher-tls" "rancher-tls" "${INGRESS_IP}" \
  "${RANCHER_HOSTNAME}" "${RANCHER_LOCAL_HOSTNAME}"

helm upgrade -i rancher rancher-latest/rancher -n cattle-system \
  --set hostname="${RANCHER_HOSTNAME}" \
  --set bootstrapPassword="${RANCHER_ADMIN_PASSWORD}" \
  --set ingress.tls.source=secret \
  --set privateCA=true \
  "${helm_extra_args[@]}"

for _ in {1..30}; do
  if kubectl -n cattle-system get ingress rancher >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl -n cattle-system get ingress rancher >/dev/null 2>&1 || { log "Ingress rancher não encontrado após instalação"; exit 1; }

kubectl -n cattle-system patch ingress rancher --type merge -p '{
  "spec": {
    "tls": [
      {
        "hosts": ["'"${RANCHER_HOSTNAME}"'","'"${RANCHER_LOCAL_HOSTNAME}"'"],
        "secretName": "rancher-tls"
      }
    ]
  }
}'

tls_hosts=$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.tls[?(@.secretName=="rancher-tls")].hosts[*]}' 2>/dev/null || echo "")
if ! grep -qw "${RANCHER_HOSTNAME}" <<<"${tls_hosts}" || ! grep -qw "${RANCHER_LOCAL_HOSTNAME}" <<<"${tls_hosts}"; then
  log "ingress rancher não apresenta todos os hosts esperados na configuração TLS (rancher-tls)."
  exit 1
fi

current_hosts=$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[*].host}' 2>/dev/null || echo "")
if ! grep -qw "${RANCHER_LOCAL_HOSTNAME}" <<<"${current_hosts}"; then
  kubectl -n cattle-system patch ingress rancher --type json -p='[
    {
      "op": "add",
      "path": "/spec/rules/-",
      "value": {
        "host": "'"${RANCHER_LOCAL_HOSTNAME}"'",
        "http": {
          "paths": [
            {
              "path": "/",
              "pathType": "Prefix",
              "backend": {
                "service": {
                  "name": "rancher",
                  "port": { "name": "https" }
                }
              }
            }
          ]
        }
      }
    }
  ]'

  updated_hosts=$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[*].host}' 2>/dev/null || echo "")
  if ! grep -qw "${RANCHER_LOCAL_HOSTNAME}" <<<"${updated_hosts}"; then
    log "falha ao adicionar o host local ${RANCHER_LOCAL_HOSTNAME} ao ingress rancher."
    exit 1
  fi
  log "host ${RANCHER_LOCAL_HOSTNAME} adicionado ao ingress rancher."
else
  log "host ${RANCHER_LOCAL_HOSTNAME} já configurado no ingress rancher."
fi

save_state_var "RANCHER_HOSTNAME" "${RANCHER_HOSTNAME}"
save_state_var "RANCHER_LOCAL_HOSTNAME" "${RANCHER_LOCAL_HOSTNAME}"
log "Rancher disponível em https://${RANCHER_HOSTNAME} e https://${RANCHER_LOCAL_HOSTNAME}"

ok "${STEP}"
