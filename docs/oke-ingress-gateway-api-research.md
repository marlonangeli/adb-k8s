# OKE ingress replacement research (2026-03-18)

## Why this is urgent

- Oracle OKE documentation now carries an explicit warning that the Kubernetes community announced that the NGINX Ingress Controller will stop receiving maintenance in March 2026.
- Existing deployments can continue working, but no new bug fixes or security updates are expected after that maintenance window.
- For this repository, continuing to depend on `ingress-nginx` on the OKE path increases deployment risk and weakens long-term supportability.

## Scope of this research

- Evaluate what to use instead of `ingress-nginx` on OKE, with focus on built-in or OKE-integrated options.
- Clarify current Gateway API status on OKE.
- Compare practical controller choices for `adb-k8s` migration from bare-metal assumptions (`MetalLB`, `sslip.io`, static local VIPs).

## Executive recommendation

1. Treat removal of `ingress-nginx` from the OKE path as a deployment blocker.
2. Use a two-phase migration strategy:
   - Phase 1 (fast risk reduction): move edge exposure to OKE native load balancer flows and replace `ingress-nginx` on OKE.
   - Phase 2 (target architecture): standardize on Kubernetes Gateway API.
3. For Gateway API on OKE, prioritize controllers in this order unless project constraints change:
   - Envoy Gateway (strong OKE guidance and conformance profile).
   - Istio add-on (Oracle-managed control-plane lifecycle, heavier footprint).
   - Traefik Gateway provider (viable with lower operational footprint, but narrower conformance breadth).

## What is built in or integrated with OKE

### Service `type: LoadBalancer` (OKE cloud integration)

- OKE provisions OCI LB/NLB from Kubernetes Services directly.
- This is the direct replacement for the old `MetalLB` responsibility.
- Supports OCI annotations for LB type, private/public mode, subnet, NSG handling, health checks, TLS options, shape, and reserved IPs.

### OCI Native Ingress Controller (first-party OKE ingress option)

- Implements Kubernetes `Ingress` resources and maps them to OCI load balancer configuration.
- Can run as an OKE add-on (recommended by Oracle docs for easier lifecycle handling).
- Supports host/path routing, TLS, health check tuning, NSG attachment, WAF policy attachment, and OCI certificate integration.

### Gateway API support in OKE

- OKE does not install Gateway API CRDs by default.
- OKE does not provide an always-on native Gateway API controller out of the box.
- Gateway API requires installing CRDs and running a controller implementation.
- Oracle provides OKE documentation paths for Envoy Gateway and Istio add-on Gateway API setups.

## Controller options for OKE (practical view)

| Option | API model | OKE integration level | Main strengths | Main caveats |
|---|---|---|---|---|
| OCI Native Ingress Controller | Ingress API | High (first-party, add-on capable) | Fast migration from Ingress manifests, OCI-native LB/WAF/cert integration | Not Gateway API contract |
| Envoy Gateway | Gateway API | Medium-High (Oracle documented) | Strong Gateway API alignment and conformance, clear OKE path | More moving parts than basic ingress |
| Istio add-on | Gateway API | High (Oracle-managed add-on lifecycle) | Managed control plane, advanced traffic features | Higher operational footprint |
| Traefik (Gateway provider) | Gateway API | Medium (self-managed on OKE) | Lower footprint, straightforward install, good migration path | Narrower conformance surface than Envoy/Istio |
| NGINX Gateway Fabric / Kong | Gateway API | Medium (self-managed) | Viable alternatives with active ecosystems | Extra operational complexity; less OKE-native guidance |

## Multi-tenant and vCluster considerations

- Sharing a single edge load balancer across many tenants can couple routing, certificate, and policy ownership.
- Stronger tenant isolation usually requires separate ingress or gateway boundaries (for example per `IngressClass`, `Gateway`, NSG scope, and certificate scope).
- Design should explicitly choose between cost efficiency (shared edge) and isolation strictness (segmented edge).

## Recommended migration path for `adb-k8s`

### Short-term (high priority)

- Stop introducing new `ingress-nginx` dependencies in OKE workflows.
- Remove OKE-path dependencies on `MetalLB` and `sslip.io` host conventions.
- Use OKE load balancer integration (`Service: LoadBalancer`) for external entry.

### Mid-term (target architecture)

- Adopt Gateway API resources (`GatewayClass`, `Gateway`, `HTTPRoute`) as the primary routing contract.
- Keep migration incremental: run old and new edge paths in parallel during cutover where possible.
- Prefer standard Gateway API channel for production-like environments; use experimental resources only with explicit acceptance of breaking-change risk.

## Implementation checklist (documentation and platform)

- [ ] Remove `ingress-nginx` as default ingress strategy in OKE docs and scripts.
- [ ] Remove `MetalLB` coupling from OKE path manifests and annotations.
- [ ] Replace `sslip.io` assumptions with real DNS strategy.
- [ ] Decide Gateway API controller for OKE path (Envoy, Istio add-on, or Traefik) and document the rationale.
- [ ] Add validation runbook for chosen ingress or gateway controller on OKE.
- [ ] Update readiness gates to require ingress migration completion before first reliable OKE deploy.

## Validation checklist (pre-cutover)

- [ ] `kubectl get svc -A` confirms expected OKE LB services and external addresses.
- [ ] `kubectl get ingress -A` (if using OCI Native Ingress) shows programmed resources.
- [ ] `kubectl get gatewayclass,gateway,httproute -A` (if using Gateway API) shows accepted and programmed resources.
- [ ] Tenant isolation tests pass for allowed and denied traffic paths.
- [ ] DNS resolution and TLS behavior match expected hostnames and certificates.

## Sources used in this research

- OKE ingress controller guidance and migration notice:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupingresscontroller.htm
- OCI Native Ingress Controller:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupnativeingresscontroller.htm
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupnativeingresscontroller-configuring.htm
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupnativeingresscontroller-addon-prereqs.htm
- OKE Gateway API setup references:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengworkingwithenvoygatewayforgatewayapi.htm
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengworkingwithistioaddonforgatewayapi.htm
- OKE load balancer behavior and annotations:
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancers-subtopic.htm
  - https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengconfiguringloadbalancersnetworkloadbalancers-subtopic.htm
- Gateway API standards and implementation comparisons:
  - https://gateway-api.sigs.k8s.io/concepts/versioning/
  - https://gateway-api.sigs.k8s.io/implementations/v1.4/
- Traefik Gateway API provider docs:
  - https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/
