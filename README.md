## Plataforma K8s (OKE + legado bare-metal)

> Ambiente alvo: **Debian 12**, acesso SSH permitido **apenas** para `utfpr`. Conecte via `ssh utfpr@200.134.18.55 -p 22252`, em cada nó execute `su -` e só então rode os scripts como root.

## OKE quick start (current path)

- For Oracle OKE operation, use `docs/oke-operator-runbook.md` as the canonical guide.
- That runbook contains: exact script order, validation gates, OCI Console paths (NSG/DNS/WAF), and controlled public exposure steps.

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
│   ├─ 90-vcluster.sh
│   └─ 95-argocd.sh
├─ scripts/
│   ├─ validate-tenant-routing-isolation.sh  # valida isolamento entre tenants + API compartilhada
│   └─ vcluster/          # helpers para criar/atualizar/remover vclusters manualmente
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

1. (Opcional, recomendado em ambientes novos) Execute `scripts/install-cli-deps.sh` como root para instalar/atualizar automaticamente `kubeadm`, `kubectl`, `kubelet`, Helm, Cilium CLI, vcluster, Kustomize e Argo CD (requer conexão externa e `curl`, `tar`, `gpg`).
2. Copie `secrets.env.example` para `secrets.env` e defina as senhas de Grafana, Rancher, Argo CD (e demais serviços que usar). TLS está desligado (`TLS_ENABLED=0` em `env.sh`); preencha `CERT_MANAGER_ACME_EMAIL` e exporte `TLS_ENABLED=1`/`TLS_CLUSTER_ISSUER` se desejar reativar certificados.
3. Ajuste `env.sh` conforme necessário (IPs, ranges, overrides de host, opções de SSH).
4. Garanta acesso SSH como root entre o nó de controle e os demais (chaves ou senha).
5. Opcional: teste conectividade com `bin/run-on-nodes.sh bin/10-so-requirements.sh --hosts "192.168.30.53" -- --help` (será solicitado o password de root via `su -`).

### Fluxo rápido

0. `make preflight-oke` para validar contexto OKE e estado local antes de executar estágios.
1. `bin/10-so-requirements.sh` (pode usar `bin/run-on-nodes.sh ... --all`).
2. `bin/20-kubeadm-init.sh` no control-plane (guarde o `~/join-worker.sh`).
3. `bin/30-cilium.sh` para rede/Hubble.
4. `bin/35-join-workers.sh` ou `make workers`.
5. `bin/40-metallb.sh` → `bin/50-ingress-nginx.sh` (VIP em `${STATE_DIR}/dynamic.env`).
6. `bin/55-cert-manager.sh` apenas se `TLS_ENABLED=1`.
7. `bin/60-rancher.sh`, `bin/70-observability.sh`, `bin/80-longhorn.sh`, `bin/90-vcluster.sh`.
8. `bin/95-argocd.sh` para instalar o Argo CD, registrar os vClusters e criar as Applications GitOps.

> Para o caminho OKE, use `make deploy-oke` e siga `docs/oke-operator-runbook.md`.

### Provisionamento de novos tenants

1. Crie o vCluster com `scripts/vcluster/create.sh --tenant <tenant> --profile private`. O script valida nomes (`[a-z0-9-]+`), aplica políticas Cilium e gera/atualiza os overlays em `adb-api-3/k8s/tenants/<tenant>` com hosts baseados no IP alocado (`api-<tenant>.<ip>.sslip.io`).
2. Execute `bin/95-argocd.sh` para registrar o novo vCluster no Argo CD. O script verifica se o cluster já está configurado e reaproveita o secret quando o endpoint é o mesmo.
3. Consulte `${STATE_DIR}/dynamic.env` para recuperar variáveis como `VCLUSTER_<TENANT>_SERVICE_IP`, `VCLUSTER_<TENANT>_API_HOST` e `VCLUSTER_SHARED_INTERPOLATION_HOST`.
4. Exporte os kubeconfigs publicados no namespace `monitoring` e importe-os no Grafana/Hubble para análise pós-teste:
   ```bash
   kubectl -n monitoring get secret vcluster-<tenant>-kubeconfig \
     -o jsonpath='{.data.kubeconfig}' | base64 -d > <tenant>.kubeconfig
   ```
5. Ajuste `adb-api-3/k8s/tenants/<tenant>/secrets.env` com credenciais reais antes do deploy GitOps.
6. Para remover ambientes de teste, utilize `scripts/vcluster/remove.sh --cluster <tenant>` (limpa namespace, kubeconfig e secret de observabilidade).

### Testes e observabilidade

- Execute `scripts/validate-tenant-routing-isolation.sh` (ou `make validate-tenant-routing`) para validar rapidamente o baseline de isolamento no OKE: API privada por tenant, sem Ingress da API de dados e acesso compartilhado à interpolação.
- Execute `scripts/oke-exposure-report.sh` (ou `make report-oke-exposure`) para listar quais serviços `LoadBalancer` estão internos/públicos e revisar recursos de borda.
- Utilize os scripts `tests/k6/*.js` como base para smoke, ramp-up e validação da API compartilhada; exporte os resultados (`--out json=...`) e registre no TCC.
- Após cada execução, configure o Grafana (dados de Kubernetes) e o Hubble com os kubeconfigs exportados para coletar métricas e fluxos.
- Consulte `docs/testing-guidelines.md` para um roteiro completo cobrindo uso de recursos, escalabilidade, segurança, GitOps e a avaliação do Liqo como trabalho futuro.

### Ajustes de recursos padrão

- Observabilidade (kube-prometheus-stack) usa retenção de 7 dias, intervalo de scrape de 60 s e requests reduzidas (Prometheus 512 Mi/1.25 Gi, Grafana 192 Mi/384 Mi, kube-state-metrics 192 Mi/256 Mi) para caber confortavelmente em VMs de 4 GB.
- Cilium/Hubble aplicam limites explícitos nas instâncias Relay/UI (≈100–200 Mi) para conter o uso de memória do namespace `kube-system`.
- Longhorn, Rancher e CSI foram configurados com requests e limits moderados (UI/manager ~160–320 Mi; Rancher 384–768 Mi) preservando estabilidade sem desabilitar componentes.
- Ajustes adicionais podem ser feitos exportando chart values customizados, mas mantenha os limites acima como baseline durante os testes do TCC.

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
