#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STATE_DIR:-/var/opt/cluster-state}"
STRICT_MODE=0

usage() {
  cat <<'EOF'
Run preflight checks before OKE deployment stages.

Usage:
  oke-preflight-check.sh [--strict]

Options:
  --strict   Treat warnings as failures
  --help     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT_MODE=1
      shift
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

PASS=0
WARN=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}

warn() {
  WARN=$((WARN + 1))
  printf 'WARN: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

check_command() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    ok "command '${name}' available"
  else
    fail "command '${name}' not found"
  fi
}

check_optional_command() {
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    ok "optional command '${name}' available"
  else
    warn "optional command '${name}' not found"
  fi
}

k() { mise exec -- kubectl "$@"; }

echo "== OKE Preflight Checks =="

check_command mise
check_optional_command oci
check_optional_command helm
check_optional_command vcluster

if command -v mise >/dev/null 2>&1; then
  if mise exec -- kubectl version --client >/dev/null 2>&1; then
    ok "kubectl available through mise"
  else
    fail "kubectl not available through mise"
  fi

  if current_context="$(k config current-context 2>/dev/null || true)"; then
    if [[ -n "${current_context}" ]]; then
      ok "kubectl current-context detected: ${current_context}"
    else
      fail "kubectl current-context is empty"
    fi
  else
    fail "unable to read kubectl current-context"
  fi

  if k get nodes >/dev/null 2>&1; then
    ok "cluster API reachable (kubectl get nodes)"
  else
    fail "cluster API not reachable (kubectl get nodes failed)"
  fi

  if k get pods -A >/dev/null 2>&1; then
    ok "cluster workload listing works (kubectl get pods -A)"
  else
    fail "unable to list cluster pods"
  fi
fi

echo
echo "State directory: ${STATE_DIR}"
if [[ -d "${STATE_DIR}" ]]; then
  ok "state directory exists"
else
  warn "state directory missing (scripts may not have been run yet on this host)"
fi

if [[ -f "${STATE_DIR}/dynamic.env" ]]; then
  ok "dynamic state file exists (${STATE_DIR}/dynamic.env)"
else
  warn "dynamic state file missing (${STATE_DIR}/dynamic.env)"
fi

declare -a stage_markers=(cert-manager observability longhorn vcluster argocd)
for marker in "${stage_markers[@]}"; do
  if [[ -f "${STATE_DIR}/${marker}.ok" ]]; then
    ok "stage marker present: ${marker}.ok"
  else
    warn "stage marker missing: ${marker}.ok"
  fi
done

kubeconfig_count=0
for kubeconfig in "${STATE_DIR}"/kubeconfig-*.yaml; do
  [[ -e "${kubeconfig}" ]] || continue
  kubeconfig_count=$((kubeconfig_count + 1))
done

if (( kubeconfig_count > 0 )); then
  ok "detected ${kubeconfig_count} vcluster kubeconfig file(s) in state dir"
else
  warn "no vcluster kubeconfig files found in state dir"
fi

echo
echo "== Summary =="
printf 'PASS=%d WARN=%d FAIL=%d\n' "${PASS}" "${WARN}" "${FAIL}"

if (( FAIL > 0 )); then
  exit 1
fi

if (( STRICT_MODE == 1 && WARN > 0 )); then
  echo "Strict mode enabled: warnings are treated as failure" >&2
  exit 1
fi
