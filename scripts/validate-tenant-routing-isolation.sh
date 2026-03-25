#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STATE_DIR="${STATE_DIR:-/var/opt/cluster-state}"
TENANT_A_KUBECONFIG="${TENANT_A_KUBECONFIG:-${STATE_DIR}/kubeconfig-abc.yaml}"
TENANT_B_KUBECONFIG="${TENANT_B_KUBECONFIG:-${STATE_DIR}/kubeconfig-xyz.yaml}"
SHARED_KUBECONFIG="${SHARED_KUBECONFIG:-${STATE_DIR}/kubeconfig-shared.yaml}"

TENANT_NS="${TENANT_NS:-app}"
SHARED_NS="${SHARED_NS:-processing}"

TENANT_API_HEALTH_PATH="${TENANT_API_HEALTH_PATH:-/actuator/health/readiness}"
INTERPOLATION_HEALTH_PATH="${INTERPOLATION_HEALTH_PATH:-/healthz}"

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-10}"
A_TO_B_FORBIDDEN_URL="${A_TO_B_FORBIDDEN_URL:-}"
B_TO_A_FORBIDDEN_URL="${B_TO_A_FORBIDDEN_URL:-}"

PASS=0
FAIL=0
SKIP=0
PROBES=()

usage() {
  cat <<'EOF'
Validate OKE tenant routing and isolation with vCluster kubeconfigs.

Usage:
  validate-tenant-routing-isolation.sh [options]

Options:
  --tenant-a-kubeconfig <path>   Default: /var/opt/cluster-state/kubeconfig-abc.yaml
  --tenant-b-kubeconfig <path>   Default: /var/opt/cluster-state/kubeconfig-xyz.yaml
  --shared-kubeconfig <path>     Default: /var/opt/cluster-state/kubeconfig-shared.yaml
  --tenant-namespace <name>      Default: app
  --shared-namespace <name>      Default: processing
  --timeout-seconds <n>          Curl max/connect timeout (default: 10)
  --a-to-b-url <url>             Optional explicit cross-tenant deny probe from tenant A
  --b-to-a-url <url>             Optional explicit cross-tenant deny probe from tenant B
  --help                         Show this help

Examples:
  scripts/validate-tenant-routing-isolation.sh

  scripts/validate-tenant-routing-isolation.sh \
    --a-to-b-url "http://tenant-b.internal/actuator/health/readiness" \
    --b-to-a-url "http://tenant-a.internal/actuator/health/readiness"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-a-kubeconfig)
      TENANT_A_KUBECONFIG="$2"; shift 2 ;;
    --tenant-b-kubeconfig)
      TENANT_B_KUBECONFIG="$2"; shift 2 ;;
    --shared-kubeconfig)
      SHARED_KUBECONFIG="$2"; shift 2 ;;
    --tenant-namespace)
      TENANT_NS="$2"; shift 2 ;;
    --shared-namespace)
      SHARED_NS="$2"; shift 2 ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="$2"; shift 2 ;;
    --a-to-b-url)
      A_TO_B_FORBIDDEN_URL="$2"; shift 2 ;;
    --b-to-a-url)
      B_TO_A_FORBIDDEN_URL="$2"; shift 2 ;;
    --help|-h)
      usage
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -f "${STATE_DIR}/dynamic.env" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_DIR}/dynamic.env" || true
fi

if [[ -n "${VCLUSTER_SHARED_INTERPOLATION_HOST:-}" ]]; then
  SHARED_INTERPOLATION_URL="http://${VCLUSTER_SHARED_INTERPOLATION_HOST}${INTERPOLATION_HEALTH_PATH}"
else
  SHARED_INTERPOLATION_URL="http://adb-interpolation-api.processing.svc.cluster.local${INTERPOLATION_HEALTH_PATH}"
fi

A_LOCAL_API_URL="http://adb-api.${TENANT_NS}.svc.cluster.local${TENANT_API_HEALTH_PATH}"
B_LOCAL_API_URL="http://adb-api.${TENANT_NS}.svc.cluster.local${TENANT_API_HEALTH_PATH}"

k() { mise exec -- kubectl "$@"; }

pass() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

skip() {
  SKIP=$((SKIP + 1))
  printf 'SKIP: %s\n' "$1"
}

require_file() {
  local file_path="$1"
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: kubeconfig not found: ${file_path}" >&2
    exit 1
  fi
}

normalize_no_value() {
  local value="${1:-}"
  if [[ "${value}" == "<no value>" ]]; then
    printf ''
    return
  fi
  printf '%s' "${value}"
}

cleanup() {
  local item kubeconfig ns pod
  for item in "${PROBES[@]}"; do
    IFS='|' read -r kubeconfig ns pod <<<"${item}"
    k --kubeconfig "${kubeconfig}" -n "${ns}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

create_probe_pod() {
  local kubeconfig="$1" ns="$2" tag="$3"
  local pod_name
  pod_name="netcheck-${tag}-$(date +%s)-$RANDOM"

  k --kubeconfig "${kubeconfig}" -n "${ns}" run "${pod_name}" \
    --image=curlimages/curl:8.8.0 \
    --restart=Never \
    --command -- sh -c 'sleep 300' >/dev/null

  k --kubeconfig "${kubeconfig}" -n "${ns}" wait --for=condition=Ready "pod/${pod_name}" --timeout=120s >/dev/null
  PROBES+=("${kubeconfig}|${ns}|${pod_name}")
  printf '%s' "${pod_name}"
}

curl_ok() {
  local kubeconfig="$1" ns="$2" pod_name="$3" url="$4" label="$5"
  if k --kubeconfig "${kubeconfig}" -n "${ns}" exec "${pod_name}" -- \
    curl -fsS --connect-timeout "${TIMEOUT_SECONDS}" --max-time "${TIMEOUT_SECONDS}" "${url}" >/dev/null 2>&1; then
    pass "${label}"
  else
    fail "${label} (url=${url})"
  fi
}

curl_blocked() {
  local kubeconfig="$1" ns="$2" pod_name="$3" url="$4" label="$5"
  if k --kubeconfig "${kubeconfig}" -n "${ns}" exec "${pod_name}" -- \
    curl -fsS --connect-timeout "${TIMEOUT_SECONDS}" --max-time "${TIMEOUT_SECONDS}" "${url}" >/dev/null 2>&1; then
    fail "${label} should be blocked but succeeded (url=${url})"
  else
    pass "${label} blocked as expected"
  fi
}

check_private_surface() {
  local name="$1" kubeconfig="$2"
  local svc_type node_port lb_ip ingress_list

  svc_type="$(k --kubeconfig "${kubeconfig}" -n "${TENANT_NS}" get svc adb-api -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [[ "${svc_type}" == "ClusterIP" ]]; then
    pass "${name}: adb-api Service type is ClusterIP"
  else
    fail "${name}: adb-api Service type expected ClusterIP, got '${svc_type}'"
  fi

  node_port="$(normalize_no_value "$(k --kubeconfig "${kubeconfig}" -n "${TENANT_NS}" get svc adb-api -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)")"
  if [[ -z "${node_port}" ]]; then
    pass "${name}: adb-api has no NodePort"
  else
    fail "${name}: adb-api should not expose NodePort (found ${node_port})"
  fi

  lb_ip="$(normalize_no_value "$(k --kubeconfig "${kubeconfig}" -n "${TENANT_NS}" get svc adb-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)")"
  if [[ -z "${lb_ip}" ]]; then
    pass "${name}: adb-api has no LoadBalancer IP"
  else
    fail "${name}: adb-api should not expose LoadBalancer IP (found ${lb_ip})"
  fi

  ingress_list="$(k --kubeconfig "${kubeconfig}" -n "${TENANT_NS}" get ingress -o name 2>/dev/null || true)"
  if [[ -z "${ingress_list}" ]]; then
    pass "${name}: no Ingress objects in namespace '${TENANT_NS}'"
  else
    fail "${name}: expected no Ingress in '${TENANT_NS}', found '${ingress_list//$'\n'/, }'"
  fi
}

check_shared_surface() {
  local svc_type internal_ann security_mode

  svc_type="$(k --kubeconfig "${SHARED_KUBECONFIG}" -n "${SHARED_NS}" get svc adb-interpolation-api -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [[ "${svc_type}" == "LoadBalancer" ]]; then
    pass "Shared interpolation Service type is LoadBalancer"
  else
    fail "Shared interpolation Service type expected LoadBalancer, got '${svc_type}'"
  fi

  internal_ann="$(k --kubeconfig "${SHARED_KUBECONFIG}" -n "${SHARED_NS}" get svc adb-interpolation-api -o jsonpath='{.metadata.annotations.oci-network-load-balancer\.oraclecloud\.com/internal}' 2>/dev/null || true)"
  if [[ "${internal_ann}" == "true" ]]; then
    pass "Shared interpolation NLB is internal=true"
  else
    fail "Shared interpolation NLB should be internal=true (got '${internal_ann}')"
  fi

  security_mode="$(k --kubeconfig "${SHARED_KUBECONFIG}" -n "${SHARED_NS}" get svc adb-interpolation-api -o jsonpath='{.metadata.annotations.oci\.oraclecloud\.com/security-rule-management-mode}' 2>/dev/null || true)"
  if [[ "${security_mode}" == "NSG" ]]; then
    pass "Shared interpolation uses NSG security-rule mode"
  else
    fail "Shared interpolation should use NSG mode (got '${security_mode}')"
  fi
}

if ! command -v mise >/dev/null 2>&1; then
  echo "ERROR: mise command not found in PATH" >&2
  exit 1
fi

require_file "${TENANT_A_KUBECONFIG}"
require_file "${TENANT_B_KUBECONFIG}"
require_file "${SHARED_KUBECONFIG}"

printf '== Static isolation checks ==\n'
printf 'Tenant A kubeconfig: %s\n' "${TENANT_A_KUBECONFIG}"
printf 'Tenant B kubeconfig: %s\n' "${TENANT_B_KUBECONFIG}"
printf 'Shared   kubeconfig: %s\n' "${SHARED_KUBECONFIG}"

check_private_surface "Tenant A" "${TENANT_A_KUBECONFIG}"
check_private_surface "Tenant B" "${TENANT_B_KUBECONFIG}"
check_shared_surface

printf '\n== Runtime access checks ==\n'
printf 'Tenant A local API URL: %s\n' "${A_LOCAL_API_URL}"
printf 'Tenant B local API URL: %s\n' "${B_LOCAL_API_URL}"
printf 'Shared interpolation URL: %s\n' "${SHARED_INTERPOLATION_URL}"

POD_A="$(create_probe_pod "${TENANT_A_KUBECONFIG}" "${TENANT_NS}" "a")"
POD_B="$(create_probe_pod "${TENANT_B_KUBECONFIG}" "${TENANT_NS}" "b")"

curl_ok "${TENANT_A_KUBECONFIG}" "${TENANT_NS}" "${POD_A}" "${A_LOCAL_API_URL}" "Tenant A -> adb-api (own tenant)"
curl_ok "${TENANT_B_KUBECONFIG}" "${TENANT_NS}" "${POD_B}" "${B_LOCAL_API_URL}" "Tenant B -> adb-api (own tenant)"
curl_ok "${TENANT_A_KUBECONFIG}" "${TENANT_NS}" "${POD_A}" "${SHARED_INTERPOLATION_URL}" "Tenant A -> shared interpolation"
curl_ok "${TENANT_B_KUBECONFIG}" "${TENANT_NS}" "${POD_B}" "${SHARED_INTERPOLATION_URL}" "Tenant B -> shared interpolation"

if [[ -n "${A_TO_B_FORBIDDEN_URL}" ]]; then
  curl_blocked "${TENANT_A_KUBECONFIG}" "${TENANT_NS}" "${POD_A}" "${A_TO_B_FORBIDDEN_URL}" "Tenant A -> Tenant B adb-api"
else
  skip "A_TO_B_FORBIDDEN_URL not set (explicit cross-tenant deny probe skipped)"
fi

if [[ -n "${B_TO_A_FORBIDDEN_URL}" ]]; then
  curl_blocked "${TENANT_B_KUBECONFIG}" "${TENANT_NS}" "${POD_B}" "${B_TO_A_FORBIDDEN_URL}" "Tenant B -> Tenant A adb-api"
else
  skip "B_TO_A_FORBIDDEN_URL not set (explicit cross-tenant deny probe skipped)"
fi

printf '\n== Summary ==\n'
printf 'PASS=%d FAIL=%d SKIP=%d\n' "${PASS}" "${FAIL}" "${SKIP}"

if (( FAIL > 0 )); then
  exit 1
fi
