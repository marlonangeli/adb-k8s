# k6 Load Testing Playbooks

Os testes agora podem ser executados **dentro do cluster Kubernetes** usando o
container oficial `grafana/k6:1.7.1`, mirando diretamente os **Services** reais
do host cluster e dos vClusters. Isso evita o viés do `kubectl port-forward` e
gera evidências melhores para o TCC.

## Pré-requisitos

- `mise` configurado na raiz do workspace (`/home/ilegna/Work/tcc`).
- `kubectl` funcional via `mise exec -- kubectl`.
- vClusters `shared`, `abc` e `xyz` registrados e saudáveis.
- Token válido para cenários autenticados da ADB API (`TENANT_API_TOKEN`), se o
  endpoint exigir autenticação.

## Fluxo sugerido

1. Capture o baseline e atualize o dashboard do TCC:
   ```bash
   mise run k6-prepare-incluster
   ```
2. Rode o teste de balanceamento da interpolação compartilhada:
   ```bash
   mise run k6-shared-balance
   ```
3. Rode cenários funcionais/algorítmicos da API compartilhada:
   ```bash
   mise run k6-shared-root-smoke
   mise run k6-shared-kriging
   mise run k6-shared-idw-grid
   mise run k6-shared-isi-grid
   mise run k6-shared-isi-geostatistics
   ```
4. Rode smoke e ramp-up por tenant:
   ```bash
   mise run k6-tenant-abc-smoke
   mise run k6-tenant-xyz-smoke
   TARGET_VUS=50 mise run k6-tenant-abc-ramp
   TARGET_VUS=50 mise run k6-tenant-xyz-ramp
   ```

## Estrutura

- `tenant-smoke.js`: validação básica da API de dados por tenant.
- `tenant-ramp.js`: cenário de rampa para HPA/latência dos tenants.
- `shared-interpolation.js`: cenário principal de **balanceamento real** usando
  `Connection: close` + métricas por `hostname` retornado em `/healthz`.
- `shared-interpolation/*.js`: cenários algorítmicos da API compartilhada.
- `lib/k6-common.js`: métricas customizadas, metadata e summaries padrão.

## Runner in-cluster e artefatos

Os `mise tasks` usam `scripts/k6-run-incluster.sh`, que:

1. cria `ConfigMaps` com scripts e payloads;
2. sobe um `Job` Kubernetes com `grafana/k6:1.7.1`;
3. executa o cenário contra o **Service** real do cluster;
4. coleta artefatos para a pasta de evidências.

Cada execução salva, no mínimo:

- `k6.log`
- `metrics.json`
- `summary-export.json`
- `summary.json`
- `summary.md`
- `metadata.json`
- `html-report.html`
- `paper-report.md`
- `paper-report.html`
- `overview.csv`
- `pod-distribution.csv`
- snapshots `pre`/`post` de `kubectl top`, Applications e runtime

## Serviços reais usados nos testes

- Shared interpolation (host cluster):
  - `http://adb-interpolation-api-x-processing-x-shared`
- Tenant `abc` (host cluster):
  - `http://adb-api-x-app-x-abc`
- Tenant `xyz` (host cluster):
  - `http://adb-api-x-app-x-xyz`

## Exportando kubeconfigs para observabilidade

Após cada ensaio, utilize os kubeconfigs publicados em `monitoring` para
analisar telemetria no Grafana/Hubble:

```bash
TENANT=tenant-a
kubectl -n monitoring get secret vcluster-${TENANT}-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > ${TENANT}.kubeconfig
```

1. Abra o Grafana (`http://${GRAFANA_HOSTNAME}`) e adicione uma fonte de dados
   *Kubernetes* apontando para o arquivo exportado.
2. Use o modo *Explore* para filtrar métricas por namespace `vcluster-${TENANT}`
   (CPU/memória via `container_cpu_usage_seconds_total`,
   `container_memory_working_set_bytes`).
3. No Hubble UI (`http://${HUBBLE_HOSTNAME}`), aplique filtros de namespace
   para validar se o tráfego entre tenants permanece bloqueado.

## Evidência para o TCC

- Use `paper-report.html` para gráficos/tabelas rápidas.
- Use `paper-report.md` e `pod-distribution.csv` para anexos e tabelas do texto.
- Use `html-report.html` (dashboard exportado pelo k6) como gráfico adicional.
- Use os snapshots `pre`/`post` para correlacionar latência, HPA e consumo.
