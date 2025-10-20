# k6 Load Testing Playbooks

Os testes de carga serão executados a partir de uma máquina externa para evitar
impacto direto no cluster bare-metal. Utilize esta pasta como base para scripts
k6 focados nos cenários do TCC.

## Pré-requisitos

- k6 >= 0.48 instalado na estação de testes.
- Acesso HTTPS/HTTP ao Ingress do cluster (mesmos hosts configurados para os
  tenants e para a API de interpolação compartilhada).
- Variáveis de ambiente exportadas com as URLs dos serviços:
  - `TENANT_API_BASE_URL`
  - `TENANT_API_TOKEN`
  - `INTERPOLATION_BASE_URL`
- Hosts e portas podem ser obtidos em `${STATE_DIR}/dynamic.env` após a
  execução do `bin/90-vcluster.sh` e `bin/95-argocd.sh`.

## Fluxo sugerido

1. Copie os arquivos de `tests/k6/` para a estação de testes.
2. Ajuste as variáveis no arquivo `.env.sample` (ou exporte manualmente).
3. Execute um smoke test:
   ```bash
   k6 run tenant-smoke.js --vus 5 --duration 2m
   ```
4. Para testes de estresse, utilize stages:
   ```bash
   k6 run tenant-ramp.js -e TARGET_VUS=200
   ```

## Estrutura

- `tenant-smoke.js`: validação básica dos endpoints da API de dados (GET/POST).
- `tenant-ramp.js`: cenário de rampa com métricas de latência/p95.
- `shared-interpolation.js`: garante que o balanceamento `least_conn` está
  respondendo dentro dos SLAs.

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

## Melhorias recomendadas para os testes

- Crie um cenário adicional usando o executor `ramping-arrival-rate` em um
  novo script (ex.: `tenant-arrival-rate.js`) para controlar requisições por
  segundo e simular picos reais.
- Separe cenários de leitura e escrita em arquivos distintos, coletando métricas
  de sucesso/erro individualmente.
- Propague `X-Request-ID` nas requisições (k6 `http.batch`) e rastreie no
  Grafana/Loki para correlacionar latência com logs.
- Persista os resultados (`k6 run ... --out json=run.json`) e anexe ao TCC como
  evidência dos SLAs cumpridos.
