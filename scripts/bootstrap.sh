#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

echo "=== K3s Platform Bootstrap ==="

# 1. Instalar K3s (si no esta disponible)
if command -v k3s >/dev/null 2>&1 && [ -f "$KUBECONFIG" ] && kubectl get nodes >/dev/null 2>&1; then
  echo "[1/4] K3s ya esta corriendo y listo, saltando instalacion..."
else
  echo "[1/4] Instalando K3s..."
  bash "$PROJECT_DIR/cluster/bootstrap/install-k3s.sh"
fi

# 2. Esperar a que el cluster este listo
echo "[2/4] Esperando a que el cluster este listo..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# 3. Instalar addons del cluster
# Metrics Server no se instala: K3s ya lo incluye (ver cluster/addons/metrics-server/)
echo "[3/4] Instalando addons del cluster..."
kubectl apply -f "$PROJECT_DIR/cluster/addons/ingress-nginx/"
kubectl apply -f "$PROJECT_DIR/cluster/addons/cert-manager/cert-manager.yaml"
wait_for_crd clusterissuers.cert-manager.io
wait_for_deployment cert-manager cert-manager-webhook
kubectl apply -f "$PROJECT_DIR/cluster/addons/cert-manager/clusterissuer-selfsigned.yaml"

# 4. Instalar ArgoCD
echo "[4/4] Instalando ArgoCD..."
kubectl apply -f "$PROJECT_DIR/infrastructure/argocd/namespace.yaml"
kubectl apply -f "$PROJECT_DIR/infrastructure/argocd/installation.yaml"
wait_for_crd applications.argoproj.io
wait_for_deployment argocd argocd-server

echo ""
echo "=== Bootstrap completado ==="
echo "Usa el kubeconfig del lab:"
echo "  export KUBECONFIG=$KUBECONFIG"
echo ""
echo "Siguiente paso: bash scripts/deploy-infra.sh"
echo ""
echo "Password de admin de ArgoCD:"
echo '  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d'
