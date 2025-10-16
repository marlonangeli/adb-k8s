#!/bin/bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
need_root

STEP="so-reqs"
donep "${STEP}" && { log "skip ${STEP}"; exit 0; }

apt update && apt -y upgrade
apt -y install ca-certificates curl gnupg lsb-release jq \
               kmod procps iptables arptables ebtables ethtool \
               conntrack iproute2 open-iscsi nfs-common
systemctl enable --now iscsid

swapoff -a
sed -ri 's/^\s*([^#]\S+\s+\S+\s+swap\s+\S+.*)$/#\1/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<'EOF'
br_netfilter
EOF
cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 10485760
EOF
modprobe br_netfilter
sysctl --system

apt -y install containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -ri 's/^(\s*)SystemdCgroup\s*=\s*false/\1SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

# kube tools 1.34
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt update && apt -y install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# kubelet ulimits
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/20-ulimits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload

ok "${STEP}"
