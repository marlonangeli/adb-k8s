# Repository Guidelines

## Project Structure & Module Organization
- `env.sh` centralizes static inventory (IPs, SSH defaults) while runtime secrets go in `secrets.env` (copy from `secrets.env.example`).
- `bin/` contains idempotent automation stages (`10-...` through `90-...`) plus shared helpers in `lib.sh` and the remote orchestrator `run-on-nodes.sh`.
- `manifests/` stores Kubernetes templates rendered with `envsubst`; additional Cilium policies live under `manifests/cnp/`.
- Legacy YAMLs are parked in `old/` for reference; do not modify unless migrating history.

## Build, Test, and Development Commands
- `bash -n bin/*.sh` — quick syntax check for all automation scripts (run before committing).
- `make <target>` — wrapper for the stage scripts (e.g., `make cilium`, `make longhorn`); the order mirrors the numbered `bin/` files.
- `bin/run-on-nodes.sh <script>` — sync repository to remote nodes via `ssh utfpr@host` and execute scripts after `su -`.

## Coding Style & Naming Conventions
- Shell scripts use `bash` with `set -Eeuo pipefail`; keep functions lowercase with hyphen-separated filenames (e.g., `80-longhorn.sh`).
- Prefer helpers in `bin/lib.sh` (`log`, `save_state_var`, `resolve_hostname`) instead of duplicating logic.
- Templates in `manifests/` should rely on environment variables exported in `env.sh`; avoid hard-coded IPs or credentials.

## Testing Guidelines
- Smoke tests are CLI-based: validate deployments with `kubectl get nodes`, `cilium status`, and `kubectl get ingress -A`.
- When adding scripts, include a `donep` marker to guarantee idempotency and exercise them in a non-production sandbox before merging.
- For ingress-dependent components, confirm `${STATE_DIR}/dynamic.env` updates as expected.

## Commit & Pull Request Guidelines
- Follow the pragmatic, descriptive style already in history (e.g., “Refactor bare-metal cluster automation”): imperative mood, concise scope.
- Each PR should summarize the change, list affected scripts/manifests, and include manual verification steps (e.g., commands run, sample outputs).
- Link related tickets/issues where applicable and call out any backward-incompatible changes (such as new environment variables).

## Security & Configuration Tips
- Never commit real credentials; keep sensitive data in `secrets.env`, which is git-ignored.
- Scripts assume login as `utfpr` followed by `su -`; ensure you can escalate before running automation remotely.
- Persisted state lives in `${STATE_DIR}` (default: `<repo>/.state/cluster-state`); inspect markers (`*.ok`) before forcing reruns. Delete intentionally only when re-provisioning from scratch.

## Review Checklist
- Confirme se o `CHANGELOG` foi atualizado com as mudanças relevantes antes de concluir uma entrega.

## Operational Constraints
- Trabalhe sempre sem `sudo`; qualquer automação deve assumir privilégios limitados e solicitar ao usuário ações manuais que exijam root.
- O acesso de rede é restrito durante automações locais; para diagnosticar o cluster, peça ao usuário a saída de `kubectl` ou `cilium` quando necessário.
- A árvore git pode conter alterações pré-existentes (por exemplo, `Makefile`, `README.md`); não reverta nada sem instrução explícita.
- Evite instalar componentes extras de monitoramento: o ambiente já executa Prometheus/Grafana, e o control-plane opera com memória apertada (~92% em carga recente).

## Cluster Topology & Tooling
- Cluster bare-metal/VM com `marlon-tcc-vm1` (control-plane) e trabalhadores `marlon-tcc-vm2`/`marlon-tcc-vm3`; sempre adicione workers antes de etapas que exigem workloads distribuídos (ex.: MetalLB).
- Rede: Cilium (v1.18.x) substitui kube-proxy; Hubble Relay/UI exigem tolerations para agendar em nó control-plane.
- Storage e ingress: Longhorn provê blocos; MetalLB anuncia IPs (pool atual termina em `.100`); ingress-nginx faz o roteamento L7.
- Cert-manager roda apenas com emissores internos (sem domínio público); preferir fluxos `--no-cacerts`/self-signed ou desabilitar integrações que dependem de ACME externo.
- Scripts principais em `bin/` seguem a numeração de estágios (`10` requisitos SO, `20` container runtime, `30` Cilium, … `90` vcluster). Use `bin/run-on-nodes.sh` para orquestrar execuções remotas.

## TCC & vCluster Objectives
- Tema do TCC: plataforma multi-tenant baseada em `vCluster` onde cada tenant gerencia sua API de dados e banco apenas dentro do vCluster dedicado.
- O tráfego intra-tenant (API de dados/banco) deve permanecer privado, roteado por balanceador que conhece mapas de tenants; exposição de dados só via serviços internos do vCluster.
- A API de interpolação de dados reside em cada vCluster, porém permite acesso federado entre tenants com balanceamento descentralizado.
- Valide qualquer mudança de arquitetura/suporte com o usuário antes de alterar fluxos críticos do tenant e do balanceador.

## Active Focus Areas
- Scripts `bin/30-cilium.sh`, `bin/55-cert-manager.sh`, `bin/60-rancher.sh`, `bin/remove-rancher.sh` e `bin/90-vcluster.sh` são priorizados; mantenha sua idempotência (`donep`) e trate saídas `kubectl` falhas.
- Rancher instala agora sem Fleet nem telemetria (variáveis `RANCHER_ENABLE_FLEET=1` e/ou `RANCHER_ENABLE_TELEMETRY=1` reativam); avalie impactos antes de reabilitar para preservar recursos.
- Para limpeza do Rancher, forçar deleções via `kubectl replace --raw ".../finalize"` pode ser necessário para namespaces `cattle-*`, `fleet-*`, `local`, `p-*`, `user-*`; documente comandos de recuperação usados.
- Commits só devem ser criados quando o usuário ordenar explicitamente; caso contrário, deixe mudanças no workspace e descreva os passos para validação manual.
