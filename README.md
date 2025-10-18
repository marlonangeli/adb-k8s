## Plataforma K8s Bare-Metal

> Ambiente alvo: **Debian 12**, acesso SSH permitido **apenas** para `utfpr`. Conecte via `ssh utfpr@200.134.18.55 -p 22252`, em cada nó execute `su -` e só então rode os scripts como root.

### Visão Geral

- Cluster Kubernetes bare-metal com **Cilium** (kube-proxy-free + Hubble), **MetalLB** (L2), **Ingress-NGINX**, **cert-manager** para TLS automatizado, **Rancher**, observabilidade (**kube-prometheus-stack/Grafana**), **Longhorn** e **vcluster** para isolamento multi-tenant.
- Scripts idempotentes, executados como root, guardam estado em `${STATE_DIR}` (padrão em `/var/opt/cluster-state`) e registram logs em `${LOG_FILE}` (padrão em `/var/log/cluster-install.log`).
- Certificados TLS são emitidos pelo cert-manager para Rancher, Grafana, Longhorn e Hubble, com suporte a aliases `sslip.io` locais para tunelamento.

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

1. Copie `secrets.env.example` para `secrets.env` e defina as senhas de Grafana, Rancher, Argo CD (e demais serviços que usar).
2. Ajuste `env.sh` conforme necessário (IPs, ranges, overrides de host, opções de SSH).
3. Garanta acesso SSH como root entre o nó de controle e os demais (chaves ou senha).
4. Opcional: teste conectividade com `bin/run-on-nodes.sh bin/10-so-requirements.sh --hosts "192.168.30.53" -- --help` (será solicitado o password de root via `su -`).

### Fluxo de Provisionamento

1. **Prep SO** – `bin/10-so-requirements.sh` em todas as VMs (entre como `ssh utfpr@IP`, faça `su -` e execute manualmente, ou use `bin/run-on-nodes.sh` para orquestrar com prompts de senha de root). Pode ser utilizado com `bin/run-on-nodes.sh`:
   ```bash
   bin/run-on-nodes.sh bin/10-so-requirements.sh --all
   ```
2. **Control-plane** – `bin/20-kubeadm-init.sh`: kubeadm init sem kube-proxy, gera `~/join-worker.sh`.
3. **Rede** – `bin/30-cilium.sh`: garante Cilium CLI e aplica Cilium v1.18 com Hubble.
4. **Workers** – `bin/35-join-workers.sh`: utiliza o `~/join-worker.sh` gerado no passo anterior, sincroniza o repositório nos hosts de `WORKERS`, verifica se já fazem parte do cluster e executa `kubeadm join` apenas onde necessário. Disponível via `make workers` ou incluso em `make all`.
   - Execuções manuais continuam possíveis (`ssh utfpr@IP`, `su -`, `~/join-worker.sh`) ou com `bin/run-on-nodes.sh`, mas o estágio agora garante idempotência e evita reprocessar nós já integrados.
5. **LoadBalancer** – `bin/40-metallb.sh`: instala operador + pool L2.
6. **Ingress** – `bin/50-ingress-nginx.sh`: instala via Helm; captura automaticamente o IP atribuído pelo MetalLB (armazenado em `${STATE_DIR}/dynamic.env`).
7. **Cert-manager** – `bin/55-cert-manager.sh`: instala o chart oficial, cria CA interna e registra o emissor `${TLS_CLUSTER_ISSUER}`.
8. **Planos superiores** (no control-plane):
   - `bin/60-rancher.sh`: instala Helm chart, emite certificado via cert-manager e adiciona host local `rancher.127-0-0-1.sslip.io`.
     Clusters Kubernetes >= 1.34 recebem automaticamente `--kube-version 1.33.9`; ajuste via `RANCHER_HELM_KUBE_VERSION_OVERRIDE` se utilizar chart compatível mais recente.
   - `bin/70-observability.sh`: kube-prometheus-stack com ingress Grafana em HTTPS + alias local para túnel.
   - `bin/80-longhorn.sh`: Helm + ingress HTTPS do Longhorn emitido pelo cert-manager.
   - `bin/90-vcluster.sh`: instala CLI, cria tenant/shared, aplica CNP e ingress HTTPS do Hubble com host local.

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
  - Rancher: `https://${RANCHER_HOSTNAME}` (ou `https://${RANCHER_LOCAL_HOSTNAME}` via túnel); login inicial controlado por `RANCHER_ADMIN_PASSWORD`.
  - Grafana: `https://${GRAFANA_HOSTNAME}` (ou `https://${GRAFANA_LOCAL_HOSTNAME}`); credenciais em `secrets.env`.
  - Longhorn: `https://${LONGHORN_HOSTNAME}` (ou `https://${LONGHORN_LOCAL_HOSTNAME}`).
  - Hubble UI: `https://${HUBBLE_HOSTNAME}` (ou `https://${HUBBLE_LOCAL_HOSTNAME}`).
- Personalize hostnames adicionando entradas no `/etc/hosts` se preferir evitar sslip.io.

### Notas Importantes

- Certificados TLS usam a CA interna gerenciada pelo cert-manager; importe o segredo `cluster-root-ca` se desejar confiança no navegador.
- Scripts conferem se já foram executados antes de prosseguir; repetições são seguras e úteis para correção de falhas.
- Após o passo do ingress, o IP dinamicamente alocado e os hosts derivados ficam persistidos em `${STATE_DIR}/dynamic.env`.
- Cuidado com recursos: requests/limits foram dimensionados para VMs de 4 GB RAM.
- Diretório `old/` mantém manifestos legados para referência; não são usados no fluxo atual.
