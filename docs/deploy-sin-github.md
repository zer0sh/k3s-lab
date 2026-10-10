# Desplegar con ArgoCD sin GitHub

Por defecto, las Applications de ArgoCD leen de `https://github.com/zer0sh/k3s-lab.git`: un cambio solo llega al lab después de hacer commit y push. Esta guía describe las alternativas para desplegar desde tu copia local.

> "Sin GitHub" no significa sin internet: los charts de Helm y las imágenes siguen descargándose de sus registries (Docker Hub, repos de Helm).

## Resumen

| Opción | Cómo funciona | GitOps completo | En el lab |
|---|---|---|---|
| **1. Git dentro del cluster** | ArgoCD lee de un servidor Git en el namespace `git`; tú envías ahí tu working tree | Sí: auto-sync, self-heal, historial, rollback, Image Updater | **Implementada**: `make push-local` |
| 2. `argocd app sync --local` | El CLI renderiza una carpeta local y la aplica a través de ArgoCD | No | Manual, solo para pruebas puntuales |
| 3. Fuente OCI | Los manifiestos se empaquetan como artefacto OCI en un registry | Sí | No implementada |
| 4. `kubectl apply` directo | Sin ArgoCD | No | Manual |

---

## Opción 1: Git dentro del cluster (`make push-local`)

```bash
make push-local                   # envía tu working tree al Git local y ArgoCD pasa a leer de ahí
make push-local LOCAL_GIT=light   # igual, con el backend ligero
make git-source                   # fuente actual y backend instalado
make use-github                   # ArgoCD vuelve a GitHub
```

O desde cero, sin pasar nunca por GitHub:

```bash
make up GIT_SOURCE=local                  # backend gitea
make up GIT_SOURCE=local LOCAL_GIT=light  # backend ligero
```

### Backends

Los dos exponen la **misma URL** para ArgoCD (`http://git.git.svc.cluster.local/lab/k3s-lab.git`), así que se pueden intercambiar sin tocar las Applications.

| Backend | `LOCAL_GIT` | Qué es | RAM aprox. | Interfaz |
|---|---|---|---|---|
| Gitea | `gitea` (por defecto) | `gitea/gitea:1.24-rootless` con SQLite | ~95 MiB | Web en http://localhost:3030 (`make forward`), usuario `lab` / `labgit123` |
| Ligero | `light` | `git-http-backend` + `fcgiwrap` sobre `nginx:1.29-alpine` (instala `git` al arrancar) | ~15 MiB | Ninguna |

- Manifiestos en `cluster/addons/local-git/`. No los gestiona ArgoCD, porque no puede depender del Git del que lee.
- Si cambias de backend (`make push-local LOCAL_GIT=light` con Gitea instalado), se borra el repo local y el mismo push lo vuelve a crear.
- El usuario `lab` / `labgit123` está en el Secret `git/local-git`. Gitea lo exige para hacer push; el backend ligero acepta escritura anónima, porque el Service solo es accesible dentro del cluster o por port-forward.

### Qué hace `make push-local`

1. Instala el servidor Git local si falta (o cambia de backend si pasas `LOCAL_GIT`). En Gitea crea el usuario `lab`.
2. Crea un **snapshot de tu working tree**: incluye cambios sin commitear y archivos nuevos, y respeta `.gitignore`. Usa un índice temporal y `git commit-tree`, así que **tu rama, tu índice y tu historial no se tocan**. El commit tiene como padre tu `HEAD`.
3. Hace push forzado del snapshot a `main` del Git local, a través de un port-forward temporal (puerto `18080`, configurable con `LOCAL_GIT_PF_PORT`). Las credenciales viajan por variables de entorno, no en la URL.
4. Aplica `argocd-apps/` con `repoURL` apuntando al Git local y pide un refresh de las Applications. ArgoCD despliega en segundos.

Cada `make push-local` reemplaza el `main` local por el snapshot nuevo. Para iterar: editas, ejecutas `make push-local` y compruebas.

### Cómo se elige la fuente

- `make up` / `make infra` sin `GIT_SOURCE` mantienen la fuente que ya usan las Applications (o GitHub si aún no existen). Con `GIT_SOURCE=local`, `deploy-infra.sh` ejecuta `make push-local` en lugar de aplicar las apps apuntando a GitHub.
- `make use-github` vuelve a aplicar las Applications con la URL de GitHub. El Git local queda instalado; para quitarlo: `kubectl delete namespace git`.

### Image Updater en modo local

Image Updater hace write-back al repo de la Application, así que en modo local escribe en el Git local:

- `make push-local` pone en `argocd/git-creds` el usuario del Git local. Si había credenciales de GitHub, las guarda en `argocd/git-creds-github`, y `make use-github` las restaura.
- Si usas `make git-creds` en modo local, sobrescribes las credenciales locales.
- El próximo `make push-local` sobrescribe el commit de Image Updater con tu working tree. Si quieres conservar el tag nuevo, cópialo a `apps/sample-app/kustomization.yaml`.

### Limitaciones

- GitHub Actions no ve el Git local. Build, lint, Trivy y SonarQube siguen funcionando sobre GitHub. El workflow de rollback deja de tener sentido: en modo local se hace rollback con `make push-local` de la versión anterior, o con `argocd app rollback`.
- El Git local es un espejo desechable, no un segundo origen: el historial "real" sigue en tu repo y en GitHub.

---

## Opción 2: `argocd app sync --local`

El CLI de ArgoCD renderiza una carpeta local y la sincroniza, sin leer del repo. ArgoCD **no lo permite con auto-sync activo**, así que hay que desactivarlo antes:

```bash
argocd login localhost:8080 --plaintext --username admin     # con make forward activo
argocd app set sample-app --sync-policy none
argocd app sync sample-app --local apps/sample-app
argocd app diff sample-app --local apps/sample-app            # ver diferencias sin aplicar
# volver a GitOps normal:
argocd app set sample-app --sync-policy automated --auto-prune --self-heal
```

Sirve para probar un cambio puntual en una app. La Application queda "OutOfSync" respecto a su repo hasta que vuelves a activar auto-sync.

## Opción 3: fuente OCI

ArgoCD 3.1+ acepta artefactos OCI como fuente (`repoURL: oci://registry/repo`). Habría que montar un registry en el cluster, empaquetar los manifiestos con `oras push` y cambiar las Applications. Es la opción más moderna, pero requiere más piezas que la 1 sin aportar nada extra a un lab local; no está implementada.

## Opción 4: `kubectl apply` directo

```bash
kubectl apply -k apps/sample-app      # Kustomize
kubectl apply -f apps/mysql/          # manifiestos planos
```

No pasa por ArgoCD. Si la Application existe con self-heal, ArgoCD revertirá el cambio al estado de su repo en el siguiente ciclo. Útil solo para recursos que no gestiona ArgoCD, o con la Application borrada.
