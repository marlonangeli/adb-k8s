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

## Testes de uso de recursos

1. Gere carga com os scripts k6 (`tenant-ramp.js`, `shared-interpolation.js`).
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

## Testes de escalabilidade

1. Configure um cenário k6 com rampas de carga (ex.: 0 → 200 VUs em 5 minutos).
2. Observe o HPA com `kubectl --kubeconfig tenant-a.kubeconfig describe hpa
   adb-api` e confirme que o número de réplicas aumenta quando a utilização de
   CPU ultrapassa 70%.
3. Valide o balanceamento pelo `kubectl --kubeconfig tenant-a.kubeconfig get
   endpoints adb-api -o wide` e pelos logs dos pods (diferença de requisições).
4. Para a API de interpolação compartilhada, monitore o Service
   `adb-interpolation-api` no vCluster `shared` e acompanhe o tempo de resposta
   via `shared-interpolation.js`.

## Testes de segurança entre tenants

1. Conecte-se ao vCluster do tenant A e tente acessar o host da API do tenant B
   (`curl http://api-tenant-b.<ip>.sslip.io`). A CiliumNetworkPolicy deve negar
   o tráfego (timeout ou conexão recusada).
2. Valide que somente o namespace `ingress-nginx` e o próprio tenant conseguem
   atingir a API (`kubectl --kubeconfig tenant-a.kubeconfig run curl --rm -it`
   com imagem `curlimages/curl`).
3. Verifique no Hubble UI se há fluxos bloqueados (vermelho) ao tentar acesso
   cruzado – evidencie com captura para o relatório.

## Sincronização GitOps

1. Atualize o overlay do tenant (ex.: ajuste `PUBLIC_BASE_URL` em
   `adb-api-3/k8s/tenants/tenant-a/app.env`).
2. Faça commit e push no repositório correspondente.
3. Execute `bin/95-argocd.sh` para garantir que o Argo CD tenha o vCluster
   registrado.
4. No Argo CD (`http://argocd.<ip>.sslip.io`), verifique se a Application do
   tenant entrou em estado *OutOfSync* e depois voltou a *Synced*.
5. Confirme via `kubectl --kubeconfig tenant-a.kubeconfig get ingress adb-api`
   que o host foi atualizado.

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
- Utilize `kubectl top` (metrics-server) como validação rápida e anexe o output
  junto às métricas de Grafana.
- Para testes de resiliência, simule a queda de um pod (`kubectl delete pod`) e
  prove que o Deployment/HPA recupera a capacidade sem intervenção manual.
