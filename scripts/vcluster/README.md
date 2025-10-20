# vCluster Toolkit

Ferramentas auxiliares para criar, atualizar e remover vClusters vinculados ao
ambiente bare-metal. Todas as automações partem da biblioteca `bin/lib.sh` e
compartilham as mesmas variáveis exportadas pelos arquivos `env.sh` e
`secrets.env`.

## Scripts principais

- `create.sh` – Cria ou atualiza um vCluster (perfil `private` ou `shared`),
  garantindo que:
  - o namespace host exista e esteja rotulado com as chaves de tenancy;
  - os _resource requests/limits_ sigam o perfil escolhido;
  - as políticas de rede Cilium sejam aplicadas, restringindo o tráfego entre
    tenants e liberando apenas os fluxos esperados;
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
   - as variáveis `PUBLIC_BASE_URL`/`INTERPOLATION_BASE_URL` com base no IP
     exposto (`api-<tenant>.<ip>.sslip.io` e `interpolation.<ip>.sslip.io`);
   - o overlay `adb-interpolation-api/k8s/overlays/shared` com o host público
     do processamento.
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

Os scripts reutilizam o IP do Ingress (obtido via `current_ingress_ip()`) e
herdam limites personalizados via variáveis de ambiente (ex.: exporte
`PRIVATE_API_LIMIT_CPU=800m` antes de invocar `create.sh`).
