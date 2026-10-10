#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== Levantando port-forwards ==="

declare -A SERVICES=(
  ["ArgoCD"]="svc/argocd-server -n argocd 8080:443"
  ["Grafana"]="svc/grafana -n monitoring 3000:80"
  ["Prometheus"]="svc/prometheus-server -n monitoring 9090:80"
  ["Sample App"]="svc/sample-app -n sample-app 8081:80"
  ["Loki"]="svc/loki -n logging 3100:3100"
  ["pgAdmin"]="svc/pgadmin -n postgres 5050:80"
  ["PostgreSQL"]="svc/postgres -n postgres 5432:5432"
  ["phpMyAdmin"]="svc/phpmyadmin -n mysql 8082:80"
  ["MySQL"]="svc/mysql -n mysql 3306:3306"
  ["SonarQube"]="svc/sonarqube -n sonarqube 9001:9000"
)
# Git local (solo si esta instalado: make push-local)
if kubectl -n git get svc git >/dev/null 2>&1; then
  SERVICES["Git local"]="svc/git -n git 3030:80"
fi

PIDS=()

cleanup() {
  echo ""
  echo "=== Deteniendo port-forwards ==="
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  echo "Listo."
  exit 0
}

trap cleanup SIGINT SIGTERM

for name in "${!SERVICES[@]}"; do
  kubectl port-forward ${SERVICES[$name]} &>/dev/null &
  PIDS+=($!)
  echo "  $name -> PID $!"
done

echo ""
echo "=== Servicios disponibles ==="
echo "  ArgoCD:     http://localhost:8080   (admin / ver password abajo)"
echo "  Grafana:    http://localhost:3000   (admin / admin)"
echo "  Prometheus: http://localhost:9090"
echo "  Sample App: http://localhost:8081"
echo "  Loki:       http://localhost:3100/ready"
echo "  pgAdmin:    http://localhost:5050   (admin@devlab.com / admin123)"
echo "  PostgreSQL: localhost:5432          (admin / admin123)"
echo "  phpMyAdmin: http://localhost:8082   (usuarios de MySQL)"
echo "  MySQL:      localhost:3306          (admin / admin123, root / root123)"
echo "  SonarQube:  http://localhost:9001   (admin / admin)"
if [ -n "${SERVICES["Git local"]:-}" ]; then
  echo "  Git local:  http://localhost:3030   (lab / labgit123; interfaz web solo con backend gitea)"
fi
echo ""
echo "Password ArgoCD:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo ""
echo ""
echo "Si cambiaste contraseñas de BD: make db-creds"
echo "Presiona Ctrl+C para detener todos los port-forwards"

wait
