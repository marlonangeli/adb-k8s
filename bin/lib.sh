#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${ROOT_DIR}/env.sh"
SECRETS_FILE="${ROOT_DIR}/secrets.env"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  echo "crie secrets.env a partir de secrets.env.example e preencha as credenciais" >&2
  exit 1
fi
source "${SECRETS_FILE}"

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"

DYNAMIC_ENV="${STATE_DIR}/dynamic.env"
[[ -f "${DYNAMIC_ENV}" ]] && source "${DYNAMIC_ENV}"

log() { echo "[$(date +'%F %T')] $*" | tee -a "${LOG_FILE}"; }
ok() { touch "${STATE_DIR}/$1.ok"; log "ok: $1"; }
donep() { [[ -f "${STATE_DIR}/$1.ok" ]]; }

need_root() {
  [[ $(id -u) -eq 0 ]] || { echo "precisa ser root"; exit 1; }
}

wait_rollout() { # ns kind name
  kubectl -n "$1" rollout status "$2/$3" --timeout=5m
}

require_commands() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    log "comando(s) ausente(s): ${missing[*]}"
    exit 1
  fi
}

tmp_artifacts=()

register_tmp() {
  tmp_artifacts+=("$1")
}

cleanup_tmp() {
  local path
  for path in "${tmp_artifacts[@]}"; do
    [[ -e "$path" ]] && rm -rf "$path"
  done
}

render_template() {
  local template="$1"
  [[ -f "$template" ]] || { log "template não encontrado: ${template}"; return 1; }
  local dir output
  dir=$(mktemp -d)
  register_tmp "$dir"
  output="${dir}/$(basename "$template")"
  envsubst < "${template}" > "${output}"
  echo "${output}"
}

save_state_var() {
  local key="$1"
  local value="$2"
  mkdir -p "${STATE_DIR}"
  local tmp
  tmp=$(mktemp)
  [[ -f "${DYNAMIC_ENV}" ]] && grep -v "^${key}=" "${DYNAMIC_ENV}" >"${tmp}"
  echo "${key}=${value}" >>"${tmp}"
  mv "${tmp}" "${DYNAMIC_ENV}"
  source "${DYNAMIC_ENV}"
}

current_ingress_ip() {
  if [[ -n "${INGRESS_VIP}" ]]; then
    echo "${INGRESS_VIP}"
    return
  fi
  if [[ -n "${ASSIGNED_INGRESS_IP:-}" ]]; then
    echo "${ASSIGNED_INGRESS_IP}"
    return
  fi
  return 1
}

resolve_hostname() {
  local override="$1"
  local prefix="$2"
  if [[ -n "${override}" ]]; then
    echo "${override}"
    return
  fi
  local ip template
  ip=$(current_ingress_ip) || { log "IP do ingress ainda não disponível (prefixo: ${prefix})"; exit 1; }
  template="${INGRESS_HOST_TEMPLATE:-%s.%s.sslip.io}"
  printf "${template}" "${prefix}" "$(sslip_slug "${ip}")"
}

sslip_slug() {
  local raw="$1"
  raw="${raw//./-}"
  raw="${raw//:/-}"
  echo "${raw}"
}

local_sslip_host() {
  local prefix="$1"
  printf "%s.127-0-0-1.sslip.io" "${prefix}"
}

apply_certificate() {
  local namespace="$1"
  local certificate_name="$2"
  local secret_name="$3"
  local ip_address="$4"
  shift 4
  local dns_names=("$@")

  if [[ -z "${TLS_CLUSTER_ISSUER:-}" ]]; then
    echo "defina TLS_CLUSTER_ISSUER em env.sh ou secrets.env" >&2
    exit 1
  fi
  if [[ -z "${namespace}" || -z "${certificate_name}" || -z "${secret_name}" || -z "${ip_address}" ]]; then
    echo "apply_certificate: parâmetros insuficientes" >&2
    exit 1
  fi
  if ((${#dns_names[@]} == 0)); then
    echo "apply_certificate: informe pelo menos um DNS" >&2
    exit 1
  fi

  local manifest
  manifest=$(mktemp)
  register_tmp "${manifest}"
  {
    printf 'apiVersion: cert-manager.io/v1\n'
    printf 'kind: Certificate\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${certificate_name}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'spec:\n'
    printf '  secretName: %s\n' "${secret_name}"
    printf '  issuerRef:\n'
    printf '    kind: ClusterIssuer\n'
    printf '    name: %s\n' "${TLS_CLUSTER_ISSUER}"
    printf '  dnsNames:\n'
    local dns
    for dns in "${dns_names[@]}"; do
      printf '    - %s\n' "${dns}"
    done
    printf '  ipAddresses:\n'
    printf '    - %s\n' "${ip_address}"
  } >"${manifest}"
  kubectl apply -f "${manifest}"
}

wait_for_lb_ip() {
  local namespace="$1"
  local service="$2"
  local timeout="${3:-180}"
  local start current
  start=$(date +%s)
  while true; do
    current=$(kubectl -n "${namespace}" get svc "${service}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${current}" && "${current}" != "pending" ]]; then
      echo "${current}"
      return 0
    fi
    if (( timeout > 0 && $(date +%s) - start >= timeout )); then
      return 1
    fi
    sleep 5
  done
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return
  fi
  require_commands curl tar install
  local version tmp_dir archive
  version=$(curl -s https://get.helm.sh/helm-latest-version)
  tmp_dir=$(mktemp -d)
  register_tmp "${tmp_dir}"
  archive="${tmp_dir}/helm.tar.gz"
  curl -sSL "https://get.helm.sh/helm-${version}-linux-amd64.tar.gz" -o "${archive}"
  tar -C "${tmp_dir}" -xzf "${archive}"
  install -m 0755 "${tmp_dir}/linux-amd64/helm" /usr/local/bin/helm
}

ensure_cilium_cli() {
  if command -v cilium >/dev/null 2>&1; then
    return
  fi
  require_commands curl tar sha256sum install
  local version tmp_dir archive checksum
  version=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  tmp_dir=$(mktemp -d)
  register_tmp "${tmp_dir}"
  archive="${tmp_dir}/cilium-linux-amd64.tar.gz"
  checksum="${archive}.sha256sum"
  curl -sSL "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-amd64.tar.gz" -o "${archive}"
  curl -sSL "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-amd64.tar.gz.sha256sum" -o "${checksum}"
  (cd "${tmp_dir}" && sha256sum --check "$(basename "${checksum}")")
  tar -C "${tmp_dir}" -xzf "${archive}"
  install -m 0755 "${tmp_dir}/cilium" /usr/local/bin/cilium
}

ensure_vcluster_cli() {
  if command -v vcluster >/dev/null 2>&1; then
    return
  fi
  require_commands curl install
  local tmp_dir binary
  tmp_dir=$(mktemp -d)
  register_tmp "${tmp_dir}"
  binary="${tmp_dir}/vcluster"
  curl -sSL "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64" -o "${binary}"
  install -m 0755 "${binary}" /usr/local/bin/vcluster
}

ssh_options() {
  local -a __opts__
  if [[ -n "${REMOTE_SSH_CONTROL_PATH:-}" ]]; then
    local expanded_path="${REMOTE_SSH_CONTROL_PATH/#\~/${HOME}}"
    mkdir -p "$(dirname "${expanded_path}")"
  fi
  read -ra __opts__ <<<"${REMOTE_SSH_OPTIONS:-}"
  printf '%s\n' "${__opts__[@]}"
}

sync_repo_to_host() {
  local host="$1"
  local remote_dir="${2:-${REMOTE_BASE_DIR}}"
  require_commands ssh tar
  local opts
  mapfile -t opts < <(ssh_options)
  ssh "${opts[@]}" "${REMOTE_SSH_USER}@${host}" "rm -rf '${remote_dir}' && mkdir -p '${remote_dir}'"
  tar -C "${ROOT_DIR}" --exclude='.git' -cf - . | ssh "${opts[@]}" "${REMOTE_SSH_USER}@${host}" "tar -C '${remote_dir}' -xf -"
  echo "${remote_dir}"
}

run_remote_script() {
  local host="$1"; shift
  local script="$1"; shift
  local script_local_path script_remote_path
  if [[ "${script}" = /* ]]; then
    script_local_path="${script}"
    if [[ "${script_local_path}" == ${ROOT_DIR}/* ]]; then
      script_remote_path="${script_local_path#${ROOT_DIR}/}"
    else
      log "script precisa estar dentro do repositório (${ROOT_DIR})"
      exit 1
    fi
  else
    script_local_path="${ROOT_DIR}/${script}"
    script_remote_path="${script}"
  fi
  [[ -f "${script_local_path}" ]] || { log "script não encontrado: ${script}"; exit 1; }
  local remote_dir
  remote_dir=$(sync_repo_to_host "${host}")
  local opts
  mapfile -t opts < <(ssh_options)
  local inner_cmd="cd '${remote_dir}' && bash '${script_remote_path}'"
  local arg
  for arg in "$@"; do
    inner_cmd+=" $(printf '%q' "${arg}")"
  done
  local cmd="su - -c $(printf '%q' "${inner_cmd}")"
  ssh "${opts[@]}" -tt "${REMOTE_SSH_USER}@${host}" "${cmd}"
}

trap 'log "ERRO em linha $LINENO"; cleanup_tmp; exit 1' ERR
trap cleanup_tmp EXIT
