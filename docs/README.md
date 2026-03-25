# Documentation Index

This file centralizes project references used in the TCC migration from bare-metal Kubernetes to Oracle OKE.

## Critical migration alert (2026-03)

- `ingress-nginx` on the OKE path is now a high-priority migration risk due to the announced maintenance stop in March 2026.
- Read `docs/oke-ingress-gateway-api-research.md` before making new ingress-related changes.
- Treat ingress replacement as a readiness blocker for first reliable OKE deployment.

## Related repositories

| Repository | Focus | Active branch | Main references |
|---|---|---|---|
| `adb-k8s` | Bare-metal automation, vCluster and GitOps orchestration | `oke` | `README.md`, `docs/oke-ingress-gateway-api-research.md`, `docs/oke-migration-decisions.md`, `docs/testing-guidelines.md` |
| `adb-api-3` | Data API (Spring Boot), tenant overlays and tenant-specific configs | `multi-tenant` | `README.md`, `docs/multi-tenant-summary.md`, `k8s/README.md` |
| `adb-interpolation-api` | Shared interpolation API deployed in shared vCluster | `kubernetes` | `README.md`, `k8s/base/*`, `k8s/overlays/shared/*` |
| `infra-oci` | Terraform/OpenTofu infrastructure for Oracle Cloud and OKE | `adb` | `oracle-cloud/README.md`, `oracle-cloud/kubernetes/README.md` |

## Core docs in this repository

- `README.md`: bare-metal platform overview, provisioning flow, topology and operations.
- `CHANGELOG`: timeline of operational and architectural changes.
- `scripts/validate-tenant-routing-isolation.sh`: operational validation script for tenant isolation and shared interpolation routing on OKE.
- `docs/oke-ingress-gateway-api-research.md`: deep research and recommendation for replacing `ingress-nginx` on OKE with OKE-integrated alternatives and Gateway API paths.
- `docs/oke-migration-decisions.md`: target decisions to adapt the stack to OKE.
- `docs/oke-readiness-gaps.md`: missing configuration and implementation items before reliable OKE deployment.
- `docs/testing-guidelines.md`: test strategy, observability and validation checklist.
- `docs/checkpoints/2025-10-19.md`: baseline checkpoint from the bare-metal stage.
- `docs/checkpoints/2026-03-03.md`: consolidated migration status and next actions.
- `docs/cluster-stability-incident-2025-10-29.md`: incident analysis and mitigation notes.

## External documentation references

- OCI Terraform provider/environment configuration:
  - https://docs.oracle.com/en-us/iaas/Content/dev/terraform/configuring.htm#environment-variables
- OCI user profile API public key setup:
  - https://docs.oracle.com/en-us/iaas/private-cloud-appliance/pca/adding-an-api-public-key-to-a-user-profile.htm#adding-an-api-public-key-to-a-user-profile
- OKE version/support notes:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutk8sversions.htm#supportedk8sversions
- OKE ingress controller guidance and migration notice:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupingresscontroller.htm
- OKE native ingress controller:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupnativeingresscontroller.htm
- OKE Gateway API references:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengworkingwithenvoygatewayforgatewayapi.htm
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengworkingwithistioaddonforgatewayapi.htm

## Suggested reading order

1. Read `docs/oke-ingress-gateway-api-research.md` for ingress replacement priority and options.
2. Read `docs/oke-readiness-gaps.md` for updated blockers and execution gates.
3. Read `docs/checkpoints/2026-03-03.md` for migration context and timeline.
4. Read `docs/oke-migration-decisions.md` for target architecture decisions.
5. Read `infra-oci/oracle-cloud/kubernetes/README.md` in `infra-oci` before running Terraform/OpenTofu.
6. Read `adb-api-3/docs/multi-tenant-summary.md` and `adb-interpolation-api/README.md` to align app deployment expectations.
