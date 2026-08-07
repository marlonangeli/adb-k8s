#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state/cluster-state}"
EVIDENCE_ROOT="${GITOPS_EVIDENCE_ROOT:-${WORKSPACE_DIR}/evidencias/gitops}"

ABC_KUBECONFIG="${ABC_KUBECONFIG:-${STATE_DIR}/kubeconfig-abc.yaml}"
SHARED_KUBECONFIG="${SHARED_KUBECONFIG:-${STATE_DIR}/kubeconfig-shared.yaml}"

ABC_NAMESPACE="${ABC_NAMESPACE:-app}"
SHARED_NAMESPACE="${SHARED_NAMESPACE:-processing}"
ABC_APPLICATION="${ABC_APPLICATION:-tenant-abc-adb-api}"
SHARED_APPLICATION="${SHARED_APPLICATION:-shared-interpolation}"

PHASE="snapshot"
SCENARIO="gitops-pipeline"
OUTPUT_DIR=""
SCOPE="all"
SMOKE_URL=""
IMAGE_REF=""

usage() {
  cat <<'EOF'
Capture GitOps evidence for the TCC Argo CD/vCluster pipeline.

Usage:
  scripts/capture-gitops-evidence.sh [options]

Options:
  --phase <name>       Evidence phase prefix, e.g. 01-baseline, 02-outofsync.
  --scenario <name>    Scenario slug used when creating a new output directory.
  --output-dir <dir>   Existing/new run directory. Reuse it across phases.
  --scope <scope>      all, abc, or shared. Default: all.
  --smoke-url <url>    Optional URL to capture with curl/http, e.g. /input/hi.
  --image <ref>        Optional Docker image ref to inspect if available locally.
  -h, --help           Show this help.

Examples:
  scripts/capture-gitops-evidence.sh \
    --phase 01-baseline \
    --scenario tenant-abc-app-version

  scripts/capture-gitops-evidence.sh \
    --output-dir ../evidencias/gitops/20260515T143500Z-tenant-abc-app-version \
    --phase 05-smoke-after \
    --scope abc \
    --smoke-url http://127.0.0.1:3001/input/hi

Notes:
  - Argo CD is captured from the current host-cluster kubeconfig.
  - vCluster workloads are captured with explicit --kubeconfig files.
  - Secrets are not read; only Secret references and non-secret workload state are captured.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="$2"
      shift 2
      ;;
    --scenario)
      SCENARIO="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --scope)
      SCOPE="$2"
      shift 2
      ;;
    --smoke-url)
      SMOKE_URL="$2"
      shift 2
      ;;
    --image)
      IMAGE_REF="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${command_name}" >&2
    exit 1
  fi
}

require_file() {
  local file_path="$1"

  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: required file not found: ${file_path}" >&2
    exit 1
  fi
}

safe_slug() {
  local raw_value="$1"

  raw_value="${raw_value// /-}"
  raw_value="${raw_value//\//-}"
  printf '%s' "${raw_value}"
}

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

run_and_capture() {
  local output_file="$1"
  shift

  {
    printf 'timestamp: %s\n' "$(timestamp_utc)"
    printf 'command: '
    printf '%q ' "$@"
    printf '\n\n'
    "$@"
  } >"${output_file}" 2>&1 || {
    local status=$?
    printf '\n[command exited with status %s]\n' "${status}" >>"${output_file}"
    return 0
  }
}

write_text_file() {
  local output_file="$1"
  local message="$2"

  {
    printf 'timestamp: %s\n\n' "$(timestamp_utc)"
    printf '%s\n' "${message}"
  } >"${output_file}"
}

capture_argocd_application() {
  local app_name="$1"
  local label="$2"

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-argocd-summary.txt" \
    mise exec -- kubectl -n argocd get application "${app_name}" \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,OPERATION:.status.operationState.phase,FINISHED:.status.operationState.finishedAt

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-argocd-wide.txt" \
    mise exec -- kubectl -n argocd get application "${app_name}" -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-argocd-describe.txt" \
    mise exec -- kubectl -n argocd describe application "${app_name}"

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-argocd-json.txt" \
    mise exec -- kubectl -n argocd get application "${app_name}" -o json
}

capture_host_state() {
  run_and_capture "${OUTPUT_DIR}/${PHASE}-host-argocd-applications.txt" \
    mise exec -- kubectl -n argocd get applications -A -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-host-nodes.txt" \
    mise exec -- kubectl get nodes -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-host-top-nodes.txt" \
    mise exec -- kubectl top nodes
}

capture_vcluster_workload() {
  local cluster="$1"
  local kubeconfig="$2"
  local namespace="$3"
  local workload="$4"
  local app_label="$5"
  local configmap_name="$6"

  require_file "${kubeconfig}"

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-get-all.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get all -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-deployment-summary.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get deployment "${workload}" \
      -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[*].image

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-deployment-images.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get deployment "${workload}" \
      -o 'jsonpath={range .spec.template.spec.initContainers[*]}init:{.name}={.image}{"\n"}{end}{range .spec.template.spec.containers[*]}container:{.name}={.image}{"\n"}{end}'

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-deployment-yaml.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get deployment "${workload}" -o yaml

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-deployment-describe.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      describe deployment "${workload}"

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-rollout-status.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      rollout status "deployment/${workload}" --timeout=10s

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-replicasets.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get rs -l "app=${app_label}" -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-pods.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get pods -l "app=${app_label}" -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-hpa.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get hpa "${workload}" -o wide

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-hpa-yaml.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get hpa "${workload}" -o yaml

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-hpa-describe.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      describe hpa "${workload}"

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-top-pods.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      top pods

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-events.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get events --sort-by=.lastTimestamp

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${cluster}-${configmap_name}.txt" \
    mise exec -- kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" \
      get configmap "${configmap_name}" -o yaml
}

capture_smoke_request() {
  if [[ -z "${SMOKE_URL}" ]]; then
    return
  fi

  if command -v curl >/dev/null 2>&1; then
    run_and_capture "${OUTPUT_DIR}/${PHASE}-smoke-request.txt" \
      curl -i --max-time 20 "${SMOKE_URL}"
    return
  fi

  if command -v http >/dev/null 2>&1; then
    run_and_capture "${OUTPUT_DIR}/${PHASE}-smoke-request.txt" \
      http GET "${SMOKE_URL}"
    return
  fi

  write_text_file "${OUTPUT_DIR}/${PHASE}-smoke-request.txt" \
    "Skipped smoke request; neither curl nor http command is available. URL: ${SMOKE_URL}"
}

capture_docker_image() {
  if [[ -z "${IMAGE_REF}" ]]; then
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    write_text_file "${OUTPUT_DIR}/${PHASE}-docker-image-inspect.txt" \
      "Skipped docker inspect; docker command is not available. Image: ${IMAGE_REF}"
    return
  fi

  run_and_capture "${OUTPUT_DIR}/${PHASE}-docker-image-inspect.txt" \
    docker image inspect "${IMAGE_REF}"
}

capture_git_repo() {
  local repo_dir="$1"
  local label="$2"
  shift 2
  local -a diff_paths=("$@")

  if ! git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    write_text_file "${OUTPUT_DIR}/${PHASE}-${label}-git.txt" \
      "Skipped Git capture; not a Git repository: ${repo_dir}"
    return
  fi

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-git-head.txt" \
    git -C "${repo_dir}" log -1 --stat

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-git-revision.txt" \
    git -C "${repo_dir}" rev-parse HEAD

  run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-git-status.txt" \
    git -C "${repo_dir}" status --short

  if ((${#diff_paths[@]} > 0)); then
    run_and_capture "${OUTPUT_DIR}/${PHASE}-${label}-git-diff.txt" \
      git -C "${repo_dir}" diff -- "${diff_paths[@]}"
  fi
}

write_run_readme() {
  cat >"${OUTPUT_DIR}/README.md" <<EOF
# GitOps Evidence Run

- Scenario: ${SCENARIO}
- Last captured phase: ${PHASE}
- Captured at: $(timestamp_utc)
- Scope: ${SCOPE}
- Argo CD applications: ${ABC_APPLICATION}, ${SHARED_APPLICATION}
- abc kubeconfig: ${ABC_KUBECONFIG}
- shared kubeconfig: ${SHARED_KUBECONFIG}
- Smoke URL: ${SMOKE_URL:-not captured}
- Image inspect target: ${IMAGE_REF:-not captured}

## How to use this folder

Compare files with the same suffix across phases, for example:

- 01-baseline-abc-deployment-summary.txt vs. 04-synced-healthy-abc-deployment-summary.txt
- 01-baseline-shared-hpa.txt vs. 04-synced-healthy-shared-hpa.txt
- 02-after-push-tenant-abc-argocd-summary.txt to show OutOfSync
- 04-synced-healthy-tenant-abc-argocd-summary.txt to show Synced / Healthy

Useful evidence for the TCC text/presentation:

1. Git revision and diff files prove the desired state changed in Git.
2. Argo CD summary/describe files prove reconciliation from Git to cluster.
3. Deployment/ReplicaSet/Pod files prove Kubernetes rollout behavior.
4. HPA files prove min/max/current replica configuration.
5. Smoke request proves the application responded after the rollout.
EOF
}

main() {
  require_command mise
  require_command git

  case "${SCOPE}" in
    all|abc|shared)
      ;;
    *)
      echo "ERROR: invalid scope: ${SCOPE}" >&2
      usage >&2
      exit 1
      ;;
  esac

  PHASE="$(safe_slug "${PHASE}")"
  SCENARIO="$(safe_slug "${SCENARIO}")"

  if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-${SCENARIO}"
  fi

  mkdir -p "${OUTPUT_DIR}"

  write_text_file "${OUTPUT_DIR}/${PHASE}-capture-metadata.txt" "$(cat <<EOF
Scenario: ${SCENARIO}
Phase: ${PHASE}
Scope: ${SCOPE}
Workspace: ${WORKSPACE_DIR}
Argo CD applications: ${ABC_APPLICATION}, ${SHARED_APPLICATION}
abc kubeconfig: ${ABC_KUBECONFIG}
shared kubeconfig: ${SHARED_KUBECONFIG}
abc namespace/workload: ${ABC_NAMESPACE}/adb-api
shared namespace/workload: ${SHARED_NAMESPACE}/adb-interpolation-api
Smoke URL: ${SMOKE_URL:-not captured}
Image inspect target: ${IMAGE_REF:-not captured}
EOF
)"

  capture_host_state

  if [[ "${SCOPE}" == "all" || "${SCOPE}" == "abc" ]]; then
    capture_argocd_application "${ABC_APPLICATION}" "tenant-abc"
    capture_vcluster_workload abc "${ABC_KUBECONFIG}" "${ABC_NAMESPACE}" adb-api adb-api app-settings
  fi

  if [[ "${SCOPE}" == "all" || "${SCOPE}" == "shared" ]]; then
    capture_argocd_application "${SHARED_APPLICATION}" "shared-interpolation"
    capture_vcluster_workload shared "${SHARED_KUBECONFIG}" "${SHARED_NAMESPACE}" adb-interpolation-api adb-interpolation-api interpolation-settings
  fi

  capture_git_repo "${WORKSPACE_DIR}/adb-api-3" adb-api \
    src/main/java/br/edu/utfpr/adb/api/controller/GenericController.java \
    k8s/tenants/abc/app.env \
    k8s/tenants/abc/kustomization.yaml \
    k8s/tenants/abc/deployment-image-patch.yaml

  capture_git_repo "${WORKSPACE_DIR}/adb-interpolation-api" adb-interpolation-api \
    k8s/overlays/shared/kustomization.yaml \
    k8s/overlays/shared/deployment-replicas-patch.yaml \
    k8s/overlays/shared/hpa-replicas-patch.yaml \
    k8s/base/deployment.yaml \
    k8s/base/hpa.yaml

  capture_docker_image
  capture_smoke_request
  write_run_readme

  printf 'GitOps evidence written to: %s\n' "${OUTPUT_DIR}"
}

main "$@"
