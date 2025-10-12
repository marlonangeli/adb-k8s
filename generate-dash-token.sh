#!/bin/bash

NS=kubernetes-dashboard
SA=dashboard-admin
CTX=$(kubectl config current-context)
CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")
SERVER=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$CLUSTER\")].cluster.server}")
CA_DATA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$CLUSTER\")].cluster.certificate-authority-data}")
TOKEN=$(kubectl -n $NS create token $SA --duration=24h)

cat > dashboard-admin.kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
  name: k8s
contexts:
- context:
    cluster: k8s
    user: $SA
  name: $SA@k8s
current-context: $SA@k8s
users:
- name: $SA
  user:
    token: $TOKEN
EOF


echo "======================================================================="
echo "=========================== TOKEN GERADO =============================="
echo "======================================================================="

echo $TOKEN

echo ""
