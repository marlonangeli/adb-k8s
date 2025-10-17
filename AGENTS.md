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
- Persisted state lives in `/var/opt/cluster-state`; inspect markers (`*.ok`) before forcing reruns. Delete intentionally only when re-provisioning from scratch.

## Review Checklist
- Confirme se o `CHANGELOG` foi atualizado com as mudanças relevantes antes de concluir uma entrega.
