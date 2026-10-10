# Acceso a servicios - K3s Dev Platform Lab

Todos los comandos asumen el kubeconfig del lab:

```bash
eval "$(make env)"    # equivale a: export KUBECONFIG=~/.kube/config-k3s
```

## Acceso rápido (todos los servicios)

```bash
make forward    # o: bash scripts/port-forward-all.sh
```

Levanta los 10 port-forwards (11 si el Git local está instalado) de esta página e imprime la password de ArgoCD. Presiona `Ctrl+C` para detenerlos.

---

## Servicios individuales

### ArgoCD
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
- URL: http://localhost:8080 (ArgoCD sirve HTTP: `server.insecure: true`)
- Usuario: admin
- Password: `make password`, o:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
- CLI: `argocd login localhost:8080 --plaintext --username admin`

### Grafana
```bash
kubectl port-forward svc/grafana -n monitoring 3000:80
```
- URL: http://localhost:3000
- Usuario: admin / Password: admin
- Datasources preconfigurados: Prometheus + Loki
- Dashboard: carpeta **K3s Platform** > **K3s Platform Overview**

### Prometheus
```bash
kubectl port-forward svc/prometheus-server -n monitoring 9090:80
```
- URL: http://localhost:9090

### SonarQube
```bash
kubectl port-forward svc/sonarqube -n sonarqube 9001:9000
```
- URL: http://localhost:9001
- Usuario: admin / Password: admin (pide cambiarla en el primer login)
- Tarda 1-2 minutos en arrancar (readiness con `initialDelaySeconds: 60`)

### pgAdmin
```bash
kubectl port-forward svc/pgadmin -n postgres 5050:80
```
- URL: http://localhost:5050
- Email: admin@devlab.com / Password: admin123
- El servidor **PostgreSQL (lab)** ya aparece registrado (host `postgres`, usuario `admin`); al abrirlo pide la password de la base de datos (`admin123` inicial)

### PostgreSQL
```bash
kubectl port-forward svc/postgres -n postgres 5432:5432
```
- Host: localhost:5432
- Usuario: admin / Password: admin123
- Base de datos: devlab (vacía). `admin` es superusuario

### phpMyAdmin
```bash
kubectl port-forward svc/phpmyadmin -n mysql 8082:80
```
- URL: http://localhost:8082
- Servidor preconfigurado (`mysql:3306`): entra con un usuario de MySQL (`admin` / `admin123` o `root` / `root123`)

### MySQL
```bash
kubectl port-forward svc/mysql -n mysql 3306:3306
```
- Host: localhost:3306
- Admin: admin / admin123 (todos los privilegios, `WITH GRANT OPTION`)
- Root: root / root123
- Base de datos: devlab (vacía)

### Sample App
```bash
kubectl port-forward svc/sample-app -n sample-app 8081:80
```
- URL: http://localhost:8081
- Health check: http://localhost:8081/health

### Loki (API)
```bash
kubectl port-forward svc/loki -n logging 3100:3100
```
- URL: http://localhost:3100/ready

### Git local (solo con `make push-local`)
```bash
kubectl port-forward svc/git -n git 3030:80
```
- URL: http://localhost:3030 (interfaz web solo con el backend `gitea`)
- Usuario: lab / labgit123
- Repo: `lab/k3s-lab`. ArgoCD lo lee en `http://git.git.svc.cluster.local/lab/k3s-lab.git`
- Ver [deploy-sin-github.md](deploy-sin-github.md)

---

## Cambiar contraseñas de las bases de datos

Las credenciales de arriba son las iniciales. Para ver las vigentes o cambiarlas:

```bash
make db-creds
make db-password TARGET=postgres|pgadmin|mysql|mysql-root
```

Detalle en el [README](../README.md#bases-de-datos).

---

## Ingress NGINX (NodePort)

Solo la `sample-app` tiene Ingress (host `sample-app.local`, certificado autofirmado de `selfsigned-issuer`). El resto de los servicios se accede por port-forward.

1. Añade el host a `/etc/hosts`:
   ```
   127.0.0.1 sample-app.local
   ```
2. Abre:
   - HTTPS: https://sample-app.local:31443 (el navegador avisará del certificado autofirmado)
   - HTTP: http://sample-app.local:31080

> **Nota:** NGINX Ingress usa NodePort porque K3s trae Traefik ocupando los puertos 80/443. Para usar NGINX en puertos estándar, instala K3s con `--disable traefik`.
