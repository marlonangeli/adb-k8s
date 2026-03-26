# OKE Migration Phases Tracker

This file tracks execution phases for the OKE migration and hardening work.

## Current status

| Phase | Goal | Status | Notes |
|---|---|---|---|
| 0 | Baseline and commit current migration work | complete | OKE-first commits created across `adb-k8s`, `adb-api-3`, `adb-interpolation-api` |
| 1 | Validate core OKE path and tenant isolation baseline | complete | Kustomize checks + tenant isolation validator in place |
| 2 | Public exposure controls + operator guidance | complete | runbook + exposure toggles + reporting + audit published |
| 3 | Full script remediation and consistency cleanup | in_progress | preflight checks and OKE safety guards added |
| 4 | Controlled deployment and end-to-end verification | pending | execute in order and capture evidence |
| 5 | Public internet go-live hardening | pending | NSG/DNS/WAF/TLS final checks |

## Phase 0 - Completed

- Baseline OKE migration changes committed in:
  - `adb-k8s` (`e4d0fcd`)
  - `adb-api-3` (`4c59f9a`)
  - `adb-interpolation-api` (`63d2168`)

## Phase 1 - Completed

- Tenant/private routing model enforced in manifests.
- Shared interpolation aligned to OKE internal LB model.
- Validator added (`scripts/validate-tenant-routing-isolation.sh`) and documented.

## Phase 2 - Completed

### Completed in this phase

- Canonical operator runbook added: `docs/oke-operator-runbook.md`.
- OKE exposure toggles added per component (`env.sh` + platform scripts).
- Tenant validator improved with kubeconfig auto-discovery and clearer diagnostics.
- New exposure visibility tool added: `scripts/oke-exposure-report.sh`.

## Phase 3 - In Progress

### Completed in this phase

- Added preflight checker: `scripts/oke-preflight-check.sh` and `make preflight-oke`.
- Added `make deploy-oke` execution path with preflight gate.
- Added OKE safety guards to bare-metal bootstrap stages (`bin/10`, `bin/20`, `bin/30`, `bin/35`).
- Fixed Longhorn patch payload variable interpolation for OKE LB annotations.
- Extended runbook with helper scripts and deployment shortcuts.
- Added rollback snippets per OKE-active stage in `docs/oke-operator-runbook.md`.

### Remaining for phase completion

- Run live OKE evidence capture and close phase with deployment artifacts.

## Evidence commands per phase

```bash
cd /home/ilegna/Work/tcc/adb-k8s

# Phase 1 evidence
make validate-tenant-routing

# Phase 2 evidence
make report-oke-exposure

# Phase 3 evidence
make preflight-oke
```
