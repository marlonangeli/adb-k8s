#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

STEP="observability"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

require_commands kubectl
ensure_helm
: "${CILIUM_SERVICE_MONITOR_PENDING:=0}"
: "${PROMETHEUS_REQUEST_CPU:=100m}"
: "${PROMETHEUS_SCRAPE_INTERVAL:=30s}"
: "${PROMETHEUS_CLUSTER_LABEL:=oke}"
: "${METRICS_SERVER_NAMESPACE:=kube-system}"
: "${METRICS_SERVER_REQUEST_CPU:=50m}"
: "${METRICS_SERVER_REQUEST_MEMORY:=96Mi}"
: "${METRICS_SERVER_LIMIT_CPU:=200m}"
: "${METRICS_SERVER_LIMIT_MEMORY:=256Mi}"
: "${METRICS_SERVER_RESOLUTION:=30s}"
: "${METRICS_SERVER_KUBELET_ADDRESS_TYPES:=InternalIP,ExternalIP,Hostname}"
: "${METRICS_SERVER_KUBELET_INSECURE_TLS:=1}"
: "${GRAFANA_ADMIN_USER:?defina GRAFANA_ADMIN_USER em secrets.env}"
: "${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD em secrets.env}"

GRAFANA_HOSTNAME=$(resolve_hostname "${GRAFANA_HOST_OVERRIDE:-}" "grafana")
GRAFANA_LOCAL_HOSTNAME=$(local_sslip_host "grafana")
kubectl create ns monitoring || true

if [[ "${TLS_ENABLED:-0}" == "1" && "${PLATFORM_MODE:-baremetal}" != "oke" ]]; then
  if kubectl -n monitoring get secret grafana-tls >/dev/null 2>&1; then
    log "certificado grafana-tls já existe; reutilizando emissão anterior."
  else
    INGRESS_IP=$(current_ingress_ip) || { log "Ingress IP não conhecido. Execute primeiro o script do ingress."; exit 1; }
    apply_certificate "monitoring" "grafana-tls" "grafana-tls" "${INGRESS_IP}" \
      "${GRAFANA_HOSTNAME}" "${GRAFANA_LOCAL_HOSTNAME}"
  fi
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
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

crd_dir="${chart_dir}/crds"
declare -a crd_files=()
if [[ -d "${crd_dir}" ]]; then
  shopt -s nullglob
  crd_files=("${crd_dir}"/*.yaml "${crd_dir}"/*.yml)
  shopt -u nullglob
  if ((${#crd_files[@]} > 0)); then
    mapfile -t crd_files < <(printf '%s\n' "${crd_files[@]}" | sort -u)
  fi
fi

CRD_APPLY_MAX_RETRIES="${CRD_APPLY_MAX_RETRIES:-5}"

apply_crd_manifest_with_retry() {
  local label="$1"
  local manifest_file="$2"
  local attempt=1
  local output

  while (( attempt <= CRD_APPLY_MAX_RETRIES )); do
    if output=$(kubectl apply --server-side --force-conflicts -f "${manifest_file}" 2>&1); then
      printf '%s\n' "${output}"
      return 0
    fi

    log "falha ao aplicar ${label} (tentativa ${attempt}/${CRD_APPLY_MAX_RETRIES})"
    printf '%s\n' "${output}"

    if [[ "${output}" == *"metadata.annotations: Too long"* ]]; then
      log "erro de tamanho de anotação detectado ao aplicar ${label}; abortando para evitar loop infinito."
      return 1
    fi

    ((attempt++))
    sleep 5
  done

  log "atingido limite de tentativas para ${label}."
  return 1
}

if ! kubectl get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
  log "Aplicando CRDs do kube-prometheus-stack de forma controlada"
  if ((${#crd_files[@]} == 0)); then
    crd_fallback_file="${chart_tmp}/kube-prometheus-stack-crds.yaml"
    helm show crds "${chart_source}" >"${crd_fallback_file}" || true
    if [[ ! -s "${crd_fallback_file}" ]]; then
      log "nenhum arquivo CRD encontrado em ${crd_dir} e fallback 'helm show crds' retornou vazio."
      log "verifique versão do chart/repositório antes de continuar."
      exit 1
    fi

    log "diretório de CRDs vazio; aplicando fallback via 'helm show crds'."
    if ! apply_crd_manifest_with_retry "CRDs via fallback" "${crd_fallback_file}"; then
      log "falha ao aplicar CRDs via fallback; interrompendo etapa observability."
      exit 1
    fi

    mapfile -t fallback_crd_names < <(awk '/^  name: /{print $2}' "${crd_fallback_file}" | sort -u)
    for crd_name in "${fallback_crd_names[@]}"; do
      [[ -n "${crd_name}" ]] || continue
      kubectl wait --for=condition=Established --timeout=120s "crd/${crd_name}" >/dev/null 2>&1 || true
    done
  else
    for crd_file in "${crd_files[@]}"; do
      crd_name=$(awk '/^  name: /{print $2; exit}' "${crd_file}" 2>/dev/null || true)
      if [[ -z "${crd_name}" ]]; then
        crd_name="$(basename "${crd_file}")"
      fi
      log "Aplicando CRD ${crd_name}"
      if ! apply_crd_manifest_with_retry "${crd_name}" "${crd_file}"; then
        log "falha ao aplicar ${crd_name}; interrompendo etapa observability."
        exit 1
      fi
      kubectl wait --for=condition=Established --timeout=120s "crd/${crd_name}" >/dev/null 2>&1 || true
      sleep 1
    done
  fi
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
  --set grafana.resources.requests.cpu=50m
  --set grafana.resources.requests.memory=192Mi
  --set grafana.resources.limits.cpu=500m
  --set grafana.resources.limits.memory=384Mi
  --set prometheusOperator.resources.requests.cpu=50m
  --set prometheusOperator.resources.requests.memory=192Mi
  --set prometheusOperator.resources.limits.cpu=400m
  --set prometheusOperator.resources.limits.memory=384Mi
  --set kubeStateMetrics.resources.requests.cpu=50m
  --set kubeStateMetrics.resources.requests.memory=192Mi
  --set kubeStateMetrics.resources.limits.cpu=300m
  --set kubeStateMetrics.resources.limits.memory=256Mi
  --set kubeStateMetrics.enabled=true
  --set kubeStateMetrics.replicaCount=1
  --set nodeExporter.resources.requests.cpu=40m
  --set nodeExporter.resources.requests.memory=48Mi
  --set nodeExporter.resources.limits.cpu=180m
  --set nodeExporter.resources.limits.memory=192Mi
  --set prometheus.prometheusSpec.resources.requests.cpu="${PROMETHEUS_REQUEST_CPU}"
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi
  --set prometheus.prometheusSpec.resources.limits.cpu=800m
  --set prometheus.prometheusSpec.resources.limits.memory=1.25Gi
  --set prometheus.prometheusSpec.retention=7d
  --set-string prometheus.prometheusSpec.externalLabels.cluster="${PROMETHEUS_CLUSTER_LABEL}"
  --set kubeScheduler.enabled=false
  --set kubeControllerManager.enabled=false
  --set kubeEtcd.enabled=false
  --set kubeProxy.enabled=false
  --set alertmanager.enabled=false
  --set prometheus.prometheusSpec.scrapeInterval="${PROMETHEUS_SCRAPE_INTERVAL}"
  --set global.scrapeInterval="${PROMETHEUS_SCRAPE_INTERVAL}"
)

if [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
  helm_args+=(--set grafana.ingress.enabled=false)
  helm_args+=(--set grafana.service.type=LoadBalancer)
  helm_args+=(--set "grafana.service.annotations.oci\\.oraclecloud\\.com/load-balancer-type=${GRAFANA_LB_TYPE}")
  helm_args+=(--set-string "grafana.service.annotations.oci-network-load-balancer\\.oraclecloud\\.com/internal=${GRAFANA_LB_INTERNAL}")
  helm_args+=(--set-string "grafana.service.annotations.oci\\.oraclecloud\\.com/security-rule-management-mode=${GRAFANA_LB_SECURITY_RULE_MODE}")
else
  helm_args+=(--set grafana.ingress.enabled=true)
  helm_args+=(--set grafana.ingress.ingressClassName=nginx)
  helm_args+=(--set grafana.ingress.hosts[0]="${GRAFANA_HOSTNAME}")
  helm_args+=(--set grafana.ingress.hosts[1]="${GRAFANA_LOCAL_HOSTNAME}")
fi

if [[ "${TLS_ENABLED:-0}" == "1" && "${PLATFORM_MODE:-baremetal}" != "oke" ]]; then
  helm_args+=(--set grafana.ingress.tls[0].hosts[0]="${GRAFANA_HOSTNAME}")
  helm_args+=(--set grafana.ingress.tls[0].hosts[1]="${GRAFANA_LOCAL_HOSTNAME}")
  helm_args+=(--set grafana.ingress.tls[0].secretName="grafana-tls")
elif [[ "${PLATFORM_MODE:-baremetal}" != "oke" ]]; then
  helm_args+=(--set-string grafana.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=false)
fi

helm "${helm_args[@]}"

metrics_server_values="${chart_tmp}/metrics-server-values.yaml"
cat >"${metrics_server_values}" <<EOF
resources:
  requests:
    cpu: ${METRICS_SERVER_REQUEST_CPU}
    memory: ${METRICS_SERVER_REQUEST_MEMORY}
  limits:
    cpu: ${METRICS_SERVER_LIMIT_CPU}
    memory: ${METRICS_SERVER_LIMIT_MEMORY}
args:
  - --kubelet-preferred-address-types=${METRICS_SERVER_KUBELET_ADDRESS_TYPES}
  - --kubelet-use-node-status-port
  - --metric-resolution=${METRICS_SERVER_RESOLUTION}
EOF

if [[ "${METRICS_SERVER_KUBELET_INSECURE_TLS}" == "1" ]]; then
  cat >>"${metrics_server_values}" <<'EOF'
  - --kubelet-insecure-tls
EOF
fi

helm upgrade --debug -i metrics-server metrics-server/metrics-server \
  -n "${METRICS_SERVER_NAMESPACE}" \
  --create-namespace \
  -f "${metrics_server_values}"

log "validando rollout do kube-prometheus-stack"
wait_rollout "${METRICS_SERVER_NAMESPACE}" deployment metrics-server
wait_rollout monitoring deployment kube-prometheus-stack-operator
wait_rollout monitoring deployment kube-prometheus-stack-grafana
if kubectl -n monitoring get deployment kube-prometheus-stack-kube-state-metrics >/dev/null 2>&1; then
  wait_rollout monitoring deployment kube-prometheus-stack-kube-state-metrics
fi
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

if [[ "${PLATFORM_MODE:-baremetal}" == "oke" ]]; then
  grafana_exposure_label="publico"
  if [[ "${GRAFANA_LB_INTERNAL}" == "true" ]]; then
    grafana_exposure_label="interno"
  fi
  grafana_endpoint="$(wait_for_lb_ip monitoring kube-prometheus-stack-grafana 300 || true)"
  if [[ -n "${grafana_endpoint}" ]]; then
    save_state_var "GRAFANA_HOSTNAME" "${grafana_endpoint}"
    log "Grafana disponível em http://${grafana_endpoint} (LoadBalancer ${grafana_exposure_label} OKE)."
  else
    log "Grafana instalado; endpoint LoadBalancer OKE não disponível no tempo esperado."
  fi
elif [[ "${TLS_ENABLED:-0}" == "1" ]]; then
  log "Grafana disponível em https://${GRAFANA_HOSTNAME} e https://${GRAFANA_LOCAL_HOSTNAME}"
else
  log "Grafana disponível em http://${GRAFANA_HOSTNAME} e http://${GRAFANA_LOCAL_HOSTNAME}"
fi

ok "${STEP}"
