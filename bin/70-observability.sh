#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="observability"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_helm
: "${CILIUM_SERVICE_MONITOR_PENDING:=0}"
: "${GRAFANA_ADMIN_USER:?defina GRAFANA_ADMIN_USER em secrets.env}"
: "${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD em secrets.env}"

GRAFANA_HOSTNAME=$(resolve_hostname "${GRAFANA_HOST_OVERRIDE:-}" "grafana")
GRAFANA_LOCAL_HOSTNAME=$(local_sslip_host "grafana")
INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }
kubectl create ns monitoring || true

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  if kubectl -n monitoring get secret grafana-tls >/dev/null 2>&1; then
    log "certificado grafana-tls já existe; reutilizando emissão anterior."
  else
    apply_certificate "monitoring" "grafana-tls" "grafana-tls" "${INGRESS_IP}" \
      "${GRAFANA_HOSTNAME}" "${GRAFANA_LOCAL_HOSTNAME}"
  fi
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm_args=(
  upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring
  --set grafana.adminUser="${GRAFANA_ADMIN_USER}"
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}"
  --set grafana.ingress.enabled=true
  --set grafana.ingress.ingressClassName=nginx
  --set grafana.ingress.hosts[0]="${GRAFANA_HOSTNAME}"
  --set grafana.ingress.hosts[1]="${GRAFANA_LOCAL_HOSTNAME}"
)

if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  helm_args+=(--set grafana.ingress.tls[0].hosts[0]="${GRAFANA_HOSTNAME}")
  helm_args+=(--set grafana.ingress.tls[0].hosts[1]="${GRAFANA_LOCAL_HOSTNAME}")
  helm_args+=(--set grafana.ingress.tls[0].secretName="grafana-tls")
else
  helm_args+=(--set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=false)
fi

helm "${helm_args[@]}"

log "validando rollout do kube-prometheus-stack"
wait_rollout monitoring deployment kube-prometheus-stack-operator
wait_rollout monitoring deployment kube-prometheus-stack-grafana
if kubectl -n monitoring get statefulset kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  wait_rollout monitoring statefulset kube-prometheus-stack-prometheus
fi
if kubectl -n monitoring get statefulset kube-prometheus-stack-alertmanager >/dev/null 2>&1; then
  wait_rollout monitoring statefulset kube-prometheus-stack-alertmanager
fi

if [[ "${CILIUM_SERVICE_MONITOR_PENDING}" == "1" ]]; then
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    log "habilitando ServiceMonitor do Cilium agora que os CRDs estão disponíveis"
    ensure_cilium_cli
    cilium upgrade --reuse-values \
      --set prometheus.serviceMonitor.enabled=true \
      --set operator.prometheus.enabled=true \
      --set prometheus.enabled=true
    cilium status --wait
    save_state_var "CILIUM_SERVICE_MONITOR_PENDING" "0"
  else
    log "CRD servicemonitors.monitoring.coreos.com ainda indisponível; mantenha o Cilium pendente e reexecute este passo após aplicar as CRDs."
  fi
fi

save_state_var "GRAFANA_HOSTNAME" "${GRAFANA_HOSTNAME}"
save_state_var "GRAFANA_LOCAL_HOSTNAME" "${GRAFANA_LOCAL_HOSTNAME}"
if [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  log "Grafana disponível em https://${GRAFANA_HOSTNAME} e https://${GRAFANA_LOCAL_HOSTNAME}"
else
  log "Grafana disponível em http://${GRAFANA_HOSTNAME} e http://${GRAFANA_LOCAL_HOSTNAME}"
fi

ok "${STEP}"
