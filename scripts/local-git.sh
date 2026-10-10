#!/bin/bash
# Git dentro del cluster como fuente de ArgoCD, para desplegar sin GitHub.
#
# Uso:
#   bash scripts/local-git.sh install [gitea|light]   # instala el servidor Git local
#   bash scripts/local-git.sh push [gitea|light]      # snapshot del working tree -> Git local; ArgoCD lee de ahi
#   bash scripts/local-git.sh use-github              # ArgoCD vuelve a leer de GitHub
#   bash scripts/local-git.sh status                  # fuente actual y backend instalado
#
# Backends (misma URL para ArgoCD: http://git.git.svc.cluster.local/lab/k3s-lab.git):
#   gitea   Gitea con interfaz web (http://localhost:3030 con make forward). Por defecto
#   light   git-http-backend sobre nginx, sin interfaz, minimo consumo
# Sin argumento se mantiene el backend instalado (o LOCAL_GIT si esta definida).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib.sh"

ADDON_DIR="$PROJECT_DIR/cluster/addons/local-git"
PF_PORT="${LOCAL_GIT_PF_PORT:-18080}"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

installed_backend() {
  kubectl -n git get deployment git -o jsonpath='{.metadata.labels.k3s-lab/git-backend}' 2>/dev/null || true
}

require_argocd() {
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
    || die "ArgoCD no esta instalado: ejecuta primero make bootstrap"
}

install() { # [backend]
  local current backend
  current="$(installed_backend)"
  backend="${1:-${LOCAL_GIT:-${current:-gitea}}}"
  case "$backend" in
    gitea|light) ;;
    *) die "backend desconocido '$backend' (usa gitea o light)" ;;
  esac

  echo "=== Git local: backend $backend ==="
  kubectl apply -f "$ADDON_DIR/namespace.yaml" >/dev/null
  kubectl apply -f "$ADDON_DIR/secret.yaml" -f "$ADDON_DIR/service.yaml" >/dev/null
  if [ -n "$current" ] && [ "$current" != "$backend" ]; then
    echo "  Cambiando de $current a $backend: el repo local se recrea con el proximo push"
    kubectl -n git delete deployment git --wait >/dev/null
    kubectl -n git delete pvc git-data --wait >/dev/null
    kubectl -n git delete configmap git-light --ignore-not-found >/dev/null
  fi
  kubectl apply -f "$ADDON_DIR/pvc.yaml" -f "$ADDON_DIR/$backend/" >/dev/null
  wait_for_deployment git git 300 >/dev/null

  if [ "$backend" = gitea ]; then
    local user
    user="$(kubectl -n git get secret local-git -o jsonpath='{.data.username}' | base64 -d)"
    if ! kubectl -n git exec deploy/git -- gitea admin user list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$user"; then
      # La password viaja por stdin, no en los argumentos
      kubectl -n git get secret local-git -o jsonpath='{.data.password}' | base64 -d \
        | kubectl -n git exec -i deploy/git -- sh -c \
          'read -r p; gitea admin user create --admin --username "$1" --password "$p" --email "$1@k3s-lab.local" --must-change-password=false' _ "$user" >/dev/null
      echo "  Usuario $user creado en Gitea"
    fi
  fi
  echo "  Git local listo: $LOCAL_REPO_URL"
}

# Copia un Secret de argocd sin decodificar sus datos
copy_creds() { # from to label(o "") namespace_origen
  local u p label=""
  u="$(kubectl -n "$4" get secret "$1" -o jsonpath='{.data.username}')"
  p="$(kubectl -n "$4" get secret "$1" -o jsonpath='{.data.password}')"
  if [ -n "$3" ]; then label="  labels:
    k3s-lab/git-source: $3"; fi
  kubectl -n argocd delete secret "$2" --ignore-not-found >/dev/null
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: argocd\n%s\ndata:\n  username: %s\n  password: %s\n' \
    "$2" "$label" "$u" "$p" | kubectl apply -f - >/dev/null
}

# Image Updater escribe en el repo de la Application: en modo local usa el usuario del Git local.
# El secret de GitHub (si existe) se guarda en git-creds-github y se restaura con use-github.
creds_to_local() {
  local src
  src="$(kubectl -n argocd get secret git-creds -o jsonpath='{.metadata.labels.k3s-lab/git-source}' 2>/dev/null || echo none)"
  if [ "$src" != none ] && [ "$src" != local ]; then
    copy_creds git-creds git-creds-github "" argocd
  fi
  copy_creds local-git git-creds local git
}

creds_to_github() {
  if kubectl -n argocd get secret git-creds-github >/dev/null 2>&1; then
    copy_creds git-creds-github git-creds "" argocd
    kubectl -n argocd delete secret git-creds-github >/dev/null
  else
    kubectl -n argocd delete secret git-creds --ignore-not-found >/dev/null
    echo "  Sin credenciales de GitHub para Image Updater: make git-creds GIT_USER=... GIT_TOKEN=..."
  fi
}

refresh_apps() {
  kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

push() { # [backend]
  require_argocd
  if [ -z "$(installed_backend)" ] || [ -n "${1:-}" ]; then
    install "${1:-}"
  fi

  cd "$PROJECT_DIR"
  # Snapshot del working tree (incluye cambios sin commitear y archivos nuevos, respeta .gitignore)
  # con un indice temporal: la rama, el indice y el historial del usuario no se tocan.
  local tmp_index tree commit parent=()
  tmp_index="$(mktemp)"
  cp "$(git rev-parse --git-path index)" "$tmp_index" 2>/dev/null || true
  GIT_INDEX_FILE="$tmp_index" git add -A
  tree="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
  rm -f "$tmp_index"
  if git rev-parse -q --verify HEAD >/dev/null; then parent=(-p HEAD); fi
  commit="$(GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(git config user.name || echo k3s-lab)}" \
    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo lab@k3s-lab.local)}" \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$(git config user.name || echo k3s-lab)}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$(git config user.email || echo lab@k3s-lab.local)}" \
    git commit-tree "$tree" "${parent[@]}" -m "push-local: snapshot de $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo working-tree) ($(date -Iseconds))")"

  echo "=== Enviando snapshot ${commit:0:7} al Git local ==="
  kubectl -n git port-forward svc/git "$PF_PORT:80" >/dev/null 2>&1 &
  local pf_pid=$!
  trap 'kill '"$pf_pid"' 2>/dev/null || true' EXIT

  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$PF_PORT/" && break
    sleep 1
  done

  # Credenciales por variables de entorno (no aparecen en los argumentos del proceso)
  local auth
  auth="$(printf '%s:%s' \
    "$(kubectl -n git get secret local-git -o jsonpath='{.data.username}' | base64 -d)" \
    "$(kubectl -n git get secret local-git -o jsonpath='{.data.password}' | base64 -d)" | base64 -w0)"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $auth" \
    git push -q --force "http://127.0.0.1:$PF_PORT/lab/k3s-lab.git" "$commit:refs/heads/main"

  echo "=== ArgoCD: fuente local ==="
  creds_to_local
  apply_argocd_apps "$PROJECT_DIR" local >/dev/null
  refresh_apps
  echo "  Applications -> $LOCAL_REPO_URL (main = ${commit:0:7})"
  echo "  Estado: make status"
}

use_github() {
  require_argocd
  echo "=== ArgoCD: fuente GitHub ==="
  apply_argocd_apps "$PROJECT_DIR" github >/dev/null
  creds_to_github
  refresh_apps
  echo "  Applications -> $GITHUB_REPO_URL"
  echo "  El Git local sigue instalado; para quitarlo: kubectl delete namespace git"
}

status() {
  local backend
  backend="$(installed_backend)"
  echo "Fuente de ArgoCD: $(current_git_source)"
  echo "Git local:        ${backend:-no instalado}"
  if [ "$backend" = gitea ]; then
    echo "Gitea UI:         http://localhost:3030 (make forward), usuario $(kubectl -n git get secret local-git -o jsonpath='{.data.username}' | base64 -d)"
  fi
}

case "${1:-}" in
  install)    install "${2:-}" ;;
  push)       push "${2:-}" ;;
  use-github) use_github ;;
  status)     status ;;
  *)          usage ;;
esac
