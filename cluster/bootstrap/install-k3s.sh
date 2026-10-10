#!/bin/bash
set -euo pipefail

# Kubeconfig dedicado al lab: no pisa ~/.kube/config (otros clusters)
K3S_KUBECONFIG="${K3S_KUBECONFIG:-$HOME/.kube/config-k3s}"

echo "=== Instalando K3s ==="
curl -sfL https://get.k3s.io | sh -

echo "=== Verificando instalacion ==="
sudo k3s kubectl get nodes

echo "=== Configurando kubeconfig en $K3S_KUBECONFIG ==="
mkdir -p "$(dirname "$K3S_KUBECONFIG")"
sudo cp /etc/rancher/k3s/k3s.yaml "$K3S_KUBECONFIG"
sudo chown "$(id -u):$(id -g)" "$K3S_KUBECONFIG"
chmod 600 "$K3S_KUBECONFIG"

echo "=== K3s instalado correctamente ==="
echo "Para usar kubectl con el lab: export KUBECONFIG=$K3S_KUBECONFIG"
