# Plataforma K8s Bare-Metal (Cilium + MetalLB + Ingress + Rancher + Longhorn + vcluster)

> Ambiente alvo: **Debian 12**, usuário **root**, IPs `192.168.30.52–54`. Acesso remoto inicial via `ssh utfpr@200.134.18.55 -p 22252` e `su -` para root (ou login direto se root habilitado).

## 1) Visão Geral

- **Objetivo:** cluster Kubernetes bare-metal estável para TCC, com rede eBPF (**Cilium** kube-proxy-free), serviço L2 (**MetalLB**), Ingress-NGINX, **Rancher** como painel (substitui dashboard vanilla), observabilidade (Prometheus/Grafana), **Longhorn** como storage distribuído e **vcluster** para multi-tenant isolado (vclusters privados + 1 “shared” para API de interpolação).
- **Por que essas escolhas**
  - **Cilium (sem kube-proxy):** menos iptables/NAT, menor latência; políticas L3/L4/L7; **Hubble** pra visibilidade.
  - **MetalLB (L2):** entrega `type: LoadBalancer` em rede local.
  - **Ingress-NGINX:** roteamento por **host** e por **header** (ex.: `X-Tenant: public`).
  - **Rancher:** gestão central (users, clusters, apps); **exige TLS** → usamos **autoassinado** só nele.
  - **Longhorn:** volumes replicados via iSCSI.
  - **vcluster:** cada tenant com control-plane virtual isolado; workloads rodam como pods no host cluster.

## 2) Topologia/Capacidade

- **VMs** (rede 192.168.30.0/24)
  - **control-plane**: `192.168.30.52` — **2 vCPU, 4 GB RAM**
  - **worker-1**: `192.168.30.53` — **4 vCPU, 4 GB RAM**
  - **worker-2**: `192.168.30.54` — **4 vCPU, 4 GB RAM**
- **CIDRs**
  - **Pods:** `10.10.0.0/16`
  - **Services:** `10.96.0.0/12`
- **MetalLB (L2):** `192.168.30.100–192.168.30.120`
  - **VIP padrão do Ingress:** `192.168.30.101`
- **Hostnames práticos (sem domínio):** usar **sslip.io** (resolve por IP), ex. `rancher.192.168.30.101.sslip.io`.
  - Alternativa: adicionar entradas em `/etc/hosts` na sua máquina.

## 3) Segurança/Operação

- Execução **como root** (sem `sudo`).
- **Scripts idempotentes**: cada etapa grava um *marker* em `/var/opt/cluster-state/*.ok`.
- **Sem TLS global**: **apenas o Rancher** exigirá TLS (autoassinado via `openssl`, **sem cert-manager**).
- Portas típicas: `6443/tcp` (API), `10250/tcp` (kubelet), `8472/udp` (VXLAN Cilium), `80/443/tcp` (Ingress).

## 4) Padrões de Roteamento & Multi-Tenant

- **Ingress** (NGINX) recebe no VIP `192.168.30.101`.
- **vcluster**:
  - **privados:** A e B (por ex.) — **não** podem falar entre si.
  - **shared:** “vcluster-shared” (API de interpolação).
  - Isolamento com **CiliumNetworkPolicy**: `deny-all egress` + `allow DNS + 80/443 → 192.168.30.101`.

---

## Layout do Repositório

```
lab-k8s/
├─ README.md                      # este arquivo
├─ env.sh                         # variáveis de ambiente do cluster
├─ Makefile                       # orquestra passos com idempotência
├─ bin/
│  ├─ lib.sh                      # helpers (estado, logs, waits)
│  ├─ 10-so-requirements.sh       # prepara SO + containerd + kube tools
│  ├─ 20-kubeadm-init.sh          # init control-plane (kubeadm)
│  ├─ 30-cilium.sh                # Cilium + Hubble
│  ├─ 40-metallb.sh               # MetalLB (pool L2)
│  ├─ 50-ingress-nginx.sh         # ingress controller (sem TLS global)
│  ├─ 60-rancher.sh               # Rancher (gera TLS autoassinado)
│  ├─ 70-observability.sh         # kube-prometheus-stack + Grafana
│  ├─ 80-longhorn.sh              # Longhorn + Ingress HTTP
│  └─ 90-vcluster.sh              # template p/ tenants + isolamento Cilium
└─ manifests/
   ├─ metallb-pool.yaml
   ├─ ingress-nginx.values.yaml
   ├─ cilium.values.yaml          # (opcional) se preferir helm em vez do CLI
   ├─ longhorn.ingress.yaml
   ├─ hubble.ingress.yaml         # (HTTP)
   └─ cnp/                        # policies Cilium (deny-all, allow-dns+ingress)
```

---

## Como usar

```bash
# 0) clone e configure env
git clone <seu-repo> lab-k8s && cd lab-k8s
sed -n '1,200p' env.sh     # revise variáveis se quiser

# 1) em CADA nó (52, 53, 54): preparar SO
/bin/bash bin/10-so-requirements.sh

# 2) no control-plane (52): inicializa cluster + Cilium + MetalLB + Ingress
/bin/bash bin/20-kubeadm-init.sh
/bin/bash bin/30-cilium.sh
/bin/bash bin/40-metallb.sh
/bin/bash bin/50-ingress-nginx.sh

# 3) em cada worker (53 e 54): executar o comando de join que foi gerado
cat ~/join-worker.sh   # pegue do control-plane e rode nos workers

# 4) no control-plane: Rancher (TLS autoassinado), observabilidade, longhorn, vclusters
/bin/bash bin/60-rancher.sh
/bin/bash bin/70-observability.sh
/bin/bash bin/80-longhorn.sh
/bin/bash bin/90-vcluster.sh
```

> você também pode usar `make`: `make init-cp`, `make cilium`, `make metallb`, etc.

---

## Arquivos principais

### `env.sh`

```bash
# Cluster IP plan
export CP_IP="192.168.30.52"
export WORKERS=("192.168.30.53" "192.168.30.54")

# Networking
export POD_CIDR="10.10.0.0/16"
export SVC_CIDR="10.96.0.0/12"

# MetalLB
export LB_POOL_START="192.168.30.100"
export LB_POOL_END="192.168.30.120"
export INGRESS_VIP="192.168.30.101"

# Hostnames úteis (sem domínio)
export RANCHER_HOST="rancher.${INGRESS_VIP}.sslip.io"
export GRAFANA_HOST="grafana.${INGRESS_VIP}.sslip.io"
export LONGHORN_HOST="longhorn.${INGRESS_VIP}.sslip.io"
export HUBBLE_HOST="hubble.${INGRESS_VIP}.sslip.io"

# Estado / logs
export STATE_DIR="/var/opt/cluster-state"
export LOG_FILE="/var/log/cluster-install.log"
```

### `bin/lib.sh`

```bash
#!/bin/bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/env.sh"

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "${LOG_FILE}"; }
ok(){  touch "${STATE_DIR}/$1.ok"; log "ok: $1"; }
donep(){ [[ -f "${STATE_DIR}/$1.ok" ]]; }

need_root(){
  [[ $(id -u) -eq 0 ]] || { echo "precisa ser root"; exit 1; }
}

wait_rollout(){ # ns kind name
  kubectl -n "$1" rollout status "$2/$3" --timeout=5m
}

trap 'log "ERRO em linha $LINENO"; exit 1' ERR
```

### `bin/10-so-requirements.sh`

```bash
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"; need_root

STEP="so-reqs"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

apt update && apt -y upgrade
apt -y install ca-certificates curl gnupg lsb-release jq \
               kmod procps iptables arptables ebtables ethtool \
               conntrack iproute2 open-iscsi nfs-common
systemctl enable --now iscsid

swapoff -a
sed -ri 's/^\s*([^#]\S+\s+\S+\s+swap\s+\S+.*)$/#\1/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<'EOF'
br_netfilter
EOF
cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 10485760
EOF
modprobe br_netfilter
sysctl --system

apt -y install containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/^(\s*)SystemdCgroup\s*=\s*false/\1SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

# kube tools 1.34
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt update && apt -y install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# kubelet ulimits
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/20-ulimits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload

ok "${STEP}"
```

### `bin/20-kubeadm-init.sh`

```bash
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"; need_root

STEP="kubeadm-init"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

kubeadm config images pull
kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --skip-phases=addon/kube-proxy

mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"

kubeadm token create --print-join-command | tee ~/join-worker.sh
chmod +x ~/join-worker.sh

log "execute ~/join-worker.sh nos workers: ${WORKERS[*]}"
ok "${STEP}"
```

### `bin/30-cilium.sh`

```bash
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="cilium"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"{,.sha256sum}
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
tar -C /usr/local/bin -xzvf cilium-linux-amd64.tar.gz
rm -f cilium-linux-amd64.tar.gz*

cilium install \
  --version v1.18.0 \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost="${CP_IP}" --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set cluster.name=lab-cluster \
  --set cluster.id=1 \
  --set l7Proxy=true \
  --set bpf.masquerade=true \
  --set tunnel=vxlan \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns;drop;tcp;flow;port-distribution;icmp;http}"

cilium status --wait
ok "${STEP}"
```

### `manifests/metallb-pool.yaml` + `bin/40-metallb.sh`

```yaml
# manifests/metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool-bridge
  namespace: metallb-system
spec:
  addresses:
    - ${LB_POOL_START}-${LB_POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
spec:
  ipAddressPools: [ "pool-bridge" ]
```

```bash
# bin/40-metallb.sh
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="metallb"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
wait_rollout metallb-system deploy controller

# renderiza com envsubst
render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/metallb-pool.yaml" > "${render_dir}/metallb-pool.yaml"
kubectl apply -f "${render_dir}/metallb-pool.yaml"

ok "${STEP}"
```

### `manifests/ingress-nginx.values.yaml` + `bin/50-ingress-nginx.sh`

```yaml
# manifests/ingress-nginx.values.yaml
controller:
  replicaCount: 2
  publishService: { enabled: true }
  service:
    type: LoadBalancer
    loadBalancerIP: ${INGRESS_VIP}
    annotations:
      metallb.universe.tf/address-pool: pool-bridge
    externalTrafficPolicy: Local
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }
  livenessProbe: { initialDelaySeconds: 10, timeoutSeconds: 10, failureThreshold: 5 }
  readinessProbe:{ initialDelaySeconds: 10, timeoutSeconds: 10, failureThreshold: 5 }
```

```bash
# bin/50-ingress-nginx.sh
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="ingress-nginx"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

curl -sL "https://get.helm.sh/helm-$(curl -s https://get.helm.sh/helm-latest-version)-linux-amd64.tar.gz" \
  | tar -xz && install -m 0755 linux-amd64/helm /usr/local/bin/helm && rm -rf linux-amd64

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
kubectl create ns ingress-nginx || true

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/ingress-nginx.values.yaml" > "${render_dir}/ingress-nginx.values.yaml"
helm upgrade -i ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx \
  -f "${render_dir}/ingress-nginx.values.yaml"

ok "${STEP}"
```

### `bin/60-rancher.sh` (TLS autoassinado)

```bash
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="rancher"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create ns cattle-system || true

# cria secret TLS autoassinado (sem cert-manager)
TLS_KEY=$(mktemp)
TLS_CRT=$(mktemp)
if ! kubectl -n cattle-system get secret rancher-tls >/dev/null 2>&1; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
    -subj "/CN=${RANCHER_HOST}" \
    -addext "subjectAltName=DNS:${RANCHER_HOST},IP:${INGRESS_VIP}"
  kubectl -n cattle-system create secret tls rancher-tls \
    --key "${TLS_KEY}" --cert "${TLS_CRT}"
fi

helm upgrade -i rancher rancher-latest/rancher -n cattle-system \
  --set hostname="${RANCHER_HOST}" \
  --set ingress.tls.source=secret \
  --set privateCA=true

# garante que o Ingress do chart use nosso secret
kubectl -n cattle-system patch ingress rancher -p '{"spec":{"tls":[{"hosts":["'"${RANCHER_HOST}"'"],"secretName":"rancher-tls"}]}}'

ok "${STEP}"
```

### `bin/70-observability.sh`

```bash
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="observability"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create ns monitoring || true

helm upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring \
  --set grafana.adminPassword='admin' \
  --set grafana.ingress.enabled=true \
  --set grafana.ingress.ingressClassName=nginx \
  --set grafana.ingress.hosts="[\"${GRAFANA_HOST}\"]"

ok "${STEP}"
```

### `manifests/longhorn.ingress.yaml` + `bin/80-longhorn.sh`

```yaml
# manifests/longhorn.ingress.yaml (HTTP simples)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  ingressClassName: nginx
  rules:
    - host: ${LONGHORN_HOST}
      http:
        paths:
        - path: /
          pathType: Prefix
          backend:
            service: { name: longhorn-frontend, port: { number: 80 } }
```

```bash
# bin/80-longhorn.sh
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="longhorn"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

helm repo add longhorn https://charts.longhorn.io
helm repo update
kubectl create ns longhorn-system || true

helm upgrade -i longhorn longhorn/longhorn -n longhorn-system \
  --set defaultSettings.defaultReplicaCount=2

render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/longhorn.ingress.yaml" > "${render_dir}/longhorn.ingress.yaml"
kubectl apply -f "${render_dir}/longhorn.ingress.yaml"

ok "${STEP}"
```

### `manifests/hubble.ingress.yaml` + `bin/90-vcluster.sh`

```yaml
# manifests/hubble.ingress.yaml (HTTP)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hubble-ui
  namespace: kube-system
spec:
  ingressClassName: nginx
  rules:
  - host: ${HUBBLE_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: hubble-ui, port: { number: 80 } }
```

```bash
# bin/90-vcluster.sh
#!/bin/bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

STEP="vcluster"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

# CLI
if ! command -v vcluster >/dev/null 2>&1; then
  curl -L -o /usr/local/bin/vcluster \
    "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
  chmod +x /usr/local/bin/vcluster
fi

# example: tenant-a + shared
for NS in vcluster-tenant-a vcluster-shared; do
  kubectl create ns "${NS}" || true
done

cat >/tmp/vc.values.yaml <<'EOF'
controlPlane: { distro: k8s }
syncer:
  targetNamespace: REPLACE_NS
api: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
controllerManager: { resources: { requests: { cpu: 100m, memory: 128Mi } } }
scheduler: { resources: { requests: { cpu: 50m,  memory: 64Mi } } }
EOF

# cria tenant-a
sed "s/REPLACE_NS/vcluster-tenant-a/" /tmp/vc.values.yaml >/tmp/vc-a.yaml
vcluster create tenant-a -n vcluster-tenant-a --connect=false --expose -f /tmp/vc-a.yaml
vcluster connect tenant-a -n vcluster-tenant-a --update-current=false --print > /root/kubeconfig-tenant-a.yaml

# cria shared
sed "s/REPLACE_NS/vcluster-shared/" /tmp/vc.values.yaml >/tmp/vc-sh.yaml
vcluster create shared -n vcluster-shared --connect=false --expose -f /tmp/vc-sh.yaml

# isolamento Cilium para tenant-a (deny all + allow DNS + allow ingress VIP)
kubectl apply -n vcluster-tenant-a -f - <<EOF
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata: { name: egress-deny-all }
spec:
  endpointSelector: {}
  egressDeny:
  - toEntities: [ "all" ]
---
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata: { name: egress-allow-dns-and-ingress }
spec:
  endpointSelector: {}
  egress:
  - toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": "kube-system"
        "k8s:k8s-app": "kube-dns"
    toPorts:
    - ports: [{ port: "53", protocol: ANY }]
      rules: { dns: [ { matchPattern: "*" } ] }
  - toCIDRSet: [ { cidr: "${INGRESS_VIP}/32" } ]
    toPorts:
    - ports: [ { port: "80", protocol: TCP }, { port: "443", protocol: TCP } ]
EOF

# Hubble Ingress (HTTP)
render_dir=$(mktemp -d)
envsubst < "${ROOT_DIR}/manifests/hubble.ingress.yaml" > "${render_dir}/hubble.ingress.yaml"
kubectl apply -f "${render_dir}/hubble.ingress.yaml"

ok "${STEP}"
```

### `Makefile`

```makefile
SHELL := /bin/bash
all: init-cp cilium metallb ingress rancher observability longhorn vcluster

init-cp: ; bin/20-kubeadm-init.sh
cilium: ;   bin/30-cilium.sh
metallb: ;  bin/40-metallb.sh
ingress: ;  bin/50-ingress-nginx.sh
rancher: ;  bin/60-rancher.sh
observability: ; bin/70-observability.sh
longhorn: ; bin/80-longhorn.sh
vcluster: ; bin/90-vcluster.sh
```

---

## Operação e Runbook

- **Join dos workers**: execute o comando que ficou em `~/join-worker.sh` nos nós `192.168.30.53` e `192.168.30.54`.
- **Verificações rápidas**

  ```bash
  kubectl get nodes -o wide
  cilium status
  kubectl -n metallb-system get ipaddresspools,l2advertisements
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
  kubectl get ingress -A
  ```

- **Acessos (sem TLS global)**
  - Rancher: <https://rancher.${INGRESS_VIP}.sslip.io>  (autoassinado; aceite o certificado)
  - Grafana: <http://grafana.${INGRESS_VIP}.sslip.io>  (admin/admin)
  - Longhorn: <http://longhorn.${INGRESS_VIP}.sslip.io>
  - Hubble UI: <http://hubble.${INGRESS_VIP}.sslip.io>

> se preferir, substitua `*.sslip.io` por hostnames locais via `/etc/hosts`.

---

## Notas de Projeto

- **TLS mínimo viável:** só para o **Rancher**, porque o chart exige HTTPS; autoassinado via `openssl`, sem `cert-manager`.
- **Estado dos instaladores:** cada etapa é **idempotente** e usa *markers* em `${STATE_DIR}`; reentrante/seguro.
- **kube-proxy-free:** melhora latência e simplifica iptables; se um dia precisar depurar SNAT/DNAT, use `hubble` e `cilium monitor`.
- **Isolamento entre vclusters:** feito **na borda (Ingress)** + **CNP de egress** para evitar tráfego lateral.
- **Recursos (mem/RAM):** mantenha `requests` modestos nos charts (Ingress/Cilium/Longhorn) para caber nos workers de 4 GB.

---

curtiu esse formato? se quiser, eu junto tudo em um `.tar.gz` (com a estrutura acima) já pronto pra `git init && git add . && git commit`.
