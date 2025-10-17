SHELL := /bin/bash

all: init-cp cilium metallb ingress cert-manager rancher observability longhorn vcluster

so-requirements:
	@bin/10-so-requirements.sh

init-cp:
	@bin/20-kubeadm-init.sh

cilium:
	@bin/30-cilium.sh

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
