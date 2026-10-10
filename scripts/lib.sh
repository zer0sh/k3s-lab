#!/bin/bash
# Funciones comunes de los scripts. Uso: source "$SCRIPT_DIR/lib.sh"

# Kubeconfig dedicado al lab: no pisa ~/.kube/config (otros clusters)
export KUBECONFIG="${K3S_KUBECONFIG:-$HOME/.kube/config-k3s}"

# Espera a que exista un CRD y quede Established (los HelmChart de K3s instalan en segundo plano)
wait_for_crd() {
  local crd="$1" timeout="${2:-300}" elapsed=0
  echo "  Esperando CRD $crd..."
  until kubectl get crd "$crd" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      echo "  ERROR: el CRD $crd no aparecio en ${timeout}s" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  kubectl wait --for=condition=Established "crd/$crd" --timeout=60s
}

# Espera a que exista un deployment y termine su rollout
wait_for_deployment() {
  local ns="$1" name="$2" timeout="${3:-300}" elapsed=0
  echo "  Esperando deployment $ns/$name..."
  until kubectl -n "$ns" get deployment "$name" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      echo "  ERROR: el deployment $ns/$name no aparecio en ${timeout}s" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  kubectl -n "$ns" rollout status "deployment/$name" --timeout="${timeout}s"
}

# Fuentes Git de las Applications de ArgoCD (argocd-apps/ contiene la de GitHub)
GITHUB_REPO_URL="https://github.com/zer0sh/k3s-lab.git"
LOCAL_REPO_URL="http://git.git.svc.cluster.local/lab/k3s-lab.git"

# Fuente actual de las Applications: "local" o "github" (github si aun no hay apps)
current_git_source() {
  local url
  url="$(kubectl -n argocd get application sample-app -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)"
  if [ "$url" = "$LOCAL_REPO_URL" ]; then echo local; else echo github; fi
}

# Aplica argocd-apps/ apuntando a la fuente indicada (github|local)
apply_argocd_apps() { # project_dir source
  local url="$GITHUB_REPO_URL" f
  if [ "$2" = local ]; then url="$LOCAL_REPO_URL"; fi
  for f in "$1"/argocd-apps/*.yaml; do
    sed "s#${GITHUB_REPO_URL}#${url}#" "$f"
    echo "---"
  done | kubectl apply -f -
}
