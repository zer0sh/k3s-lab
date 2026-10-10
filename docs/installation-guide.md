# Guía de instalación paso a paso

## Requisitos previos

- Linux (Ubuntu 20.04+ recomendado)
- 2 CPU / 4 GB RAM mínimo (8 GB recomendado si se incluye SonarQube)
- Acceso root o sudo
- `curl` instalado

## Opción A: un solo comando (recomendado)

```bash
git clone https://github.com/zer0sh/k3s-lab.git
cd k3s-lab
make up
```

`make up` ejecuta los pasos 2 y 3 de la opción B (el bootstrap solo si K3s no está instalado), espera a que las 5 apps de ArgoCD estén `Synced`/`Healthy` y muestra `make status`. Luego:

```bash
eval "$(make env)"                                  # kubectl contra el lab
make git-creds GIT_USER=<usuario> GIT_TOKEN=<PAT>   # opcional, para Image Updater
make forward                                        # acceso a los servicios
```

`make help` lista el resto de comandos.

**Sin GitHub:** `make up GIT_SOURCE=local` instala un Git dentro del cluster, le envía tu working tree y ArgoCD despliega desde ahí. Ver [deploy-sin-github.md](deploy-sin-github.md).

## Opción B: con scripts, paso a paso

### Paso 1: Clonar el repositorio

```bash
git clone https://github.com/zer0sh/k3s-lab.git
cd k3s-lab
```

### Paso 2: Bootstrap

```bash
bash scripts/bootstrap.sh
```

Instala K3s, copia el kubeconfig a `~/.kube/config-k3s`, instala Ingress NGINX y Cert-Manager (espera sus CRDs y aplica el `ClusterIssuer` autofirmado) e instala ArgoCD (espera a que `argocd-server` esté listo).

> K3s v1.34+ ya incluye Metrics Server, por eso `cluster/addons/metrics-server/` no se aplica: instalarlo encima provoca CrashLoopBackOff.

### Paso 3: Infraestructura y apps

```bash
bash scripts/deploy-infra.sh
```

Despliega Prometheus, Grafana, Loki + Promtail, ArgoCD Image Updater (con su CR `ImageUpdater`) y registra las 5 Applications en ArgoCD. A partir de ahí, **ArgoCD sincroniza desde Git** `postgres`, `mysql`, `sonarqube`, `sample-app` e `infrastructure`; no hace falta aplicarlas a mano.

### Paso 4: Usar el kubeconfig del lab

```bash
export KUBECONFIG=~/.kube/config-k3s
```

### Paso 5 (opcional): Credenciales para Image Updater

Para que Image Updater haga commit del nuevo tag de la `sample-app` en Git, necesita un PAT de GitHub con permiso de escritura en el repo:

```bash
make git-creds GIT_USER=<usuario-github> GIT_TOKEN=<PAT>
```

Sin este secret, el resto del lab funciona igual; solo se queda sin despliegue automático de imágenes nuevas.

## Opción C: manual

```bash
# 1. K3s + kubeconfig del lab
curl -sfL https://get.k3s.io | sh -
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config-k3s
sudo chown "$(id -u):$(id -g)" ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
kubectl get nodes

# 2. Addons (el ClusterIssuer necesita que existan los CRDs de cert-manager)
kubectl apply -f cluster/addons/ingress-nginx/
kubectl apply -f cluster/addons/cert-manager/cert-manager.yaml
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=300s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s
kubectl apply -f cluster/addons/cert-manager/clusterissuer-selfsigned.yaml

# 3. ArgoCD
kubectl apply -f infrastructure/argocd/namespace.yaml
kubectl apply -f infrastructure/argocd/installation.yaml
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=300s

# 4. Observabilidad + Image Updater
kubectl apply -f infrastructure/monitoring/prometheus/
kubectl apply -f infrastructure/monitoring/grafana/
kubectl apply -f infrastructure/logging/loki/
kubectl apply -f infrastructure/argocd-image-updater/install.yaml
kubectl wait --for=condition=Established crd/imageupdaters.argocd-image-updater.argoproj.io --timeout=300s
kubectl apply -f infrastructure/argocd-image-updater/imageupdater-sample-app.yaml

# 5. Applications de ArgoCD
kubectl apply -f argocd-apps/
```

> Si `kubectl wait` falla con "not found", el HelmChart aún no creó el CRD: espera unos segundos y repite. Los scripts ya lo hacen con reintentos.

## Acceder a los servicios

```bash
make forward    # o: bash scripts/port-forward-all.sh
```

| Servicio   | URL                         | Credenciales                |
|------------|-----------------------------|-----------------------------|
| ArgoCD     | http://localhost:8080       | admin / (auto)              |
| Grafana    | http://localhost:3000       | admin / admin               |
| Prometheus | http://localhost:9090       | -                           |
| SonarQube  | http://localhost:9001       | admin / admin               |
| pgAdmin    | http://localhost:5050       | admin@devlab.com / admin123 |
| PostgreSQL | localhost:5432              | admin / admin123            |
| phpMyAdmin | http://localhost:8082       | usuarios de MySQL           |
| MySQL      | localhost:3306              | admin / admin123, root / root123 |
| Sample App | http://localhost:8081       | -                           |
| Loki       | http://localhost:3100/ready | -                           |

Para cambiar las contraseñas de las bases de datos: `make db-password TARGET=postgres|pgadmin|mysql|mysql-root` (`make db-creds` muestra las vigentes).

Más detalles en [access-services.md](access-services.md).

## Verificar

```bash
make status     # nodo, apps de ArgoCD y pods con problemas
make apps       # Applications + ImageUpdater
```

Deberían aparecer 5 aplicaciones en ArgoCD (`sample-app`, `infrastructure`, `postgres`, `mysql` y `sonarqube`) en estado `Synced` / `Healthy`. SonarQube tarda unos minutos más.

## Limpieza

```bash
make down    # o: bash scripts/cleanup.sh
```

Desinstala K3s y borra `~/.kube/config-k3s`. Tu `~/.kube/config` no se toca.
