#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH=""
NAMESPACE=""
SERVICE=""
SELECTOR=""
SERVICE_CONTAINS=""

usage() {
  cat <<'EOF'
Usage:
  k8s-service-lb-ip.sh -k <kubeconfig> -n <namespace> -s <service>
  k8s-service-lb-ip.sh -k <kubeconfig> --selector <label-selector> [--service-contains <text>]

Examples:
  ./k8s-service-lb-ip.sh \
    -k adb-k8s/.state/cluster-state/kubeconfig-shared.yaml \
    -n processing \
    -s adb-interpolation-api

  ./k8s-service-lb-ip.sh \
    -k ~/.kube/config \
    --selector vcluster.loft.sh/namespace=processing \
    --service-contains adb-interpolation-api
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--kubeconfig)
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -s|--service)
      SERVICE="$2"
      shift 2
      ;;
    --selector)
      SELECTOR="$2"
      shift 2
      ;;
    --service-contains)
      SERVICE_CONTAINS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require kubectl
require jq

KUBECTL=(kubectl)

if [[ -n "$KUBECONFIG_PATH" ]]; then
  KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")
fi

if [[ -n "$SELECTOR" ]]; then
  SERVICES_JSON="$("${KUBECTL[@]}" get svc -A -l "$SELECTOR" -o json)"

  IP="$(
    jq -r --arg contains "$SERVICE_CONTAINS" '
      .items[]
      | select($contains == "" or (.metadata.name | contains($contains)))
      | .status.loadBalancer.ingress[0].ip
        // .status.loadBalancer.ingress[0].hostname
        // empty
    ' <<<"$SERVICES_JSON" | head -n 1
  )"
else
  if [[ -z "$NAMESPACE" || -z "$SERVICE" ]]; then
    echo "Exact mode requires --namespace and --service." >&2
    usage >&2
    exit 1
  fi

  IP="$(
    "${KUBECTL[@]}" -n "$NAMESPACE" get svc "$SERVICE" -o json \
      | jq -r '.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // empty'
  )"
fi

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "LoadBalancer IP/hostname not found." >&2
  exit 2
fi

printf '%s\n' "$IP"
