## Decisões de migração para OKE (Oracle Kubernetes Engine)

### Contexto
- Cluster OKE já criado via Terraform (`infra-oci/oracle-cloud/kubernetes`) com CNI **OCI VCN-Native** e node pool ARM (A1.Flex).
- Objetivo: manter a stack do TCC (vCluster multi-tenant, Argo CD/GitOps, observabilidade, autoscaling opcional) trocando apenas o que não faz sentido em OKE (MetalLB, kube-proxy-free, etc.).
- Risco externo atualizado: a documentação da Oracle para OKE agora destaca o encerramento de manutenção do NGINX Ingress Controller (anunciado pela comunidade Kubernetes para mar/2026), exigindo priorização da migração.

### Networking e segurança
- **CNI**: manter OCI VCN-Native para IP direto no VCN; complementar com **Calico em policy-only** para implementar NetworkPolicy (CNI nativa não aplica policies). A Oracle documenta a instalação do Calico policy-only junto ao OCI VCN-Native para habilitar NetworkPolicy. citeturn1search1
- **Versão suportada**: seguir matriz de compatibilidade Calico da Oracle (3.30.x validada em K8s 1.34). citeturn1search2
- **kube-proxy**: abandonar o modo kube-proxy-free (Cilium) e configurar kube-proxy padrão (recomendado nftables; ipvs entrou em descontinuação no 1.35). citeturn0search0turn0search4
- **NetworkPolicy**: reaproveitar os manifests `networking.k8s.io/v1` já existentes nas apps (ex.: `adb-api-3/k8s/base/networkpolicy-*.yaml`); converter CiliumNetworkPolicy para NetworkPolicy quando migrar os vclusters.
- **Security Lists/NSG**: restringir regras herdadas do Terraform (abriram NodePorts 30000-32767 e SSH amplo). Recomendar mover para NSGs com escopos mínimos e fechar 10256/NodePort para internet, mantendo apenas LB→workers e bastion restrito.

### Ingress / Gateway
- **Prioridade imediata**: remover `ingress-nginx` do caminho OKE como bloqueio de deploy confiável.
- **Fase 1 (redução de risco)**: usar **OCI Native Ingress Controller** (modo add-on) para substituir o edge legado mantendo API `Ingress` enquanto os manifests são limpos de dependências bare-metal.
- **Fase 2 (arquitetura alvo)**: migrar para **Gateway API** (`GatewayClass`, `Gateway`, `HTTPRoute`), escolhendo controlador conforme trade-off operacional:
  - **Envoy Gateway**: melhor alinhamento com Gateway API e documentação OKE.
  - **Istio add-on**: ciclo de vida do control plane gerenciado pela Oracle, com maior footprint.
  - **Traefik**: opção de menor footprint operacional para o projeto, mantendo a direção já considerada no repositório.
- Services de entrada devem ser expostos como `LoadBalancer` na subnet `lbs` (OCI LB gerenciado); remover dependência de MetalLB e hosts `sslip.io` baseados em VIP local.

### Armazenamento
- Manter **Longhorn** conforme tutorial oficial da Oracle para OKE (usa Helm + cloud-init que anexa block volumes). citeturn0search1turn0search7
- Garantir `defaultSettings.createDefaultDiskLabeledNodes=true` no Helm values e que o script de init anexe volumes nos novos nós (replicar no userdata do node pool).
- PVCs das aplicações e do vCluster devem apontar para `longhorn` StorageClass; remover `oci-bv` se não for usado.

### Observabilidade
- Reempacotar `kube-prometheus-stack`/Grafana/Hubble-equivalente:
  - Datasource Kubernetes via API interna; storage no Longhorn.
  - Ajustar limits para ARM A1 (baseline similar ao bare-metal: Prometheus ~1Gi, Grafana ~384Mi).
  - Hubble UI/Relay saem; para tráfego podemos usar Flow logs do OCI VCN ou, se Calico Enterprise não for opção, manter apenas métricas de rede no Prometheus.

### Autoscaling
- **Cluster Autoscaler (OCI)**: instalar chart oficial apontando para o node pool; manter flag em `env.sh` para ligar/desligar (necessário para experimentos do TCC).
- **HPA**: preservar manifests existentes e habilitar via variável (ex.: `ENABLE_HPA=1`) para comparar cenários.

### vCluster / Tenants
- Services do vCluster passam a `LoadBalancer` (OCI) ou `ClusterIP` + Traefik Gateway HTTPRoute; retirar uso de `VCLUSTER_METALLB_POOL`.
- Policies: traduzir CiliumNetworkPolicy do profile private para NetworkPolicy padrão (deny-all + DNS + ingress VIP).
- Hosts: substituir `sslip.io` por domínio configurado em Cloudflare/OCI DNS; documentar passo a passo de CNAME/A para o IP público do LB.

### DNS/TLS
- Automatizar opção Cloudflare (A/AAAA + CNAME) para o IP do LB Traefik; alternativa: OCI DNS.
- TLS opcional com cert-manager (HTTP-01 no LB) ou certificados autoassinados; manter flag `TLS_ENABLED`.

### Itens de compatibilidade e risco
- Calico policy-only é suportado em VCN-Native; confirmar versão 3.30.x no cluster 1.34/1.35 antes de aplicar. citeturn1search2
- kube-proxy ipvs deixará de ser suportado → usar `mode: nftables` ou `iptables` até NFT ser padrão. citeturn0search0turn0search4
- Longhorn em OKE requer volumes anexados via cloud-init; sem isso os discos default são só o boot de 100 GiB. citeturn0search6
- `ingress-nginx` sem manutenção pós mar/2026 aumenta risco de segurança e suporte; não usar como estratégia de destino no OKE.

### Próximos passos sugeridos
1) Ajustar Terraform: fechar Security Lists, opcionalmente trocar para NSGs; incluir script de init do Longhorn no node pool; outputs com subnet OCIDs e LB IP.  
2) Definir e implementar o caminho de edge em duas fases (OCI Native Ingress Controller -> Gateway API) e criar os manifests/charts correspondentes (Envoy/Istio/Traefik conforme decisão final), além de Longhorn values, Calico policy-only e Cluster Autoscaler.  
3) Refatorar `env.sh`/`Makefile`/`bin/` removendo MetalLB/Cilium/kubeadm; adicionar alvos para Traefik, Calico, Longhorn, autoscaler, vCluster.  
4) Atualizar manifests das apps e vClusters (StorageClass longhorn, NetworkPolicy padrão, recursos de rota alinhados ao controlador escolhido: `Ingress` com OCI Native ou `Gateway`/`HTTPRoute`).  
5) Documentar DNS (Cloudflare/OCI), roteiro de verificação da rota de entrada escolhida e critérios de corte (kubectl, gateway/ingress status, longhorn ui, prometheus).
