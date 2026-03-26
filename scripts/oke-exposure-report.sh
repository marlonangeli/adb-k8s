#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Generate a quick exposure report for OKE edge resources.

Usage:
  oke-exposure-report.sh [--namespace <name>]

Options:
  --namespace <name>   Filter LoadBalancer services by namespace
  --help               Show this help
EOF
}

NAMESPACE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE_FILTER="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v mise >/dev/null 2>&1; then
  echo "ERROR: mise command not found in PATH" >&2
  exit 1
fi

k() { mise exec -- kubectl "$@"; }

normalize_no_value() {
  local value="${1:-}"
  if [[ "${value}" == "<no value>" ]]; then
    printf ''
    return
  fi
  printf '%s' "${value}"
}

echo "== OKE Exposure Report =="
echo
echo "LoadBalancer Services"
printf '%-18s %-34s %-8s %-10s %-10s %s\n' "NAMESPACE" "SERVICE" "TYPE" "EXPOSURE" "SEC_MODE" "ENDPOINT"

lb_rows="$(k get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.annotations.oci\.oraclecloud\.com/load-balancer-type}{"|"}{.metadata.annotations.service\.beta\.kubernetes\.io/oci-load-balancer-internal}{"|"}{.metadata.annotations.oci-network-load-balancer\.oraclecloud\.com/internal}{"|"}{.metadata.annotations.oci\.oraclecloud\.com/security-rule-management-mode}{"|"}{.status.loadBalancer.ingress[0].ip}{"|"}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null || true)"

if [[ -z "${lb_rows}" ]]; then
  echo "(none)"
else
  while IFS='|' read -r ns svc lb_type lb_internal nlb_internal sec_mode ip hostname; do
    [[ -n "${ns}" ]] || continue
    if [[ -n "${NAMESPACE_FILTER}" && "${ns}" != "${NAMESPACE_FILTER}" ]]; then
      continue
    fi

    lb_type="$(normalize_no_value "${lb_type}")"
    lb_internal="$(normalize_no_value "${lb_internal}")"
    nlb_internal="$(normalize_no_value "${nlb_internal}")"
    sec_mode="$(normalize_no_value "${sec_mode}")"
    ip="$(normalize_no_value "${ip}")"
    hostname="$(normalize_no_value "${hostname}")"

    [[ -n "${lb_type}" ]] || lb_type="<unset>"
    [[ -n "${sec_mode}" ]] || sec_mode="<unset>"

    exposure="PUBLIC"
    if [[ "${lb_internal}" == "true" || "${nlb_internal}" == "true" ]]; then
      exposure="INTERNAL"
    fi

    endpoint="pending"
    if [[ -n "${ip}" ]]; then
      endpoint="${ip}"
    elif [[ -n "${hostname}" ]]; then
      endpoint="${hostname}"
    fi

    printf '%-18s %-34s %-8s %-10s %-10s %s\n' "${ns}" "${svc}" "${lb_type}" "${exposure}" "${sec_mode}" "${endpoint}"
  done <<<"${lb_rows}"
fi

echo
echo "Ingress Resources"
printf '%-18s %-34s %-18s %s\n' "NAMESPACE" "INGRESS" "CLASS" "HOSTS"
ingress_rows="$(k get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.ingressClassName}{"|"}{range .spec.rules[*]}{.host}{","}{end}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "${ingress_rows}" ]]; then
  echo "(none)"
else
  while IFS='|' read -r ns name class hosts; do
    [[ -n "${ns}" ]] || continue
    [[ -n "${class}" ]] || class="<unset>"
    [[ -n "${hosts}" ]] || hosts="<no-host-rules>"
    printf '%-18s %-34s %-18s %s\n' "${ns}" "${name}" "${class}" "${hosts}"
  done <<<"${ingress_rows}"
fi

echo
echo "Gateway API Resources"
if k get gatewayclass >/dev/null 2>&1; then
  printf '%-18s %-34s %-22s %s\n' "NAMESPACE" "GATEWAY" "GATEWAYCLASS" "ADDRESSES"
  gateway_rows="$(k get gateway -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.gatewayClassName}{"|"}{range .status.addresses[*]}{.value}{","}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "${gateway_rows}" ]]; then
    echo "(none)"
  else
    while IFS='|' read -r ns name gateway_class addresses; do
      [[ -n "${ns}" ]] || continue
      [[ -n "${gateway_class}" ]] || gateway_class="<unset>"
      [[ -n "${addresses}" ]] || addresses="pending"
      printf '%-18s %-34s %-22s %s\n' "${ns}" "${name}" "${gateway_class}" "${addresses}"
    done <<<"${gateway_rows}"
  fi
else
  echo "(Gateway API CRDs not detected)"
fi
