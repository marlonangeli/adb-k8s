#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Uso: bin/run-on-nodes.sh <script> [opções] [-- script_args...]

Opções:
  --workers              Executa nos WORKERS (padrão)
  --control-plane        Executa apenas no control-plane
  --all                  Executa no control-plane e nos WORKERS
  --hosts "ip1 ip2"      Lista personalizada de hosts (separados por espaços)
  -h, --help             Mostra esta ajuda

Exemplos:
  bin/run-on-nodes.sh bin/10-so-requirements.sh --workers
  bin/run-on-nodes.sh bin/10-so-requirements.sh --all -- --flag

Observações:
  * O login inicial é realizado como o usuário configurado (padrão: utfpr).
  * Será executado `su -`; forneça a senha de root quando solicitado.
EOF
}

target_hosts=("${WORKERS[@]}")
script_path=""
script_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      target_hosts=("${WORKERS[@]}")
      shift
      ;;
    --control-plane)
      target_hosts=("${CP_IP}")
      shift
      ;;
    --all)
      target_hosts=("${CP_IP}" "${WORKERS[@]}")
      shift
      ;;
    --hosts)
      shift
      [[ $# -gt 0 ]] || { usage; exit 1; }
      read -ra target_hosts <<<"$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      script_args+=("$@")
      break
      ;;
    -*)
      if [[ -z "${script_path}" ]]; then
        echo "opção desconhecida: $1" >&2
        usage
        exit 1
      fi
      script_args+=("$1")
      shift
      ;;
    *)
      if [[ -z "${script_path}" ]]; then
        script_path="$1"
      else
        script_args+=("$1")
      fi
      shift
      ;;
  esac
done

[[ ${#target_hosts[@]} -gt 0 ]] || { echo "nenhum host selecionado"; exit 1; }
[[ -n "${script_path}" ]] || { usage; exit 1; }

for host in "${target_hosts[@]}"; do
  log "executando ${script_path} em ${host}"
  run_remote_script "${host}" "${script_path}" "${script_args[@]}"
done
