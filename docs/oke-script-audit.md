# OKE Script Audit

This document records OKE compatibility status for every shell script in `adb-k8s`.

## Summary

- OKE-active scripts are documented with execution order in `docs/oke-operator-runbook.md`.
- Legacy bare-metal scripts remain in repository but are not part of the OKE execution path.
- OKE guards are in place to auto-skip known legacy stages in `PLATFORM_MODE=oke`.

## `bin/` scripts

| Script | OKE status | Action |
|---|---|---|
| `bin/10-so-requirements.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/20-kubeadm-init.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/30-cilium.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/35-join-workers.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/40-metallb.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/50-ingress-nginx.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/55-cert-manager.sh` | OKE-active (optional) | Use for TLS issuer automation; ACME class now OKE-aware |
| `bin/60-rancher.sh` | guarded | Auto-skip in `PLATFORM_MODE=oke` |
| `bin/70-observability.sh` | OKE-active | Deploys Grafana/Prometheus with OKE LB annotation controls |
| `bin/80-longhorn.sh` | OKE-active | Deploys Longhorn and patches service for OKE LB exposure |
| `bin/90-vcluster.sh` | OKE-active | Creates/upgrades tenant/shared vClusters (manual checkpoint flow) |
| `bin/95-argocd.sh` | OKE-active | Installs Argo CD and registers tenant/shared clusters |
| `bin/lib.sh` | OKE-active helper | Shared utilities, dynamic env and state management |
| `bin/remove-rancher.sh` | maintenance-only | Legacy cleanup utility; not required in OKE path |
| `bin/run-on-nodes.sh` | legacy (bare-metal ops) | Not part of OKE operator runbook |

## `scripts/` scripts

| Script | OKE status | Action |
|---|---|---|
| `scripts/install-cli-deps.sh` | optional host bootstrap | Use only if you need local/root CLI bootstrap |
| `scripts/scan-ips-30.sh` | legacy network helper | Not used in OKE path |
| `scripts/worker-join.sh` | legacy (bare-metal) | Not used in OKE path |
| `scripts/oke-preflight-check.sh` | OKE-active | Preflight checks before deployment stages |
| `scripts/validate-tenant-routing-isolation.sh` | OKE-active | Baseline tenant isolation/shared access validation |
| `scripts/oke-exposure-report.sh` | OKE-active | Reports internal/public LB exposure + ingress/gateway visibility |
| `scripts/vcluster/common.sh` | OKE-active | Shared OKE-aware vCluster defaults and overlay generation |
| `scripts/vcluster/create.sh` | OKE-active | Creates/updates vCluster and writes kubeconfigs/state |
| `scripts/vcluster/remove.sh` | OKE-active | Removes vCluster and state artifacts |
| `scripts/vcluster/prompt.sh` | optional UX helper | Shows current kubectl context in shell prompt |

## Fixes applied in current phase

- Cert-manager ACME ingress class default now follows OKE mode (`native-oci`) instead of forcing `nginx` when not explicitly set.
- Tenant validator no longer assumes `abc/xyz`; it auto-discovers tenant kubeconfigs and shows diagnostics when state is missing.
- Exposure controls are now configurable by component (`ARGOCD_*`, `GRAFANA_*`, `LONGHORN_*`) through `env.sh`.
- Bare-metal bootstrap stages (`10`, `20`, `30`, `35`) now auto-skip in `PLATFORM_MODE=oke` to avoid accidental execution.
- Longhorn service patch now expands OKE LB variables correctly in JSON payload.

## Next hardening targets (Phase 4)

- Capture live deployment evidence from a real OKE run (preflight, exposure report, tenant validation, NSG verification in OCI Console).
