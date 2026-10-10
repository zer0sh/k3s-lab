#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

echo "=== Desplegando infraestructura ==="

echo "[1/4] Desplegando monitoring (Prometheus + Grafana)..."
kubectl apply -f "$PROJECT_DIR/infrastructure/monitoring/prometheus/"
kubectl apply -f "$PROJECT_DIR/infrastructure/monitoring/grafana/"

echo "[2/4] Desplegando logging (Loki + Promtail)..."
kubectl apply -f "$PROJECT_DIR/infrastructure/logging/loki/"

echo "[3/4] Instalando ArgoCD Image Updater..."
kubectl apply -f "$PROJECT_DIR/infrastructure/argocd-image-updater/install.yaml"
wait_for_crd imageupdaters.argocd-image-updater.argoproj.io
kubectl apply -f "$PROJECT_DIR/infrastructure/argocd-image-updater/imageupdater-sample-app.yaml"

# Fuente Git de ArgoCD: GIT_SOURCE=github|local (sin definir: la que ya usan las apps, o github)
GIT_SOURCE="${GIT_SOURCE:-}"
wait_for_crd applications.argoproj.io
if [ -z "$GIT_SOURCE" ]; then
  GIT_SOURCE="$(current_git_source)"
fi
echo "[4/4] Registrando apps en ArgoCD desde $GIT_SOURCE (sample-app, postgres, mysql, sonarqube, infrastructure)..."
case "$GIT_SOURCE" in
  github) apply_argocd_apps "$PROJECT_DIR" github ;;
  local)  bash "$SCRIPT_DIR/local-git.sh" push ;;
  *)      echo "ERROR: GIT_SOURCE debe ser github o local" >&2; exit 1 ;;
esac

echo ""
echo "=== Infraestructura desplegada ==="
echo "ArgoCD sincroniza ahora postgres, mysql, sonarqube y sample-app desde Git ($GIT_SOURCE)."
echo "Estado: kubectl get applications -n argocd"
echo ""
if [ "$GIT_SOURCE" = github ]; then
  echo "Para que Image Updater haga commit del nuevo tag, crea el secret con un PAT de GitHub:"
  echo "  make git-creds GIT_USER=<usuario> GIT_TOKEN=<PAT>"
else
  echo "Fuente local: aplica cambios con make push-local (no hace falta commit ni GitHub)."
fi
echo ""
echo "Acceso a los servicios: bash scripts/port-forward-all.sh"
