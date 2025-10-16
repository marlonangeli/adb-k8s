## Plataforma K8s Bare-Metal

> Ambiente alvo: **Debian 12**, acesso SSH permitido **apenas** para `utfpr`. Conecte via `ssh utfpr@200.134.18.55 -p 22252`, em cada nó execute `su -` e só então rode os scripts como root.

### Visão Geral
- Cluster Kubernetes bare-metal com **Cilium** (kube-proxy-free + Hubble), **MetalLB** (L2), **Ingress-NGINX**, **Rancher** (painel com TLS autoassinado), observabilidade (**kube-prometheus-stack/Grafana**), **Longhorn** e **vcluster** para isolamento multi-tenant.
- Scripts idempotentes, executados como root, guardam estado em `${STATE_DIR}` e registram logs em `${LOG_FILE}`.
- TLS obrigatório apenas para o Rancher; demais endpoints expostos em HTTP via ingress.

### Topologia
- **control-plane** `192.168.30.52` (2 vCPU / 4 GB)
- **worker-1** `192.168.30.53`, **worker-2** `192.168.30.54` (4 vCPU / 4 GB cada)
- CIDRs: Pods `10.10.0.0/16`, Services `10.96.0.0/12`
- MetalLB: pool `192.168.30.100–120`; o VIP do ingress é alocado dinamicamente e salvo em `${STATE_DIR}/dynamic.env`
- Hostnames práticos são gerados com `sslip.io` usando o IP atual do ingress (ex.: `rancher.<IP>.sslip.io`), mas podem ser sobrescritos em `env.sh`

### Segurança e Operação
- Execução sempre como root; sem `sudo`.
- Cilium fornece políticas L3/L4/L7. Ingress roteia por host/header.
- vclusters “tenant” usam CiliumNetworkPolicy com deny-all + allow para DNS e VIP do ingress.

### Layout do Repositório
```
.
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
1. Copie `secrets.env.example` para `secrets.env` e defina as senhas (ex.: Grafana).
2. Ajuste `env.sh` conforme necessário (IPs, ranges, overrides de host, opções de SSH).
3. Garanta acesso SSH como root entre o nó de controle e os demais (chaves ou senha).
4. Opcional: teste conectividade com `bin/run-on-nodes.sh bin/10-so-requirements.sh --hosts "192.168.30.53" -- --help` (será solicitado o password de root via `su -`).

### Fluxo de Provisionamento
1. **Prep SO** – `bin/10-so-requirements.sh` em todas as VMs (entre como `ssh utfpr@IP`, faça `su -` e execute manualmente, ou use `bin/run-on-nodes.sh` para orquestrar com prompts de senha de root).
2. **Control-plane** – `bin/20-kubeadm-init.sh`: kubeadm init sem kube-proxy, gera `~/join-worker.sh`.
3. **Rede** – `bin/30-cilium.sh`: garante Cilium CLI e aplica Cilium v1.18 com Hubble.
4. **LoadBalancer** – `bin/40-metallb.sh`: instala operador + pool L2.
5. **Ingress** – `bin/50-ingress-nginx.sh`: instala via Helm; captura automaticamente o IP atribuído pelo MetalLB (armazenado em `${STATE_DIR}/dynamic.env`).
6. **Workers** – executar `~/join-worker.sh` nos nós 53 e 54 (ex.: `ssh utfpr@192.168.30.53`, `su -`, `~/join-worker.sh`).
7. **Planos superiores** (no control-plane):
   - `bin/60-rancher.sh`: instala Helm chart, gera TLS autoassinado, força uso do secret.
   - `bin/70-observability.sh`: kube-prometheus-stack com ingress Grafana.
   - `bin/80-longhorn.sh`: Helm + ingress HTTP para Longhorn UI.
   - `bin/90-vcluster.sh`: instala CLI, cria tenant/shared, aplica CNP e ingress do Hubble.

Todos os scripts validam dependências, instalam CLIs ausentes (Helm, Cilium, vcluster) e limpam artefatos temporários automaticamente. Use `make <alvo>` para orquestrar se preferir.

### Operação
- Após a inicialização, valide:
  ```bash
  kubectl get nodes -o wide
  cilium status
  kubectl -n metallb-system get ipaddresspools,l2advertisements
  kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
  kubectl get ingress -A
  ```
- Acessos:
  - Carregue os dados dinâmicos: `source ${STATE_DIR}/dynamic.env`
  - Rancher: `https://${RANCHER_HOSTNAME}` (certificado autoassinado)
  - Grafana: `http://${GRAFANA_HOSTNAME}` (credenciais definidas em `secrets.env`)
  - Longhorn: `http://${LONGHORN_HOSTNAME}`
  - Hubble UI: `http://${HUBBLE_HOSTNAME}`
- Personalize hostnames adicionando entradas no `/etc/hosts` se preferir evitar sslip.io.

### Notas Importantes
- TLS mínimo: apenas Rancher. Outros serviços permanecem em HTTP para simplicidade.
- Scripts conferem se já foram executados antes de prosseguir; repetições são seguras e úteis para correção de falhas.
- Após o passo do ingress, o IP dinamicamente alocado e os hosts derivados ficam persistidos em `${STATE_DIR}/dynamic.env`.
- Cuidado com recursos: requests/limits foram dimensionados para VMs de 4 GB RAM.
- Diretório `old/` mantém manifestos legados para referência; não são usados no fluxo atual.
