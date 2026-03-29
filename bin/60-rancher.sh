#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="rancher"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

if [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
  log "PLATFORM_MODE=oke: etapa Rancher legada desabilitada neste fluxo."
  ok "${STEP}"
  exit 0
fi

require_commands kubectl
ensure_helm
: "${RANCHER_ADMIN_PASSWORD:?defina RANCHER_ADMIN_PASSWORD em secrets.env}"
RANCHER_REPLICAS="${RANCHER_REPLICAS:-1}"
RANCHER_ENABLE_FLEET="${RANCHER_ENABLE_FLEET:-0}"
RANCHER_ENABLE_TELEMETRY="${RANCHER_ENABLE_TELEMETRY:-0}"
RANCHER_STARTUP_FAILURE_THRESHOLD="${RANCHER_STARTUP_FAILURE_THRESHOLD:-30}"
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create ns cattle-system || true

leftover_namespaces=$(kubectl get namespace --no-headers 2>/dev/null | awk '/(cattle|fleet|p-|user-|cluster-fleet)/ && $1!="cattle-system" && $2=="Terminating" {print $1 " " $2}' || true)
if [[ -n "${leftover_namespaces}" ]]; then
  log "Detectadas namespaces residuais do Rancher/Fleet:"
  printf '%s\n' "${leftover_namespaces}"
  log "Execute bin/remove-rancher.sh para limpar completamente antes de reinstalar o Rancher."
  exit 1
fi

leftover_apiservice=$(kubectl get apiservice 2>/dev/null | awk '/(cattle\\.io|rancher\\.io)/ {print $1}' || true)
if [[ -n "${leftover_apiservice}" ]]; then
  log "APIService remanescentes detectadas:"
  printf '%s\n' "${leftover_apiservice}"
  log "Execute bin/remove-rancher.sh para removê-las antes de prosseguir."
  exit 1
fi

if kubectl get namespace local >/dev/null 2>&1; then
  local_status=$(kubectl get namespace local -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${local_status}" == "Terminating" ]]; then
    log "Namespace 'local' encontra-se em Terminating; execute bin/remove-rancher.sh para restaurar o cluster local antes de reinstalar."
    exit 1
  fi
else
  kubectl create namespace local >/dev/null 2>&1 || true
  kubectl annotate namespace local management.cattle.io/no-default-sa-token="true" --overwrite >/dev/null 2>&1 || true
fi

RANCHER_HOSTNAME=$(resolve_hostname "${RANCHER_HOST_OVERRIDE:-}" "rancher")
RANCHER_LOCAL_HOSTNAME=$(local_sslip_host "rancher")
INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }

server_version_raw=""
server_semver=""
kubever_tmp=$(mktemp)
register_tmp "${kubever_tmp}"
if kubectl version -o json >"${kubever_tmp}" 2>/dev/null; then
  server_version_raw=$(sed -n 's/.*"gitVersion":[[:space:]]*"\(v[^"]*\)".*/\1/p' "${kubever_tmp}" | head -n1)
fi
if [[ -z "${server_version_raw}" ]]; then
  server_version_raw=$(kubectl version 2>/dev/null | awk -F': ' '/Server Version/ {print $2; exit}')
fi
server_semver="${server_version_raw#v}"

chart_source="rancher-latest/rancher"
chart_tmp=""
if [[ -n "${RANCHER_HELM_CHART_OVERRIDE:-}" ]]; then
  chart_source="${RANCHER_HELM_CHART_OVERRIDE}"
elif [[ -n "${server_semver}" ]]; then
  IFS='.' read -r server_major server_minor _ <<<"${server_semver}"
  if (( server_major > 1 || (server_major == 1 && server_minor >= 34) )); then
    chart_tmp=$(mktemp -d)
    trap 'if [[ -n "${chart_tmp}" ]]; then rm -rf "${chart_tmp}"; fi' EXIT
    helm pull rancher-latest/rancher --untar --untardir "${chart_tmp}"
    chart_source="${chart_tmp}/rancher"
    if grep -q 'kubeVersion:' "${chart_source}/Chart.yaml"; then
      sed -i -e 's/kubeVersion:.*/kubeVersion: ">= 1.24.0-0 < 1.36.0-0"/' "${chart_source}/Chart.yaml"
    else
      printf 'kubeVersion: ">= 1.24.0-0 < 1.36.0-0"\n' >>"${chart_source}/Chart.yaml"
    fi
    log "cluster Kubernetes ${server_semver} excede o limite suportado pelo chart; kubeVersion ajustado localmente para aceitar até <1.36.0."
  fi
fi

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  apply_certificate "cattle-system" "rancher-tls" "rancher-tls" "${INGRESS_IP}" \
    "${RANCHER_HOSTNAME}" "${RANCHER_LOCAL_HOSTNAME}"
fi

kubectl -n cattle-system delete job rancher-post-delete rancher-pre-delete --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
kubectl -n cattle-system delete job -l release=rancher --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true

helm_args=(
  upgrade -i rancher "${chart_source}" -n cattle-system
  --set hostname="${RANCHER_HOSTNAME}"
  --set bootstrapPassword="${RANCHER_ADMIN_PASSWORD}"
  --set ingress.ingressClassName="nginx"
  --set replicas="${RANCHER_REPLICAS}"
  --set startupProbe.failureThreshold="${RANCHER_STARTUP_FAILURE_THRESHOLD}"
  --set resources.requests.cpu=250m
  --set resources.requests.memory=512Mi
  --set resources.limits.cpu=600m
  --set resources.limits.memory=1Gi
)

if [[ "${RANCHER_ENABLE_FLEET}" != "1" ]]; then
  helm_args+=(--set features=fleet=false,provisioningv2=false)
  helm_args+=(--set global.cattle.fleet.enabled=false)
fi

if [[ "${RANCHER_ENABLE_TELEMETRY}" != "1" ]]; then
  helm_args+=(--set global.cattle.telemetry.enabled=false)
fi

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  helm_args+=(--set ingress.tls.source=secret --set privateCA=true)
else
  helm_args+=(--set tls=external)
  helm_args+=(--set-string ingress.extraAnnotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=false)
fi

log "Executando Helm com os argumentos: ${helm_args[*]}"
helm "${helm_args[@]}"

for _ in {1..30}; do
  if kubectl -n cattle-system get ingress rancher >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl -n cattle-system get ingress rancher >/dev/null 2>&1 || { log "Ingress rancher não encontrado após instalação"; exit 1; }

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
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
else
  kubectl -n cattle-system patch ingress rancher --type json -p='[
    { "op": "remove", "path": "/spec/tls" }
  ]' >/dev/null 2>&1 || true
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
                  "port": { "number": 80 }
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

kubectl -n cattle-system patch ingress rancher --type json -p='[
  {
    "op": "replace",
    "path": "/spec/rules/0/http/paths/0/backend/service/port",
    "value": { "number": 80 }
  }
]' >/dev/null 2>&1 || true

mapfile -t rancher_rule_hosts < <(kubectl -n cattle-system get ingress rancher -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}')
for idx in "${!rancher_rule_hosts[@]}"; do
  if [[ "${rancher_rule_hosts[idx]}" == "${RANCHER_LOCAL_HOSTNAME}" ]]; then
    patch_payload=$(printf '[{"op":"replace","path":"/spec/rules/%s/http/paths/0/backend/service/port","value":{"number":80}}]' "${idx}")
    kubectl -n cattle-system patch ingress rancher --type json -p="${patch_payload}" >/dev/null 2>&1 || true
    break
  fi
done

save_state_var "RANCHER_HOSTNAME" "${RANCHER_HOSTNAME}"
save_state_var "RANCHER_LOCAL_HOSTNAME" "${RANCHER_LOCAL_HOSTNAME}"
if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  log "Rancher disponível em https://${RANCHER_HOSTNAME} e https://${RANCHER_LOCAL_HOSTNAME}"
else
  log "Rancher disponível em http://${RANCHER_HOSTNAME} e http://${RANCHER_LOCAL_HOSTNAME}"
fi
if [[ "${TLS_ENABLED:-0}" != "1" ]]; then
  log "Se estiver migrando de uma instalação antiga, force o Ingress class para nginx: kubectl -n cattle-system patch ingress rancher --type merge -p '{\"spec\":{\"ingressClassName\":\"nginx\"}}'"
  log "e reescreva a anotação: kubectl -n cattle-system annotate ingress rancher kubernetes.io/ingress.class=nginx --overwrite"
fi
log "No primeiro acesso ao Rancher defina Settings -> Server URL para http://${RANCHER_HOSTNAME} (ou o host externo desejado)."

wait_rollout cattle-system deployment rancher

ok "${STEP}"
