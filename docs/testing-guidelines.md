# Guia de Testes para o TCC

Este documento consolida orientações para validar o ambiente multi-tenant
provisionado com vClusters, Argo CD e observabilidade compartilhada.

## Objetivos

1. **Uso de recursos** – medir consumo de CPU, memória, IO e tráfego por
   tenant durante cenários de carga.
2. **Escalabilidade** – garantir que o HPA das APIs replique pods conforme a
   demanda e que o balanceamento `least_conn` distribua requisições entre nós.
3. **Segurança** – comprovar isolamento entre tenants e acesso controlado à
   API de interpolação.
4. **Cadeia GitOps** – demonstrar que alterações de manifestos aplicadas via
   Git são sincronizadas automaticamente pelo Argo CD.

## Atualização critica para OKE (2026-03)

- A substituicao de `ingress-nginx` no caminho OKE e obrigatoria antes do
  primeiro deploy confiavel.
- Os testes de entrada devem validar o modelo escolhido para OKE:
  - `Ingress` com OCI Native Ingress Controller, ou
  - `Gateway`/`HTTPRoute` com controlador Gateway API (Envoy, Istio add-on,
    Traefik).
- Evite cenarios dependentes de `sslip.io` no fluxo OKE; use DNS real do
  ambiente alvo.

## Estado operacional atual para testes (2026-04)

- Endpoints públicos disponíveis para evidência:
  - Grafana -> `http://144.22.151.206`
  - Argo CD -> `http://168.138.153.100`
- vClusters acessíveis por kubeconfig público:
  - `shared` -> `147.15.124.246`
  - `abc` -> `163.176.198.222`
  - `xyz` -> `64.181.184.95`
- Estado base antes de iniciar carga:
  - `shared-interpolation` -> `Synced / Healthy`
  - `tenant-abc-adb-api` -> `Synced / Healthy`
  - `tenant-xyz-adb-api` -> `Synced / Healthy`

## Regras para stress tests em Always Free

1. **Não aumentar capacidade do nodepool**.
2. Começar sempre com carga leve e subir em rampas.
3. Monitorar continuamente:
   - `kubectl -n argocd get applications -A`
   - `kubectl top nodes`
   - `kubectl top pods -A`
   - dashboards do Grafana
4. Interromper a carga se qualquer tenant sair de `Healthy`.
5. Evitar reabilitar componentes opcionais de observabilidade/Argo antes dos
   testes sem revisar headroom.

## Testes de uso de recursos

1. Gere carga com os scripts k6 **in-cluster** usando os tasks em `mise.toml`
   (`k6-shared-balance`, `k6-tenant-abc-ramp`, `k6-tenant-xyz-ramp`, etc.).
2. Antes de iniciar, capture baseline do cluster:
    ```bash
   cd /home/ilegna/Work/tcc
   mise run k6-prepare-incluster
    ```
2. Exporte o kubeconfig do tenant a partir do secret publicado em `monitoring`
   e configure a fonte de dados *Kubernetes* no Grafana:
   ```bash
   kubectl -n monitoring get secret vcluster-tenant-a-kubeconfig \
     -o jsonpath='{.data.kubeconfig}' | base64 -d > tenant-a.kubeconfig
   ```
3. No Grafana, utilize os dashboards `Kubernetes / Compute Resources` ou o
   modo *Explore* para acompanhar `container_cpu_usage_seconds_total` e
   `container_memory_working_set_bytes` filtrando por namespace
   `vcluster-tenant-a`.
4. Correlacione com métricas de rede no Hubble UI filtrando namespace e pod.
5. Registre também o consumo dos componentes de infra principais (`vcluster-*`,
   `longhorn-system`, `monitoring`, `argocd`) para justificar o tuning
   `Always Free` na análise do TCC.

## Testes de escalabilidade

1. Configure um cenário k6 com rampas progressivas. Para este cluster, prefira
   começar com algo como:
   - `0 -> 20 VUs` em 2 min
   - `20 -> 50 VUs` em 3 min
   - só depois elevar caso o cluster permaneça saudável
2. Observe o HPA com `kubectl --kubeconfig tenant-a.kubeconfig describe hpa
   adb-api` e confirme que o número de réplicas aumenta quando a utilização de
   CPU ultrapassa 70%.
3. Valide o balanceamento real da API compartilhada com `mise run
   k6-shared-balance`, que executa um Job k6 dentro do cluster contra o Service
   `adb-interpolation-api-x-processing-x-shared` e gera `pod-distribution.csv`,
   `paper-report.md` e `paper-report.html`.
4. Para tenants, use `mise run k6-tenant-abc-ramp` / `mise run
   k6-tenant-xyz-ramp` e correlacione os artefatos com `kubectl top`, HPA e
   snapshots do Grafana.

## Testes de segurança entre tenants

1. Execute o baseline automatizado:
   ```bash
   cd /home/ilegna/Work/tcc/adb-k8s
   scripts/validate-tenant-routing-isolation.sh
   ```
   O script valida:
   - `adb-api-3` sem `Ingress` e sem `LoadBalancer` por tenant;
   - acesso do tenant apenas à sua própria API;
   - acesso dos tenants à API compartilhada de interpolação.
2. Para validação explícita de bloqueio cruzado, execute o mesmo script com URLs
   de teste (`--a-to-b-url` e `--b-to-a-url`) e confirme status de bloqueio.
3. Gere o relatório de exposição para evidenciar quais serviços estão internos
   ou públicos no momento do teste:
   ```bash
   cd /home/ilegna/Work/tcc/adb-k8s
   make report-oke-exposure
   ```
4. Como evidência complementar, verifique no Hubble UI fluxos negados ao tentar
   acesso cruzado e anexe capturas no relatório.

## Sincronização GitOps

1. Atualize o overlay do tenant (ex.: ajuste `PUBLIC_BASE_URL` em
   `adb-api-3/k8s/tenants/tenant-a/app.env`).
2. Faça commit e push no repositório correspondente.
3. Execute `bin/95-argocd.sh` para garantir que o Argo CD tenha o vCluster
   registrado.
4. No Argo CD (`http://argocd.<dominio-do-lb>`), verifique se a Application do
   tenant entrou em estado *OutOfSync* e depois voltou a *Synced*.
5. Confirme que a rota de entrada foi atualizada no recurso correspondente:
   `Ingress` (OCI Native Ingress) ou `HTTPRoute` (Gateway API).

## Considerações sobre o Liqo

O Liqo foi pensado inicialmente para cenários multi-cluster (federar clusters
heterogêneos). No contexto atual:

- Não há um segundo cluster físico ou virtual dedicado; todos os tenants estão
  dentro do mesmo cluster físico, isolados por vClusters e Cilium.
- Introduzir o Liqo sem um par reduz o valor pedagógico e adiciona superfície
  operacional (pod scheduling remoto, CRDs extras, consumo de recursos).
- Para o TCC, o impacto é baixo: a tese continua demonstrando multi-tenancy e
  balanceamento distribuído, mas sem a parte de "elasticidade inter-cluster".

### Recomendação

- Documente a arquitetura proposta para o Liqo como trabalho futuro, destacando
  os requisitos (segundo cluster, roteamento entre datacenters, etc.).
- Foque a avaliação prática nos vClusters, evidenciando isolamento lógico,
  automação GitOps e observabilidade multi-tenant – que permanecem alinhados ao
  objetivo do projeto.

## Sugestões adicionais

- Registre os resultados (capturas do Grafana/Hubble, tabelas de consumo, logs)
  logo após os testes para facilitar a inclusão no TCC.
- Priorize os artefatos exportados pelos runners k6 in-cluster (`html-report.html`,
  `paper-report.html`, `paper-report.md`, `pod-distribution.csv`, snapshots
  `pre`/`post`) como base para tabelas e figuras do trabalho.
- Utilize `kubectl top` (metrics-server) como validação rápida e anexe o output
  junto às métricas de Grafana.
- Para testes de resiliência, simule a queda de um pod (`kubectl delete pod`) e
  prove que o Deployment/HPA recupera a capacidade sem intervenção manual.
- Mantenha uma tabela simples por execução contendo:
  - horário inicial/final
  - perfil de carga
  - estado do Argo antes/depois
  - uso de CPU/memória dos nodes
  - se houve `Pending`, `Degraded` ou throttling
