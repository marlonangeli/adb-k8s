#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "este script precisa ser executado como root" >&2
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "arquitetura não suportada: ${ARCH}" >&2
    exit 1
    ;;
esac

BIN_DIR="/usr/local/bin"
APT_KEYRING="/etc/apt/keyrings"
K8S_KEYRING="${APT_KEYRING}/kubernetes-apt-keyring.gpg"
K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"

log() {
  echo "[install-clis] $*"
}

ensure_tools() {
  local missing=()
  for tool in curl tar gpg apt-get; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  if ((${#missing[@]})); then
    echo "dependências obrigatórias ausentes: ${missing[*]}" >&2
    exit 1
  fi
}

install_binary() { # url name
  local url="$1"
  local name="$2"
  local dest="${BIN_DIR}/${name}"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "${url}" -o "${tmp}"
  install -m 0755 "${tmp}" "${dest}"
  rm -f "${tmp}"
}

install_tarball_binary() { # url binary_name archive_subpath
  local url="$1"
  local name="$2"
  local subpath="$3"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmp_dir}/archive.tgz"
  tar -C "${tmp_dir}" -xzf "${tmp_dir}/archive.tgz"
  install -m 0755 "${tmp_dir}/${subpath}" "${BIN_DIR}/${name}"
  rm -rf "${tmp_dir}"
}

install_kubernetes_components() {
  if command -v kubeadm >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v kubelet >/dev/null 2>&1; then
    log "kubeadm/kubectl/kubelet já instalados"
    return
  fi

  local stable release major_minor repo_branch
  stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  release="${stable#v}"
  major_minor="$(cut -d. -f1-2 <<<"${release}")"
  repo_branch="core:/stable:/v${major_minor}"

  mkdir -p "${APT_KEYRING}"
  curl -fsSL "https://pkgs.k8s.io/${repo_branch}/deb/Release.key" | gpg --dearmor -o "${K8S_KEYRING}"
  chmod 0644 "${K8S_KEYRING}"
  tee "${K8S_LIST}" >/dev/null <<EOF
deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/${repo_branch}/deb/ /
EOF

  apt-get update
  apt-get install -y kubeadm kubectl kubelet
  apt-mark hold kubeadm kubectl kubelet
  systemctl enable kubelet
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    log "helm já instalado"
    return
  fi
  local version archive_url archive_path
  version="$(curl -fsSL https://get.helm.sh/helm-latest-version)"
  archive_url="https://get.helm.sh/helm-${version}-linux-${ARCH}.tar.gz"
  archive_path="linux-${ARCH}/helm"
  install_tarball_binary "${archive_url}" "helm" "${archive_path}"
}

install_cilium_cli() {
  if command -v cilium >/dev/null 2>&1; then
    log "cilium CLI já instalado"
    return
  fi
  local url="https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-${ARCH}.tar.gz"
  install_tarball_binary "${url}" "cilium" "cilium"
}

install_vcluster() {
  if command -v vcluster >/dev/null 2>&1; then
    log "vcluster já instalado"
    return
  fi
  local url="https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-${ARCH}"
  install_binary "${url}" "vcluster"
}

install_kustomize() {
  if command -v kustomize >/dev/null 2>&1; then
    log "kustomize já instalado"
    return
  fi
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" -o "${tmp_dir}/install.sh"
  chmod +x "${tmp_dir}/install.sh"
  (cd "${tmp_dir}" && ./install.sh >/dev/null)
  if [[ ! -f "${tmp_dir}/kustomize" ]]; then
    echo "falha ao baixar kustomize" >&2
    exit 1
  fi
  install -m 0755 "${tmp_dir}/kustomize" "${BIN_DIR}/kustomize"
  rm -rf "${tmp_dir}"
}

install_argocd() {
  if command -v argocd >/dev/null 2>&1; then
    log "argocd já instalado"
    return
  fi
  local url="https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}"
  install_binary "${url}" "argocd"
}

install_k9s() {
  if command -v k9s >/dev/null 2>&1; then
    log "k9s já instalado"
    return
  fi
  local version url
  version="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')"
  url="https://github.com/derailed/k9s/releases/download/${version}/k9s_Linux_${ARCH}.tar.gz"
  install_tarball_binary "${url}" "k9s" "k9s"
}

main() {
  ensure_tools
  install_kubernetes_components
  install_helm
  install_cilium_cli
  install_vcluster
  install_kustomize
  install_argocd
  if command -v jq >/dev/null 2>&1; then
    install_k9s || true
  else
    log "jq não encontrado; pulando instalação do k9s (requer jq para descobrir a versão mais recente)"
  fi
  log "instalação concluída"
}

main "$@"
