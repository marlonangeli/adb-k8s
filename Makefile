SHELL := /bin/bash

all: cert-manager observability longhorn vcluster argocd

so-requirements:
	@bin/10-so-requirements.sh

init-cp:
	@bin/20-kubeadm-init.sh

cilium:
	@bin/30-cilium.sh

workers:
	@bin/35-join-workers.sh

metallb:
	@bin/40-metallb.sh

ingress:
	@bin/50-ingress-nginx.sh

cert-manager:
	@bin/55-cert-manager.sh

rancher:
	@bin/60-rancher.sh

observability:
	@bin/70-observability.sh

longhorn:
	@bin/80-longhorn.sh

vcluster:
	@bin/90-vcluster.sh

argocd:
	@bin/95-argocd.sh

validate-tenant-routing:
	@scripts/validate-tenant-routing-isolation.sh
