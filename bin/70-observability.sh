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

chart_tmp=""
chart_source="prometheus-community/kube-prometheus-stack"
trap_cleanup=false

cleanup_chart_dir() {
  if [[ "${trap_cleanup}" == true && -n "${chart_tmp}" && -d "${chart_tmp}" ]]; then
    rm -rf "${chart_tmp}"
  fi
}
trap cleanup_chart_dir EXIT

# Pré-carrega o chart para aplicar CRDs de maneira sequencial (reduz pico no apiserver)
chart_tmp=$(mktemp -d)
trap_cleanup=true
helm pull prometheus-community/kube-prometheus-stack --untar --untardir "${chart_tmp}"
chart_dir="${chart_tmp}/kube-prometheus-stack"
if [[ ! -d "${chart_dir}" ]]; then
  log "chart kube-prometheus-stack não encontrado após helm pull."
  exit 1
fi
chart_source="${chart_dir}"

if ! kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
  log "Aplicando CRDs do kube-prometheus-stack de forma controlada"
  for crd_file in "${chart_dir}"/crds/*.yaml; do
    crd_name=$(awk '/^  name: /{print $2; exit}' "${crd_file}")
    if [[ -z "${crd_name}" ]]; then
      crd_name=$(basename "${crd_file}" .yaml)
    fi
    log "Aplicando CRD ${crd_name}"
    until kubectl apply -f "${crd_file}"; do
      log "falha ao aplicar ${crd_name}, tentando novamente em 5s"
      sleep 5
    done
    kubectl wait --for=condition=Established --timeout=120s "crd/${crd_name}" >/dev/null 2>&1 || true
    sleep 1
  done
else
  log "CRDs do kube-prometheus-stack já existentes; pulando reaplicação."
fi

helm_args=(
  upgrade --debug -i kube-prometheus-stack "${chart_source}" -n monitoring
  --skip-crds
  --atomic
  --timeout 15m
  --set grafana.adminUser="${GRAFANA_ADMIN_USER}"
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}"
  --set grafana.ingress.enabled=true
  --set grafana.ingress.ingressClassName=nginx
  --set grafana.ingress.hosts[0]="${GRAFANA_HOSTNAME}"
  --set grafana.ingress.hosts[1]="${GRAFANA_LOCAL_HOSTNAME}"
  --set grafana.resources.requests.cpu=100m
  --set grafana.resources.requests.memory=192Mi
  --set grafana.resources.limits.cpu=500m
  --set grafana.resources.limits.memory=384Mi
  --set prometheusOperator.resources.requests.cpu=100m
  --set prometheusOperator.resources.requests.memory=192Mi
  --set prometheusOperator.resources.limits.cpu=400m
  --set prometheusOperator.resources.limits.memory=384Mi
  --set kubeStateMetrics.resources.requests.cpu=100m
  --set kubeStateMetrics.resources.requests.memory=192Mi
  --set kubeStateMetrics.resources.limits.cpu=300m
  --set kubeStateMetrics.resources.limits.memory=256Mi
  --set nodeExporter.resources.requests.cpu=40m
  --set nodeExporter.resources.requests.memory=48Mi
  --set nodeExporter.resources.limits.cpu=180m
  --set nodeExporter.resources.limits.memory=192Mi
  --set prometheus.prometheusSpec.resources.requests.cpu=250m
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi
  --set prometheus.prometheusSpec.resources.limits.cpu=800m
  --set prometheus.prometheusSpec.resources.limits.memory=1.25Gi
  --set prometheus.prometheusSpec.retention=7d
  --set kubeScheduler.enabled=false
  --set kubeControllerManager.enabled=false
  --set kubeEtcd.enabled=false
  --set kubeProxy.enabled=false
  --set alertmanager.enabled=false
  --set global.scrapeInterval=60s
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
