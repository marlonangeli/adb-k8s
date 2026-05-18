# PLAN: Stabilized OKE Demo + Stress-Test Preparation

## Goal

Keep the OKE environment stable for TCC evidence and prepare the next iteration focused on stress tests and metrics collection.

## Current state (validated in this session)

### Applications

- `shared-interpolation` -> `Synced / Healthy`
- `tenant-abc-adb-api` -> `Synced / Healthy`

### Public endpoints

- Grafana -> `144.22.151.206`
- Argo CD -> `168.138.153.100`
- vCluster `shared` -> `147.15.124.246`
- vCluster `abc` -> `163.176.198.222`

### Cluster shape / cost guardrail

- OKE nodepool remains:
  - `2` nodes
  - `VM.Standard.A1.Flex`
  - `2 OCPU` per node
  - `12 GB RAM` per node
- No compute scale-up was applied.
- Main billing attention remains public LoadBalancers / public traffic, not node size/count.

---

## What changed in this recovery cycle

### Public access / control plane

- Grafana and Argo CD were reprovisioned to public LoadBalancers.
- vClusters `shared` and `abc` were moved to public endpoints.
- kubeconfigs under `.state/cluster-state/` were updated to public server URLs.
- Argo CD cluster secrets were rewritten to use:
  - `caData`
  - `certData`
  - `keyData`
  - `insecure=false`

### vCluster recovery

- vClusters temporarily lost internal scheduling/DNS after endpoint reprovision.
- Clean control-plane redeploys restored:
  - nodes
  - `kube-dns`
  - workload scheduling
- `abc` needed final manual restore of the virtual `kube-system/coredns` ConfigMap so DNS resolution inside the vCluster worked again.

### Storage / Longhorn

- Longhorn future default aligned to `2` replicas via new default StorageClass `longhorn-2`.
- Existing tenant DB volumes were reduced from `3` to `2` replicas and became `healthy`.

### Always Free tuning

- Prometheus live profile set to:
  - `PROMETHEUS_REQUEST_CPU=100m`
  - `PROMETHEUS_SCRAPE_INTERVAL=30s`
- Additional permanent reductions were applied in repo manifests/defaults for:
  - vCluster control planes/syncers
  - `adb-api`
  - tenant `postgres`
  - `adb-interpolation-api`
  - Grafana / Prometheus Operator / kube-state-metrics requests
- Temporary shedding used during recovery:
  - `argocd-dex-server=0`
  - `argocd-notifications-controller=0`
  - `kube-prometheus-stack-kube-state-metrics=0`
  - `longhorn-ui=0`
  - `kube-dns-autoscaler=0`
  - host `coredns=1`

### Registry auth

- Host-mapped GHCR pull secrets had to be recreated for vCluster namespaces after recovery.

---

## Current operators' checklist

### Quick health check

```bash
cd /home/ilegna/Work/tcc/adb-k8s
source ./env.sh
source ./secrets.env

mise exec -- kubectl -n argocd get applications -A
mise exec -- kubectl --kubeconfig .state/cluster-state/kubeconfig-abc.yaml -n app get pods
mise exec -- kubectl --kubeconfig .state/cluster-state/kubeconfig-shared.yaml -n processing get pods
```

### Exposure snapshot

```bash
cd /home/ilegna/Work/tcc/adb-k8s
source ./env.sh
source ./secrets.env

./scripts/oke-exposure-report.sh
```

### Public kubeconfig smoke check

```bash
cd /home/ilegna/Work/tcc/adb-k8s
source ./env.sh
source ./secrets.env

mise exec -- kubectl --kubeconfig .state/cluster-state/kubeconfig-abc.yaml get ns
mise exec -- kubectl --kubeconfig .state/cluster-state/kubeconfig-shared.yaml get ns
```

---

## Next execution tracks

### Track A — Final evidence refresh

- [ ] Re-run `make report-oke-exposure`
- [ ] Re-run `make validate-tenant-routing`
- [ ] Save Argo/public endpoint snapshots for the TCC appendix

### Track B — Stress-test preparation

- [ ] Confirm which temporary shed components can stay disabled during tests
- [ ] Capture baseline CPU/pod usage before load
- [ ] Review HPA targets and thresholds for `adb-api` and shared interpolation
- [ ] Prepare Prometheus/Grafana panels and PromQL queries for evidence

### Track C — Stress execution

- [ ] Start with light ramp tests
- [ ] Increase gradually while watching:
  - `kubectl top`
  - Grafana dashboards
  - Argo app health
  - node pod pressure
- [ ] Stop if tenant apps leave `Healthy`

### Track D — Future architecture work

- [ ] Implement public host-routing edge for `adb-api.<tenant>.<domain>` without exposing tenant backends directly
- [ ] Apply reviewed DNS names via OpenTofu only after evidence phase is complete

---

## Main risks to remember

1. **vCluster control plane is still ephemeral**
   - rolling/recreating a control plane can drop internal objects like `coredns` and require GitOps repopulation

2. **Always Free headroom is narrow**
   - avoid re-enabling optional components all at once before load testing

3. **Public vCluster endpoint changes require Argo follow-up**
   - kubeconfig updates
   - cluster secret updates
   - controller restart if cache gets stale

4. **Public LoadBalancers may affect OCI billing even if compute stays Always Free**

---

## Recommended next commands

```bash
cd /home/ilegna/Work/tcc/adb-k8s
source ./env.sh
source ./secrets.env

mise exec -- kubectl -n argocd get applications -A
make report-oke-exposure
make validate-tenant-routing
```
