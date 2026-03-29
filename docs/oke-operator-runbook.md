# OKE Operator Runbook (Step by Step)

This is the canonical operator guide for running the `adb-k8s` OKE flow.

Phase status is tracked in `docs/oke-phases.md`.

## 1) What this runbook covers

- How to prepare OCI/OKE and local workstation.
- Which scripts to run, in order.
- How to validate tenant isolation and shared interpolation access.
- How to expose selected services to the public internet safely.
- Where each Oracle Cloud Console configuration lives.

## 2) Current architecture defaults

- `PLATFORM_MODE=oke` (default in `env.sh`).
- Legacy bare-metal stages (`metallb`, `ingress-nginx`, `rancher`) are disabled in OKE mode.
- Argo CD, Grafana, and Longhorn are exposed through OCI load balancers with **internal** access by default.
- Tenant `adb-api-3` remains private inside each vCluster.
- `adb-interpolation-api` is shared and exposed through the shared path.

## 3) OCI Console prerequisites

### 3.1 OKE cluster and access

1. OCI Console: `Developer Services -> Containers & Artifacts -> Kubernetes Clusters (OKE)`.
2. Create or open your target cluster.
3. In cluster page: `Actions -> Access cluster`.
4. Generate/access kubeconfig and validate with:

```bash
mise exec -- kubectl get nodes -o wide
```

### 3.2 OKE add-ons (if needed)

1. OCI Console: `Kubernetes Clusters -> <cluster> -> Add-ons`.
2. Configure add-ons required by your chosen ingress/gateway strategy.

### 3.3 Networking and security

1. OCI Console: `Networking -> Virtual Cloud Networks -> <VCN> -> Network Security Groups`.
2. Prefer NSGs over Security Lists.
3. For any public endpoint, review ingress CIDRs and ports explicitly.

### 3.4 DNS

1. OCI Console: `Networking -> DNS management -> Zones`.
2. Create/update records only after confirming public LB/NLB endpoints.

### 3.5 Optional WAF for public endpoints

1. OCI Console: `Identity & Security -> Web Application Firewall -> Policies`.
2. If enabled, point DNS to WAF endpoint and restrict origin ingress accordingly.

## 4) Local prerequisites

Run from `adb-k8s` repository root.

1. Ensure `mise`, `kubectl`, `helm`, and `vcluster` are available.
2. Create `secrets.env` from `secrets.env.example` and fill required values.
3. Verify cluster connectivity:

```bash
mise exec -- kubectl config current-context
mise exec -- kubectl get nodes
mise exec -- kubectl get pods -A
```

4. Run preflight checks before install stages:

```bash
cd /home/ilegna/Work/tcc/adb-k8s
make preflight-oke
```

Default runtime paths are local to the repository (`<repo>/.state/...`).

If you need custom paths, set writable overrides before running stages:

```bash
cd /home/ilegna/Work/tcc/adb-k8s
export STATE_DIR="$PWD/.state/cluster-state"
export LOG_FILE="$PWD/.state/cluster-install.log"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
make preflight-oke
```

If `helm` or `vcluster` are missing, runtime helpers can auto-install them. When `/usr/local/bin` is not writable, binaries are installed into `~/.local/bin`.

## 5) Configure OKE exposure behavior in env.sh

`env.sh` now exposes these knobs:

- Global defaults:
  - `OKE_LB_TYPE_DEFAULT` (`nlb` by default)
  - `OKE_LB_INTERNAL_DEFAULT` (`true` by default)
  - `OKE_LB_SECURITY_RULE_MODE` (`NSG` by default)
- Component-specific overrides:
  - `ARGOCD_LB_TYPE`, `ARGOCD_LB_INTERNAL`, `ARGOCD_LB_SECURITY_RULE_MODE`
  - `GRAFANA_LB_TYPE`, `GRAFANA_LB_INTERNAL`, `GRAFANA_LB_SECURITY_RULE_MODE`
  - `LONGHORN_LB_TYPE`, `LONGHORN_LB_INTERNAL`, `LONGHORN_LB_SECURITY_RULE_MODE`

Safe default for first deploy: keep all `*_LB_INTERNAL=true`.

## 6) Execution order (scripts/commands)

From `/home/ilegna/Work/tcc/adb-k8s`:

Do not use bare-metal provisioning stages for OKE cluster creation (`10`, `20`, `30`, `35`). The OKE cluster is provisioned by OCI + IaC, not kubeadm on local VMs.

1. Optional cert-manager stage:

```bash
bin/55-cert-manager.sh
```

To execute the full OKE flow in one command sequence:

```bash
cd /home/ilegna/Work/tcc/adb-k8s
make deploy-oke
```

2. Observability (Prometheus/Grafana):

```bash
bin/70-observability.sh
```

3. Longhorn:

```bash
bin/80-longhorn.sh
```

4. vClusters:

```bash
bin/90-vcluster.sh
```

Important: `bin/90-vcluster.sh` prompts manual execution of `scripts/vcluster/create.sh` commands for each cluster. Execute the printed command in another terminal, then return and press Enter.

If you prefer automatic execution in the same terminal:

```bash
export VC_MANUAL_EXECUTION=0
bin/90-vcluster.sh
```

In non-interactive terminals, keep `VC_MANUAL_EXECUTION=0` to avoid prompt failures.

5. Argo CD:

```bash
bin/95-argocd.sh
```

### 6.1 Script map (OKE)

| Script | Use in OKE | Notes |
|---|---|---|
| `bin/10-so-requirements.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/20-kubeadm-init.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/30-cilium.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/35-join-workers.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/40-metallb.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/50-ingress-nginx.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/55-cert-manager.sh` | Optional | Use when TLS automation is required |
| `bin/60-rancher.sh` | Auto-skip | Disabled when `PLATFORM_MODE=oke` |
| `bin/70-observability.sh` | Yes | Installs Prometheus/Grafana |
| `bin/80-longhorn.sh` | Yes | Installs Longhorn and patches service for OKE |
| `bin/90-vcluster.sh` | Yes | Creates/updates vClusters (manual command checkpoint) |
| `bin/95-argocd.sh` | Yes | Installs Argo CD and registers clusters/apps |

### 6.2 Helper scripts (OKE)

| Script | Use in OKE | Notes |
|---|---|---|
| `scripts/oke-preflight-check.sh` | Yes | Preflight validation before deployment |
| `scripts/validate-tenant-routing-isolation.sh` | Yes | Tenant isolation and shared routing validation |
| `scripts/oke-exposure-report.sh` | Yes | Internal/public exposure report |

## 7) Where runtime state is stored

- State dir (default): `<repo>/.state/cluster-state`
- Dynamic vars (default): `<repo>/.state/cluster-state/dynamic.env`
- vCluster kubeconfigs (default): `<repo>/.state/cluster-state/kubeconfig-<cluster>.yaml`

If this directory does not exist, the relevant stages were not run yet (or ran on another host/user context).

`STATE_DIR` and `LOG_FILE` are overridable through environment variables.

## 8) Validate deployment and tenant routing

### 8.1 Manifest rendering checks

```bash
cd /home/ilegna/Work/tcc/adb-api-3
mise exec -- kubectl kustomize k8s/tenants/abc >/dev/null

cd /home/ilegna/Work/tcc/adb-interpolation-api
mise exec -- kubectl kustomize k8s/overlays/shared >/dev/null
```

### 8.2 Tenant isolation baseline

```bash
cd /home/ilegna/Work/tcc/adb-k8s
make validate-tenant-routing
```

### 8.3 Exposure visibility baseline

```bash
cd /home/ilegna/Work/tcc/adb-k8s
make report-oke-exposure
```

This report shows current `LoadBalancer` services as `INTERNAL` or `PUBLIC`, plus ingress and Gateway API resources.

The validator auto-detects tenant kubeconfigs from `VCLUSTER_TENANTS`/state files and supports explicit overrides.

Examples:

```bash
scripts/validate-tenant-routing-isolation.sh \
  --tenant-a-name tenant-a \
  --tenant-b-name tenant-b
```

```bash
scripts/validate-tenant-routing-isolation.sh \
  --tenant-a-kubeconfig .state/cluster-state/kubeconfig-tenant-a.yaml \
  --tenant-b-kubeconfig .state/cluster-state/kubeconfig-tenant-b.yaml \
  --shared-kubeconfig .state/cluster-state/kubeconfig-shared.yaml
```

## 9) Public internet exposure (controlled)

Use this only after internal validation passes.

### 9.1 Decide which components become public

Examples:

- Public Argo CD only:
  - `ARGOCD_LB_INTERNAL=false`
- Public Grafana only:
  - `GRAFANA_LB_INTERNAL=false`
- Public Longhorn only:
  - `LONGHORN_LB_INTERNAL=false`

### 9.2 Apply component changes

Rerun only the corresponding stage after changing variables.

```bash
bin/95-argocd.sh
bin/70-observability.sh
bin/80-longhorn.sh
```

### 9.3 Confirm endpoint in OCI Console

1. OCI Console: `Networking -> Load Balancers` and `Networking -> Network Load Balancers`.
2. Confirm listener and backend health.
3. Confirm NSG rules for expected ingress ports (typically 80/443).

### 9.4 DNS record update

1. OCI Console: `Networking -> DNS management -> Zones -> <zone> -> Records`.
2. Create/update `A` or `CNAME` for the chosen endpoint.

### 9.5 Optional WAF

1. OCI Console: `Identity & Security -> Web Application Firewall -> Policies`.
2. Attach WAF and update DNS to the WAF endpoint.
3. Restrict origin LB ingress to WAF ranges.

## 10) Rollback and recovery snippets

Use these snippets to revert specific OKE stages safely.

### 10.1 Revert public exposure to internal

Set the component back to internal and rerun only that stage:

```bash
cd /home/ilegna/Work/tcc/adb-k8s

export ARGOCD_LB_INTERNAL=true
bin/95-argocd.sh

export GRAFANA_LB_INTERNAL=true
bin/70-observability.sh

export LONGHORN_LB_INTERNAL=true
bin/80-longhorn.sh
```

### 10.2 Remove a tenant or shared vCluster

```bash
cd /home/ilegna/Work/tcc/adb-k8s
scripts/vcluster/remove.sh --cluster tenant-a
scripts/vcluster/remove.sh --cluster shared
```

### 10.3 Reapply Argo CD stage

```bash
cd /home/ilegna/Work/tcc/adb-k8s
bin/95-argocd.sh
```

### 10.4 Reapply observability/Longhorn stages

```bash
cd /home/ilegna/Work/tcc/adb-k8s
bin/70-observability.sh
bin/80-longhorn.sh
```

## 11) Troubleshooting quick notes

### Error: kubeconfig not found in `.state/cluster-state`

- Cause: vCluster stages were not executed on this host/context, or cluster names differ.
- Action:

```bash
ls -lah .state/cluster-state
cat .state/cluster-state/dynamic.env
```

Then run validator with explicit kubeconfig paths if needed.

### Error: permission denied for `STATE_DIR` or `LOG_FILE`

- Cause: current user cannot write to configured `STATE_DIR` or `LOG_FILE`.
- Recommended fix (no sudo workflow):

```bash
cd /home/ilegna/Work/tcc/adb-k8s
export STATE_DIR="$PWD/.state/cluster-state"
export LOG_FILE="$PWD/.state/cluster-install.log"
mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"
make preflight-oke
```

The preflight now fails early when these paths are not writable.

### Error: observability fails on `crds/*.yaml`

- Cause: chart CRD path may be empty/changed for the pulled chart version.
- Current behavior: script now tries fallback using `helm show crds` before failing.
- Action: rerun `bin/70-observability.sh`; if it still fails, capture output and verify chart version/repository availability.

### Service pending external endpoint

- Check OCI LB/NLB provisioning and subnet/NSG constraints.
- Confirm annotation values and security-rule mode (`NSG`).

### Service `LoadBalancer` pending with `NotAuthorizedOrNotFound` on `CreateNetworkSecurityGroup`

- Symptom (from `kubectl describe svc ...` events):
  - `SyncLoadBalancerFailed`
  - `Operation Name: CreateNetworkSecurityGroup`
  - `Error Code: NotAuthorizedOrNotFound`

- Meaning:
  - OKE cloud-controller is trying to manage NSGs for the service, but IAM/network scope is not allowing it in current compartment/subnet context.

- Resolution path A (recommended): keep NSG mode and fix OCI IAM/network permissions.
  - Verify OKE dynamic group/policies can manage NSGs and LB/NLB in the target compartment.
  - Verify referenced subnet/compartment exists and is accessible to cluster policies.

- Resolution path B (temporary fallback): use Security List mode.

```bash
cd /home/ilegna/Work/tcc/adb-k8s
export OKE_LB_SECURITY_RULE_MODE="SL-All"
export GRAFANA_LB_SECURITY_RULE_MODE="SL-All"
export LONGHORN_LB_SECURITY_RULE_MODE="SL-All"
export ARGOCD_LB_SECURITY_RULE_MODE="SL-All"
```

Then rerun the affected stage(s):

```bash
bin/70-observability.sh
bin/80-longhorn.sh
bin/95-argocd.sh
```

### Public endpoint inaccessible

- Validate NSG ingress rules and source CIDRs.
- Confirm DNS points to current LB/NLB endpoint.
- If WAF is enabled, verify origin is not bypassed and policy is attached.

## 12) Source references

- OKE create/access: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/create-cluster.htm
- OKE kubeconfig access: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengdownloadkubeconfigfile.htm
- OKE LB/NLB annotations and security mode: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm
- OKE LB creation behavior: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancers-subtopic.htm
- OKE NLB behavior: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingnetworkloadbalancers.htm
- OCI DNS zones/records: https://docs.oracle.com/en-us/iaas/Content/DNS/Concepts/gettingstarted_topic-Creating_a_Zone.htm
- OCI WAF: https://docs.oracle.com/en-us/iaas/Content/WAF/Concepts/gettingstarted.htm
