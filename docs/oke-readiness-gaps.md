# OKE Deployment Readiness Gaps

This document tracks what is still missing to configure and implement before a reliable deployment on Oracle OKE.

## Current state

- Repositories and target branches are aligned (`adb-k8s: oke`, `infra-oci: adb`, `adb-api-3: multi-tenant`, `adb-interpolation-api: kubernetes`).
- OKE migration direction is defined in `docs/oke-migration-decisions.md`.
- Canonical operator execution guide is `docs/oke-operator-runbook.md`.
- `kubectl` access works through mise execution:
  - `mise exec -- kubectl`
- Migration is still partial and should not be treated as production-ready yet.

## Critical blocker (updated 2026-03-18)

- `ingress-nginx` replacement on OKE is now a hard blocker for first reliable deployment.
- Oracle OKE ingress documentation now includes a warning that Kubernetes community maintenance for NGINX Ingress Controller stops in March 2026.
- Existing deployments may continue to run, but new bugfix/security updates are not expected after that maintenance window.

### Accepted replacement paths

1. OCI Native Ingress Controller (OKE-integrated, Ingress API).
2. Gateway API with a dedicated controller (Envoy Gateway, Istio add-on, or Traefik).

At least one path above must be selected, implemented, and validated before production-like rollout.

## Missing configuration work

1. Operator CLI baseline
   - Standardize cluster commands with `mise exec -- kubectl <args>` in runbooks and scripts.
   - Optionally define permanent shell integration for mise to avoid command-not-found after shell restart.

2. OCI provider and environment setup
   - Confirm required OCI values are consistently set (tenancy, user, fingerprint, key path, region).
   - Confirm API key and profile mapping used by OpenTofu/Terraform.

3. Infrastructure state validation
   - Run `tofu init -reconfigure` in `infra-oci/oracle-cloud/kubernetes`.
   - Run `tofu validate`.
   - Run `tofu plan -refresh-only` and review drift before any apply.

4. Kubernetes access validation
   - Verify active context and API connectivity.
   - Verify node readiness and system namespace health before platform/app deployment.

## Missing implementation work

1. Platform migration from bare-metal assumptions
    - Remove dependency on MetalLB in OKE path.
    - Remove dependency on Cilium kube-proxy-free mode in OKE path.
    - Replace `ingress-nginx` with an OKE-compatible ingress or gateway model as an urgent migration task.
    - Remove temporary host conventions (`sslip.io`) and move to real DNS for edge routing.
    - Install and validate Calico in policy-only mode for `NetworkPolicy` enforcement.

2. Storage and node preparation
   - Finalize Longhorn setup pattern for OKE nodes (including node init requirements).
   - Validate `StorageClass` and PVC behavior in the OKE environment.

3. Application manifest adaptation
    - Convert tenant Cilium policies to standard Kubernetes `NetworkPolicy` where required.
    - Remove bare-metal specific service annotations in app manifests.
    - Align route resources with the chosen edge strategy (`Ingress` with OCI native controller or `Gateway`/`HTTPRoute` with Gateway API controller).

4. GitOps and secrets readiness
   - Confirm Argo CD applications target OKE-compatible services/routes.
   - Ensure tenant/shared secrets management is ready for deployment (no placeholder values).

5. Security hardening
   - Review and reduce broad Security List/NSG exposure before public rollout.
   - Restrict API and NodePort exposure to minimum required sources.

## Preflight checks (required)

```bash
# Cluster access
mise exec -- kubectl config current-context
mise exec -- kubectl get nodes -o wide
mise exec -- kubectl get pods -A

# OKE preflight baseline
cd /home/ilegna/Work/tcc/adb-k8s
scripts/oke-preflight-check.sh

# Optional: use local writable runtime paths when /var/* is restricted
export STATE_DIR="$PWD/.state/cluster-state"
export LOG_FILE="$PWD/.state/cluster-install.log"
scripts/oke-preflight-check.sh

# Edge migration visibility
mise exec -- kubectl get ingressclass
mise exec -- kubectl get ingress -A
# Run the next command if Gateway API CRDs are installed
mise exec -- kubectl get gatewayclass,gateway,httproute -A

# Infra state
cd /home/ilegna/Work/tcc/infra-oci/oracle-cloud/kubernetes
tofu init -reconfigure
tofu validate
tofu plan -refresh-only

# Manifests
cd /home/ilegna/Work/tcc/adb-api-3
mise exec -- kubectl kustomize k8s/tenants/abc >/dev/null

cd /home/ilegna/Work/tcc/adb-interpolation-api
mise exec -- kubectl kustomize k8s/overlays/shared >/dev/null

# Tenant isolation baseline
scripts/validate-tenant-routing-isolation.sh

# Exposure visibility baseline
scripts/oke-exposure-report.sh
```

## Deployment order

1. Validate infra state and apply approved changes in `infra-oci`.
2. Validate cluster access/health with `mise exec -- kubectl`.
3. Deploy platform layer changes required for OKE compatibility (including ingress-nginx replacement).
4. Deploy shared interpolation service.
5. Deploy first tenant API and validate tenant isolation.
6. Expand to additional tenants after validation gates pass.

## Exit criteria for first reliable deploy

- Infra plan is reviewed and applied without unexpected destructive changes.
- Cluster access and core health checks are stable.
- Platform stack no longer depends on bare-metal-only components in OKE path.
- `ingress-nginx` is removed from the OKE deployment path and replacement ingress or gateway flow is validated.
- Shared and tenant services deploy successfully and pass smoke checks.
- Multi-tenant isolation checks pass (including `scripts/validate-tenant-routing-isolation.sh`).
- Exposure report confirms intended internal/public boundary (`scripts/oke-exposure-report.sh`).
