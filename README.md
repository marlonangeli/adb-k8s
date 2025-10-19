## Plataforma K8s Bare-Metal

> Ambiente alvo: **Debian 12**, acesso SSH permitido **apenas** para `utfpr`. Conecte via `ssh utfpr@200.134.18.55 -p 22252`, em cada nó execute `su -` e só então rode os scripts como root.

### Visão Geral

- Cluster Kubernetes bare-metal com **Cilium** (kube-proxy-free + Hubble), **MetalLB** (L2), **Ingress-NGINX**, automações opcionais de **cert-manager** (TLS desabilitado por padrão), **Rancher**, observabilidade (**kube-prometheus-stack/Grafana**), **Longhorn** e **vcluster** para isolamento multi-tenant.
- Scripts idempotentes, executados como root, guardam estado em `${STATE_DIR}` (padrão em `/var/opt/cluster-state`) e registram logs em `${LOG_FILE}` (padrão em `/var/log/cluster-install.log`).
- TLS pode ser habilitado via cert-manager (aliases `sslip.io` disponíveis), porém o fluxo atual opera totalmente em HTTP para simplificar o acesso dentro da rede da UTFPR.

### Topologia

- **control-plane** `192.168.30.52` (2 vCPU / 4 GB)
- **worker-1** `192.168.30.53`, **worker-2** `192.168.30.54` (4 vCPU / 4 GB cada)
- CIDRs: Pods `10.10.0.0/16`, Services `10.96.0.0/12`
- MetalLB: pool `192.168.30.100–120`; o VIP do ingress é alocado dinamicamente e salvo em `${STATE_DIR}/dynamic.env`
- Hostnames práticos são gerados com `sslip.io` usando o IP atual do ingress no formato slug (ex.: `rancher.192-168-30-100.sslip.io`) e recebem um alias local `<serviço>.127-0-0-1.sslip.io`; ambos podem ser sobrescritos em `env.sh`

### Segurança e Operação

- Execução sempre como root; sem `sudo`.
- Cilium fornece políticas L3/L4/L7. Ingress roteia por host/header.
- vclusters “tenant” usam CiliumNetworkPolicy com deny-all + allow para DNS e VIP do ingress.

### Layout do Repositório

```
.
├─ CHANGELOG            # registro resumido das mudanças
├─ env.sh                # variáveis estáticas (inventário, ranges, overrides de host)
├─ secrets.env.example   # copie para secrets.env e preencha senhas (Grafana etc.)
├─ Makefile              # atalhos (make cilium, make longhorn, …)
├─ bin/                  # scripts idempotentes/orquestração
│   ├─ lib.sh            # logging, estado, helpers (helm/cilium/vcluster, templates, SSH)
│   ├─ run-on-nodes.sh   # sincroniza repositório e executa scripts via SSH
│   ├─ 10-so-requirements.sh
│   ├─ 20-kubeadm-init.sh
│   ├─ 30-cilium.sh
│   ├─ 40-metallb.sh
│   ├─ 50-ingress-nginx.sh
│   ├─ 55-cert-manager.sh
│   ├─ 60-rancher.sh
│   ├─ 70-observability.sh
│   ├─ 80-longhorn.sh
│   └─ 90-vcluster.sh
└─ manifests/            # templates processados com envsubst
    ├─ cilium.values.yaml
    ├─ metallb-pool.yaml
    ├─ ingress-nginx.values.yaml
    ├─ longhorn.ingress.yaml
    ├─ hubble.ingress.yaml
    └─ cnp/
```

> `bin/run-on-nodes.sh` sincroniza o repositório via `ssh utfpr@<host>` e executa `su -` na sequência; tenha a senha de root à mão para cada conexão.

### Preparação

1. (Opcional, recomendado em ambientes novos) Execute `scripts/install-cli-deps.sh` como root para instalar/atualizar automaticamente `kubeadm`, `kubectl`, `kubelet`, Helm, Cilium CLI, vcluster e Argo CD (requer conexão externa e `curl`, `tar`, `gpg`).
2. Copie `secrets.env.example` para `secrets.env` e defina as senhas de Grafana, Rancher, Argo CD (e demais serviços que usar). TLS está desligado (`TLS_ENABLED=0` em `env.sh`); preencha `CERT_MANAGER_ACME_EMAIL` e exporte `TLS_ENABLED=1`/`TLS_CLUSTER_ISSUER` se desejar reativar certificados.
3. Ajuste `env.sh` conforme necessário (IPs, ranges, overrides de host, opções de SSH).
4. Garanta acesso SSH como root entre o nó de controle e os demais (chaves ou senha).
5. Opcional: teste conectividade com `bin/run-on-nodes.sh bin/10-so-requirements.sh --hosts "192.168.30.53" -- --help` (será solicitado o password de root via `su -`).

### Fluxo rápido

1. `bin/10-so-requirements.sh` (pode usar `bin/run-on-nodes.sh ... --all`).
2. `bin/20-kubeadm-init.sh` no control-plane (guarde o `~/join-worker.sh`).
3. `bin/30-cilium.sh` para rede/Hubble.
4. `bin/35-join-workers.sh` ou `make workers`.
5. `bin/40-metallb.sh` → `bin/50-ingress-nginx.sh` (VIP em `${STATE_DIR}/dynamic.env`).
6. `bin/55-cert-manager.sh` apenas se `TLS_ENABLED=1`.
7. `bin/60-rancher.sh`, `bin/70-observability.sh`, `bin/80-longhorn.sh`, `bin/90-vcluster.sh`.

### Verificações rápidas

```bash
kubectl get nodes -o wide
cilium status
kubectl -n metallb-system get ipaddresspools,l2advertisements
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl get ingress -A
kubectl -n monitoring get pods
kubectl -n kube-system get pods -l k8s-app=hubble-ui
kubectl -n kube-system get pods -l k8s-app=hubble-relay
```

### Endpoints úteis

- Rancher: `http://${RANCHER_HOSTNAME}` / `http://${RANCHER_LOCAL_HOSTNAME}`.
- Grafana: `http://${GRAFANA_HOSTNAME}`.
- Longhorn: `http://${LONGHORN_HOSTNAME}`.
- Hubble UI: `http://${HUBBLE_HOSTNAME}`.

Carregue `source ${STATE_DIR}/dynamic.env` para recuperar IPs/hosts. TLS pode ser reativado depois com `TLS_ENABLED=1` e reaplicando os scripts que criam ingressos.

### Notas Importantes

- Para reativar TLS:
  1. Ajuste `TLS_ENABLED=1` em `env.sh` ou `secrets.env`.
  2. Defina `TLS_CLUSTER_ISSUER` (ex.: `selfsigned-cluster-issuer` ou o emissor ACME configurado).
  3. Execute `bin/55-cert-manager.sh` para reinstalar o cert-manager (se necessário) e emitir o `ClusterIssuer`.
  4. Reaplique os estágios que expõem ingressos (`bin/60-rancher.sh`, `bin/70-observability.sh`, `bin/80-longhorn.sh`, `bin/90-vcluster.sh`) para restaurar HTTPS.
  5. Se tiver tuneado `RANCHER_REPLICAS` ou `RANCHER_STARTUP_FAILURE_THRESHOLD` apenas para o modo HTTP, reavalie os valores ao voltar para TLS.
- Caso permaneça sem TLS, use apenas acessos HTTP dentro da rede corporativa; a emissão via cert-manager continua disponível quando desejar.
- Scripts conferem se já foram executados antes de prosseguir; repetições são seguras e úteis para correção de falhas.
- Após o passo do ingress, o IP dinamicamente alocado e os hosts derivados ficam persistidos em `${STATE_DIR}/dynamic.env`.
- Cuidado com recursos: requests/limits foram dimensionados para VMs de 4 GB RAM.
- Diretório `old/` mantém manifestos legados para referência; não são usados no fluxo atual.
