# Cluster Host Instability – 29/10/2025

## Contexto
- Ambiente bare-metal composto por `marlon-tcc-vm1` (control-plane) e workers `marlon-tcc-vm2` / `marlon-tcc-vm3`.
- Serviços essenciais: Cilium (sem kube-proxy), ingress-nginx, MetalLB, Longhorn, monitoring (kube-prometheus-stack) e vClusters.
- Serviços opcionais já reduzidos manualmente: Rancher (`deployment/rancher` escalado para 0) e Argo CD (`argocd-server`, `argocd-repo-server` escalados para 0).

## Sintomas Observados
- `kubectl get pods -A` mostrava múltiplos `CrashLoopBackOff` e falhas de prontidão em quase todos os componentes de sistema.
- Eventos recorrentes de `context deadline exceeded` para liveness/readiness probes em ingress-nginx, Cilium, MetalLB, Argocd, Rancher, monitoring e Longhorn.
- `kubectl logs -n kube-system kube-apiserver-marlon-tcc-vm1` registrou reinicializações devido a `dial tcp 127.0.0.1:2379: operation was canceled`.
- `kubectl logs -n kube-system etcd-marlon-tcc-vm1` exibiu `waiting for ReadIndex response took too long` e `slow fdatasync` (>2s), indicando escrita bloqueando o Raft log.
- Métricas de host via `kubectl debug node/... top -bn1` mostraram espera de I/O elevada:
  - `marlon-tcc-vm1`: ~63% `wa` (I/O wait), CPU ociosa mas processos presos aguardando disco.
  - `marlon-tcc-vm2`: ~30% `wa`, confirmando pressão de disco generalizada.
- `df -h` revelou uso de apenas ~22% do volume (`/dev/xvda1`), descartando falta de espaço.
- Longhorn manager (`kubectl logs -n longhorn-system longhorn-manager-5zncr`) repetia mensagens de incapacidade de preparar a engine-image em `marlon-tcc-vm3` e falhas em `backup cleanup-all-mounts`, sugerindo operações contínuas em disco.

## Diagnóstico
1. **Etcd bloqueado por latência de disco** – quando os flushes (`fdatasync`) demoram >2s, leituras lineares e heartbeat demoram a ser servis, derrubando o `kube-apiserver`.
2. **API server reiniciando** – liveness probe falha e o processo é reiniciado, tornando o cluster inacessível e provocando falha em cascata de todos os componentes dependentes.
3. **Cadeia de reinicializações** – ingress, Cilium, MetalLB, monitoring e Longhorn dependem do API server: sem resposta dentro do timeout, reiniciam continuamente.
4. **I/O anômalo persistente** – ausência de PVCs atrelados a Longhorn sugere que engine image/backup pipelines estão gerando tráfego inútil.

## Plano de Mitigação Imediata
1. **Medir a origem da latência de disco**
   ```bash
   kubectl debug node/marlon-tcc-vm1 --image=busybox -- chroot /host iostat -xz 5 3
   kubectl debug node/marlon-tcc-vm1 --image=busybox -- chroot /host pidstat -d 5 5
   ```
   Repetir em `marlon-tcc-vm2` / `vm3` para confirmar quais processos/grupos saturam o disco.

2. **Reduzir ruído de componentes opcionais (já executado)**
   - Rancher e Argo CD escalados para 0 réplicas.
   - Manter Down: `kubectl get deploy -n cattle-system` / `kubectl get deploy -n argocd` para confirmar.

3. **Quiescer Longhorn temporariamente se for a fonte de I/O**
   ```bash
   kubectl scale deployment longhorn-driver-deployer -n longhorn-system --replicas=0
   kubectl delete pod -n longhorn-system engine-image-ei-26bab25d-* --ignore-not-found
   ```
   *Observação*: realizar apenas após confirmar que nenhum volume Longhorn está em uso (não há PVCs desde o último inventário).

4. **Compactar e defragmentar etcd após estabilizar o I/O**
   - Necessário `etcdctl` com acesso aos certificados:
     ```bash
     ETCDCTL_API=3 etcdctl \
       --endpoints=https://127.0.0.1:2379 \
       --cacert=/etc/kubernetes/pki/etcd/ca.crt \
       --cert=/etc/kubernetes/pki/etcd/server.crt \
       --key=/etc/kubernetes/pki/etcd/server.key \
       endpoint status --write-out=table
     ETCDCTL_API=3 etcdctl ... compact <REV>
     ETCDCTL_API=3 etcdctl ... defrag
     ```
     - Se a rede impedir pull de imagens, copiar `etcdctl` para o host via pacote deb ou binário estático.

5. **Monitorar recuperação**
   - `kubectl logs -n kube-system etcd-marlon-tcc-vm1 -f` (sem novos `slow fdatasync`).
   - `kubectl get pods -n kube-system | grep kube-apiserver` (deve permanecer 1/1).
   - `kubectl get pods -A` (controlar retorno do ingress, Cilium, MetalLB, monitoring).

6. **Restaurar Longhorn e workloads essenciais**
   ```bash
   kubectl scale deployment longhorn-driver-deployer -n longhorn-system --replicas=1
   kubectl rollout status -n longhorn-system deployment/longhorn-driver-deployer
   ```
   - Validar: `longhorn-manager`, `csi-*` em Ready; `kubectl get lhn` (via CLI Longhorn) se disponível.

7. **Validar vClusters**
   ```bash
   vcluster list
   kubectl --context <vcluster-context> get pods -A
   ```

## Próximos Passos de Vigilância
- Capturar métricas de disco em um período prolongado (`iostat`, `sar -d`, Prometheus se disponível) para identificar padrões.
- Aplicar limites de requests/limits aos componentes oportunistas (ex.: pods de observabilidade) para evitar picos simultâneos.
- Considerar spool local para Longhorn backups ou desativar `backup cleanup-all-mounts` se não usado.

## Constatações de 29/10/2025 (19h-20h)
- **MetalLB**: `controller-6599cd9c46-kvh6s` e `speaker-7r5hx` (ambos em `marlon-tcc-vm3`) permanecem em `CrashLoopBackOff`. Os probes HTTP para `:7472/metrics` retornam `connection refused`, sugerindo que os bins não chegam a expor métricas antes do watchdog matar o processo (latência de disco ou kubelet indisponível). Tentativas de `kubectl logs` esbarram em `TLS handshake timeout` via `10250`, indicando saturação do kubelet na mesma máquina.
- **Ingress-NGINX**: réplica `ingress-nginx-controller-7cb459f86f-shfkt` (também em `marlon-tcc-vm3`) reinicia com frequência. Eventos mostram erros de reload (`invalid PID number "" em /tmp/nginx/nginx.pid`) e timeouts no healthz, consistentes com FS lento ou kubelet sem resposta.
- **Monitoring (kube-prometheus-stack)**: operator, kube-state-metrics, Grafana e Prometheus acusam `context deadline exceeded` nos probes, e o node-exporter registra `NodeNotReady` quando o kubelet do host não responde. Mesmo `kubectl describe` no operator experimenta timeout.
- **vClusters**: 
  - `vcluster-abc`: pod `abc-69465889f6-b5qpb` reiniciou 89 vezes nas últimas 18h.
  - `vcluster-shared`: pod `shared-5bfc7b6dd8-8mfr5` reiniciou 85 vezes.
  - `vcluster list` falha por timeout, presumivelmente pelo mesmo gargalo no API server/kubelet.
- **kubelet em marlon-tcc-vm3 (192.168.30.54)**: todas as requisições de logs via `https://192.168.30.54:10250/...` retornam `TLS handshake timeout`, o que reforça a hipótese de que o host está travando no I/O (etcd e outros componentes críticos residem nele).
- **Namespace vcluster-xyz**: estava travado em `Terminating` devido ao finalizer `controller.cattle.io/namespace-auth` (Rancher). Removido com `kubectl patch` e, em seguida, concluído forçadamente via `kubectl replace --raw "/api/v1/namespaces/vcluster-xyz/finalize" -f <manifest>`. Após a operação o namespace sumiu (`Error from server (NotFound)`), liberando o overlay antigo.

## Substituição do Longhorn (se necessário)
Manter o escopo do TCC requer persistência distribuída, suporte a PVCs e compatibilidade com workloads já planejados. Alternativas:

| Opção                     | Vantagens                                       | Observações / Passos Iniciais                           |
|---------------------------|-------------------------------------------------|----------------------------------------------------------|
| **OpenEBS (Jiva/Mayastor)** | Menos overhead, design para clusters pequenos  | Instalação via Helm; configurar StorageClasses equivalentes às do Longhorn. |
| **Rook + Ceph**           | Alta disponibilidade e replicação nativa       | Requer mais memória/CPU; ideal se puder dimensionar nós. |
| **Local Path Provisioner** | Simplicidade, usa disco local por nodo         | Não oferece replicação automática; adequado para labs.   |

### Estratégia de Migração (exemplo com OpenEBS Jiva)
1. `kubectl delete sc longhorn` (após migração) e criar `StorageClass` nova `openebs-jiva`.
2. Instalar OpenEBS:
   ```bash
   helm repo add openebs https://openebs.github.io/charts
   helm install openebs openebs/openebs --namespace openebs --create-namespace \
     --set jiva.enabled=true --set mayastor.enabled=false
   ```
3. Criar StorageClass com nome/parameters esperados pelas aplicações.
4. Para cada volume Longhorn existente (quando houver), efetuar backup/export (ex.: snapshot para NFS) e restaurar no novo backend.
5. Atualizar manifests (StatefulSets / PVCs) apontando para a nova StorageClass.

### Considerações
- Longhorn oferece UI e gerenciamento centralizado; se substituído por uma opção mais simples (Local Path), acrescentar documentação para operações rotineiras (backup manual, restauração).
- Garantir suporte a RWX se requerido pelos workloads; nem todas as alternativas disponibilizam RWX facilmente.
- Realizar testes de failover e restauração antes de cortar o Longhorn.

## Resumo de Comandos Executados Durante a Análise
- Diagnóstico de pods: `kubectl get pods -A`, `kubectl get pods -n metallb-system`, `kubectl get pods -n ingress-nginx`, `kubectl get pods -n monitoring`, `kubectl get pods -n vcluster-abc`, `kubectl get pods -n vcluster-shared`, `kubectl describe pod ...`.
- Eventos: `kubectl get events -A --sort-by=.lastTimestamp | tail`, `kubectl get events -n metallb-system --sort-by=.lastTimestamp`, `kubectl get events -n monitoring --sort-by=.lastTimestamp`.
- Métricas host: `kubectl debug node/... -- chroot /host top -bn1`, `df -h`, `du -sh /var/lib/etcd`.
- Longhorn logs: `kubectl logs -n longhorn-system longhorn-manager-5zncr`.
- Finalização forçada do namespace: `kubectl patch namespace vcluster-xyz --type=merge -p '{"metadata":{"finalizers":[]}}'`, `kubectl replace --raw "/api/v1/namespaces/vcluster-xyz/finalize" -f <manifest>`.
- Limpeza de pods de debug após cada execução (`kubectl delete pod node-debugger-...`).

## Recomendações Finais
1. Eliminar a causa raiz da latência de disco antes de reinstalar componentes opcionais.
2. Estabelecer rotina de manutenção do etcd (compactação/defrag) conforme tamanho (`etcdctl endpoint status` indica `DB Size`).
3. Automatizar coleta de métricas de I/O (Prometheus / node-exporter) para identificar rapidamente novos picos.
4. Validar continuamente ingress, MetalLB, Cilium e monitoring após cada ação, pois são essenciais para o funcionamento dos vClusters e do TCC.
5. Documentar, em caso de substituição do Longhorn, como os desenvolvedores e usuários acedem aos novos volumes e rotinas de backup.
