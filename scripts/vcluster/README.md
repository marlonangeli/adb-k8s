# vCluster Toolkit

Ferramentas auxiliares para criar, atualizar e remover vClusters vinculados ao
ambiente Kubernetes, com foco atual em OKE. Todas as automações partem da biblioteca `bin/lib.sh` e
compartilham as mesmas variáveis exportadas pelos arquivos `env.sh` e
`secrets.env`.

## Dependências

Todos os scripts pressupõem que os seguintes CLIs estejam instalados localmente:

- `kubectl`
- `vcluster` (CLI da Loft)
- `envsubst` (parte do GNU gettext)

Durante a execução via `bin/90-vcluster.sh` essas dependências são validadas.
Caso alguma esteja ausente, o processo é encerrado antes de iniciar qualquer
atividade para evitar estados intermediários.

## Scripts principais

- `create.sh` – Cria ou atualiza um vCluster (perfil `private` ou `shared`),
   garantindo que:
  - o namespace host exista e esteja rotulado com as chaves de tenancy;
  - os _resource requests/limits_ sigam o perfil escolhido;
  - os overlays dos tenants usem rotas internas para manter APIs privadas no
    caminho OKE;
  - o kubeconfig seja publicado em `${STATE_DIR}` e, opcionalmente, no
    namespace `monitoring` para observabilidade centralizada.
- `remove.sh` – Faz a limpeza de um vCluster de teste, removendo o namespace
  (por padrão), o arquivo de kubeconfig e o _secret_ publicado para o stack de
  observabilidade.

Ambos os scripts aceitam `--help` para listar opções detalhadas.

## Fluxo recomendado

1. Execute `bin/90-vcluster.sh` para provisionar todos os tenants listados em
   `TENANTS` (default: `tenant-a`) e o vCluster compartilhado `shared`. O script
   cria/atualiza automaticamente:
   - os overlays Kustomize em `adb-api-3/k8s/tenants/<tenant>`;
   - as variáveis `PUBLIC_BASE_URL`/`INTERPOLATION_BASE_URL` para rotas internas
     por padrão;
   - o overlay `adb-interpolation-api/k8s/overlays/shared` com endpoint de
     processamento compartilhado.
2. Para provisionar apenas um tenant isolado:
   ```bash
   scripts/vcluster/create.sh --tenant tenant-lab --profile private
   ```
   O IP e os hosts gerados ficam registrados em `${STATE_DIR}/dynamic.env`
   (`VCLUSTER_TENANT_LAB_SERVICE_IP`, `VCLUSTER_TENANT_LAB_API_HOST`, etc.).
3. Após criar um tenant, reexecute `bin/95-argocd.sh` para registrar o novo
   vCluster no Argo CD e sincronizar as Applications GitOps.
4. Para observabilidade:
   - Decodifique o kubeconfig publicado no namespace `monitoring`:
     ```bash
     kubectl -n monitoring get secret vcluster-tenant-lab-kubeconfig \
       -o jsonpath='{.data.kubeconfig}' | base64 -d > tenant-lab.kubeconfig
     ```
   - Importe esse kubeconfig na fonte de dados *Kubernetes* do Grafana (Dashboard
     > Data sources > Kubernetes) e utilize o Explore para validar métricas por
     tenant.
   - O Hubble UI fica disponível em `http://${HUBBLE_HOSTNAME}` (ou o host
     salvo com `save_state_var`). Para inspecionar fluxos específicos, filtre
     por namespace `vcluster-<tenant>`.
5. Para remover um ambiente de teste:
   ```bash
     scripts/vcluster/remove.sh --cluster tenant-lab
   ```

Os scripts herdam limites personalizados via variáveis de ambiente (ex.: exporte
`PRIVATE_API_LIMIT_CPU=800m` antes de invocar `create.sh`).

## Integração com a esteira principal

- `bin/90-vcluster.sh` é a etapa final de provisionamento do _cluster_ base e
  depende da conclusão das fases anteriores:
  - `bin/55-cert-manager.sh`/`bin/70-observability.sh` para publicar
    certificados e disponibilizar a namespace `monitoring`, permitindo o
    espelhamento de kubeconfigs;
  - `bin/80-longhorn.sh` assegura armazenamento compartilhado para bancos de
    dados dos tenants.
- A saída de `bin/90-vcluster.sh` alimenta `bin/95-argocd.sh`, que registra
  os kubeconfigs recém-criados no Argo CD.
- Os overlays gerados em `adb-api-3/k8s/tenants/<tenant>` são consumidos pelos
  manifests GitOps aplicados pelo Argo CD após a criação do vCluster.

## Rodando somente os vClusters

- `make vcluster` executa exclusivamente o estágio `bin/90-vcluster.sh`,
  respeitando os tenants listados em `TENANTS`.
- Para controlar manualmente a execução:
  ```bash
  TENANTS="tenant-lab tenant-prod" VC_FORCE_RECREATE=1 bin/90-vcluster.sh
  ```
  A variável `VC_FORCE_RECREATE=1` força a reprovisão mesmo que o tenant já
  tenha sido concluído anteriormente.

## Retomada após falhas

`bin/90-vcluster.sh` cria marcadores em `${STATE_DIR}/vcluster-progress`. Caso
algum tenant falhe, basta corrigir a causa e relançar o script: os tenants já
marcados como concluídos são ignorados. Outras opções:

- `VC_RESUME_FROM=<cluster>` – pula todos os tenants anteriores ao informado,
  retomando direto do alvo (`VC_RESUME_FROM=shared` executa apenas o vCluster
  compartilhado).
- `VC_FORCE_RECREATE=1` – ignora os marcadores e refaz cada tenant do zero.
- Para criar apenas um tenant isolado (sem percorrer a lista definida em
  `TENANTS`), execute diretamente:
  ```bash
  scripts/vcluster/create.sh --tenant meu-tenant --profile private
  ```

## Criando novos tenants

1. Garanta que a pasta `adb-api-3/k8s/tenants/<tenant>` exista; o script
   `create.sh` gera automaticamente `app.env`, `secrets.env` (placeholders) e
   `configmap-routing-patch.yaml` para reforcar rotas internas no tenant.
2. Execute:
   ```bash
   scripts/vcluster/create.sh \
     --tenant tenant-novo \
     --cluster tenant-novo \
     --profile private
   ```
3. Os arquivos gerados podem ser ajustados manualmente (ex.: senhas em
   `secrets.env`) e versionados no repositório `adb-api-3`.
4. Para provisionar todos os tenants mapeados na pasta `adb-api-3/k8s/tenants`,
   defina `TENANTS` com a lista desejada e disparar `bin/90-vcluster.sh` ou
   `make vcluster`.
