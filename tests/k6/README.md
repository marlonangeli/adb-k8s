# k6 Load Testing Playbooks

Os testes agora podem ser executados **dentro do cluster Kubernetes** usando o
container oficial `grafana/k6:1.7.1`, mirando diretamente os **Services** reais
do host cluster e dos vClusters. Isso evita o viés do `kubectl port-forward` e
gera evidências melhores para o TCC.

## Pré-requisitos

- `mise` configurado na raiz do workspace (`/home/ilegna/Work/tcc`).
- `kubectl` funcional via `mise exec -- kubectl`.
- vClusters `shared` e `abc` registrados e saudáveis.
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
3. Rode a rampa de **Escalabilidade** da interpolação compartilhada quando quiser
   evidenciar crescimento de carga e HPA:
   ```bash
   TARGET_VUS=30 mise run k6-shared-escalabilidade
   ```
4. Rode cenários funcionais/algorítmicos da API compartilhada:
   ```bash
   mise run k6-shared-root-smoke
   mise run k6-shared-kriging
   mise run k6-shared-idw-grid
   mise run k6-shared-isi-grid
   mise run k6-shared-isi-geostatistics
   ```
5. Rode smoke e ramp-up por tenant:
    ```bash
    mise run k6-tenant-abc-smoke
    TARGET_VUS=50 mise run k6-tenant-abc-ramp
    ```
6. Se um Job antigo ficar no cluster, limpe antes de repetir o mesmo cenário:
   ```bash
   mise run k6-cleanup
   ```

## Estrutura

- `tenant-smoke.js`: validação básica da API de dados por tenant usando
  `GET /input/hi` e status `200`.
- `tenant-ramp.js`: cenário de rampa com bootstrap real (`POST /person` +
  `POST /auth`) e CRUD autenticado leve de `company` e `employee`.
- `shared-interpolation.js`: cenário principal de **balanceamento real** usando
  `Connection: close` + métricas por `hostname` retornado em `/healthz`.
- `shared-interpolation/escalabilidade.js`: rampa de VUs da API compartilhada,
  usando endpoint algorítmico para gerar CPU e `/healthz` para evidenciar
  distribuição entre pods escalados.
- `shared-interpolation/*.js`: cenários algorítmicos da API compartilhada.
- `lib/k6-common.js`: métricas customizadas, metadata e summaries padrão.

## Runner in-cluster e artefatos

Os `mise tasks` usam `scripts/k6-run-incluster.sh`, que:

1. cria `ConfigMaps` com scripts e payloads;
2. sobe um `Job` Kubernetes com `grafana/k6:1.7.1`;
3. executa o cenário contra o **Service** real do cluster;
4. envia métricas k6 diretamente para o Prometheus via remote write;
5. consulta o Prometheus para gerar relatórios locais na pasta de evidências.

Cada execução salva, no mínimo:

- `k6.log`
- `paper-report.md`
- `paper-report.html`
- `overview.csv`
- `pod-distribution.csv`
- `report-index.json` com o `testid` usado no Prometheus
- snapshots `pre`/`post` apenas do escopo testado (`shared` ou `abc`)

O Prometheus recebe as séries com `testid=<timestamp>-<job>`, `test_run`,
`target_service` e `target_scope`. Use esse `testid` para filtrar no Grafana.

## Escalabilidade compartilhada

Execute com carga conservadora primeiro:

```bash
cd /home/ilegna/Work/tcc
TARGET_VUS=30 mise run k6-shared-escalabilidade
```

Parâmetros ajustáveis sem editar o script:

```bash
TARGET_VUS=50 \
K6_RAMP_STAGE_1_DURATION=2m \
K6_RAMP_STAGE_2_DURATION=3m \
K6_HOLD_DURATION=5m \
K6_RAMP_DOWN_DURATION=2m \
K6_SLEEP_SECONDS=0.5 \
INTERPOLATION_SCALABILITY_ENDPOINT=/kriging \
INTERPOLATION_SCALABILITY_PAYLOAD=./payloads/kriging.json \
INTERPOLATION_SCALABILITY_EXPECTED_STATUS=201 \
mise run k6-shared-escalabilidade
```

Use `report-index.json` para obter o `testid`; filtre o dashboard Grafana `19665`
por esse valor e correlacione a janela com HPA/réplicas do Deployment
`adb-interpolation-api` no namespace `processing`.

### Pausar Argo CD durante evidências de HPA

Quando o ensaio de escalabilidade exigir alteração temporária de réplicas,
imagem, limites ou HPA, pause a sincronização automática da Application
`shared-interpolation` antes da rampa. Isso evita que o Argo CD reverta o estado
manual enquanto o k6 gera carga.

```bash
kubectl -n argocd patch application shared-interpolation --type merge \
  -p '{"spec":{"syncPolicy":null}}'
kubectl -n argocd get application shared-interpolation \
  -o jsonpath='{.spec.syncPolicy}{"\n"}'
```

Depois de salvar os artefatos e screenshots, restaure o GitOps padrão:

```bash
kubectl -n argocd patch application shared-interpolation --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
kubectl -n argocd get application shared-interpolation
```

Não deixe a Application pausada após o teste; registre no relatório o horário em
que o pause/restore foi aplicado.

## Grafana / Prometheus

O runner usa por padrão:

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write
k6 run -o experimental-prometheus-rw --tag testid=<run-id> ...
```

Dashboard recomendado para importar no Grafana:

- `19665` — **k6 Prometheus**, sem native histograms.

Opcional, apenas se native histograms forem habilitados no Prometheus/k6:

- `18030` — **k6 Prometheus (Native Histograms)**.

## Serviços reais usados nos testes

- Shared interpolation (host cluster):
  - `http://adb-interpolation-api-x-processing-x-shared`
- Tenant `abc` (host cluster):
  - `http://adb-api-x-app-x-abc`

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
