#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

# Uso:
#   scan-ips-30.sh                  # default: 192.168.30.200-210
#   scan-ips-30.sh 192.168.30.200-210
#   scan-ips-30.sh 192.168.30.0/24

DEFAULT_RANGE="192.168.30.200-210"
TARGET="${1:-$DEFAULT_RANGE}"

# IPs que NÃO serão considerados (reservas conhecidas)
EXCLUDE_IPS=(
  192.168.30.1     # gateway
  192.168.30.51    # devops-template (conforme /etc/hosts)
  192.168.30.52    # VM1 (control-plane)
  192.168.30.53    # VM2 (worker)
)

# Detecta interface de saída para o primeiro IP do range
first_ip_from_target() {
  if [[ "$TARGET" == */* ]]; then
    echo "192.168.30.1"
  elif [[ "$TARGET" == 192.168.30.*-* ]]; then
    echo "${TARGET%-*}"
  else
    echo "$TARGET"
  fi
}

IFACE="$(ip -o -4 route get "$(first_ip_from_target)" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
IFACE="${IFACE:-enX0}"  # fallback visto nos relatórios

# Preferir arping; fallback para ping
HAVE_ARPING=0
if command -v arping >/dev/null 2>&1; then
  HAVE_ARPING=1
fi

# Gera a lista de IPs a testar
gen_ips() {
  if [[ "$TARGET" == */* ]]; then
    # 192.168.30.0/24 -> 192.168.30.1..254
    base="192.168.30"
    for i in {1..254}; do
      echo "$base.$i"
    done
  elif [[ "$TARGET" == 192.168.30.*-* ]]; then
    # 192.168.30.A-B
    start="${TARGET#192.168.30.}"
    start="${start%-*}"
    end="${TARGET##*-}"
    base="192.168.30"
    for ((i=start; i<=end; i++)); do
      echo "$base.$i"
    done
  else
    # IP único
    echo "$TARGET"
  fi
}

is_excluded() {
  local ip="$1"
  for e in "${EXCLUDE_IPS[@]}"; do
    [[ "$ip" == "$e" ]] && return 0
  done
  return 1
}

check_ip() {
  local ip="$1"
  local status="FREE"
  local note=""
  local mac=""

  if is_excluded "$ip"; then
    echo "$ip,SKIPPED,,${IFACE},excluded"
    return
  fi

  if (( HAVE_ARPING )); then
    if arping -c 2 -w 2 -I "$IFACE" "$ip" >/dev/null 2>&1; then
      status="IN-USE"
      note="arp-reply"
    fi
  else
    if timeout 1 ping -c 1 -W 1 -n "$ip" >/dev/null 2>&1; then
      status="IN-USE"
      note="icmp-echo"
    fi
  fi

  # Tenta obter MAC se houver vizinho conhecido
  mac="$(ip neigh show "$ip" 2>/dev/null | awk '/lladdr/ {print $5; exit}' || true)"
  echo "$ip,$status,${mac:-},${IFACE},${note}"
}

# Concurrency leve
MAX_JOBS=32
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "IP,STATUS,MAC,IFACE,NOTE" | tee "$tmp" >/dev/null

jobs_count=0
while read -r ip; do
  # Pule .0 e .255 por segurança
  last_octet="${ip##*.}"
  if [[ "$last_octet" == "0" || "$last_octet" == "255" ]]; then
    continue
  fi

  check_ip "$ip" >> "$tmp" &
  ((++jobs_count))
  if (( jobs_count % MAX_JOBS == 0 )); then
    wait
  fi
done < <(gen_ips)

wait
# Ordena por IP (alfa funciona bem aqui dado mesmo prefixo)
{ head -n1 "$tmp"; tail -n +2 "$tmp" | sort -t. -k4,4n; }
