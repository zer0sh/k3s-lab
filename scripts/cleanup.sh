#!/bin/bash
set -euo pipefail

echo "=== Limpieza del entorno K3s ==="
read -p "Esto eliminara K3s y todos los recursos. Continuar? (y/N): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Cancelado."
  exit 0
fi

echo "[1/2] Desinstalando K3s..."
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  /usr/local/bin/k3s-uninstall.sh
else
  echo "K3s no encontrado, saltando..."
fi

# Solo el kubeconfig del lab; ~/.kube/config (otros clusters) no se toca
K3S_KUBECONFIG="${K3S_KUBECONFIG:-$HOME/.kube/config-k3s}"
echo "[2/2] Limpiando kubeconfig del lab ($K3S_KUBECONFIG)..."
rm -f "$K3S_KUBECONFIG"

echo "=== Limpieza completada ==="
