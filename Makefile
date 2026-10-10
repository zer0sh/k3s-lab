# K3s Dev Platform Lab
# Uso: make <target>   (make help para ver todos)

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Kubeconfig dedicado al lab: nunca usa el KUBECONFIG/~/.kube/config del entorno (otros clusters)
K3S_KUBECONFIG ?= $(HOME)/.kube/config-k3s
export K3S_KUBECONFIG
export KUBECONFIG := $(K3S_KUBECONFIG)

APPS    := sample-app infrastructure postgres mysql sonarqube

# Fuente Git de ArgoCD (github|local) y backend del Git local (gitea|light). Ver docs/deploy-sin-github.md
GIT_SOURCE ?=
LOCAL_GIT  ?=
export GIT_SOURCE LOCAL_GIT
TIMEOUT ?= 900s
APP     ?= sample-app

.PHONY: help up bootstrap infra wait status apps pods forward password env \
        git-creds refresh logs-image-updater db-creds db-password \
        push-local local-git use-github git-source lint down

help: ## Muestra esta ayuda
	@echo "K3s Dev Platform Lab"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Kubeconfig del lab: $(KUBECONFIG)"

## ---------- Ciclo de vida ----------

up: ## Levanta todo: K3s (si falta) + infra + apps y espera (GIT_SOURCE=local: sin GitHub)
	@if command -v k3s >/dev/null 2>&1 && [ -f "$(KUBECONFIG)" ]; then \
		echo "K3s ya instalado, se omite bootstrap"; \
	else \
		$(MAKE) --no-print-directory bootstrap; \
	fi
	@$(MAKE) --no-print-directory infra
	@$(MAKE) --no-print-directory wait
	@$(MAKE) --no-print-directory status
	@echo ""
	@echo "Listo. Acceso a los servicios: make forward"
	@echo "Para usar kubectl: export KUBECONFIG=$(KUBECONFIG)"

bootstrap: ## Instala K3s, Ingress NGINX, Cert-Manager y ArgoCD (usa sudo)
	bash scripts/bootstrap.sh

infra: ## Despliega observabilidad + Image Updater y registra las apps en ArgoCD (GIT_SOURCE=github|local)
	bash scripts/deploy-infra.sh

wait: ## Espera a que las 5 apps de ArgoCD esten Synced y Healthy (TIMEOUT=900s)
	@echo "Esperando apps de ArgoCD (timeout $(TIMEOUT))..."
	@for app in $(APPS); do \
		kubectl -n argocd get application $$app >/dev/null 2>&1 || { echo "  $$app: no existe (make infra)"; exit 1; }; \
		kubectl -n argocd wait application/$$app --for=jsonpath='{.status.sync.status}'=Synced --timeout=$(TIMEOUT) >/dev/null && \
		kubectl -n argocd wait application/$$app --for=jsonpath='{.status.health.status}'=Healthy --timeout=$(TIMEOUT) >/dev/null && \
		echo "  $$app: Synced / Healthy" || { echo "  $$app: no quedo lista (make status)"; exit 1; }; \
	done

down: ## Desinstala K3s y borra el kubeconfig del lab (pide confirmacion)
	bash scripts/cleanup.sh

## ---------- Estado ----------

status: ## Resumen: nodo, apps de ArgoCD y pods con problemas
	@echo "=== Nodo ==="
	@kubectl get nodes
	@echo ""
	@echo "=== Apps de ArgoCD ==="
	@kubectl -n argocd get applications
	@echo ""
	@echo "=== Pods que no estan Running/Completed ==="
	@kubectl get pods -A --no-headers | awk '$$4 != "Running" && $$4 != "Completed" {print; n++} END {if (!n) print "  (ninguno)"}'

apps: ## Lista las apps de ArgoCD y el ImageUpdater
	@kubectl -n argocd get applications,imageupdaters

pods: ## Lista todos los pods del cluster
	@kubectl get pods -A

## ---------- Acceso ----------

forward: ## Port-forward a todos los servicios (Ctrl+C para detener)
	bash scripts/port-forward-all.sh

password: ## Muestra la password de admin de ArgoCD
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

env: ## Imprime el export de KUBECONFIG (uso: eval "$(make env)")
	@echo "export KUBECONFIG=$(KUBECONFIG)"

## ---------- Bases de datos ----------

db-creds: ## Muestra usuarios y contraseñas actuales de PostgreSQL, pgAdmin y MySQL
	@bash scripts/db-password.sh show

db-password: ## Cambia una contraseña: TARGET=postgres|pgadmin|mysql|mysql-root (la pide; vacia = generar)
	@test -n "$(TARGET)" || { echo "Uso: make db-password TARGET=postgres|pgadmin|mysql|mysql-root"; exit 1; }
	@bash scripts/db-password.sh $(TARGET)

## ---------- GitOps ----------

push-local: ## Envia el working tree (sin commit) al Git local y ArgoCD despliega desde ahi (LOCAL_GIT=gitea|light)
	@bash scripts/local-git.sh push $(LOCAL_GIT)

local-git: ## Solo instala o cambia el Git local (LOCAL_GIT=gitea|light), sin cambiar la fuente de ArgoCD
	@bash scripts/local-git.sh install $(LOCAL_GIT)

use-github: ## ArgoCD vuelve a leer de GitHub
	@bash scripts/local-git.sh use-github

git-source: ## Muestra la fuente Git actual de ArgoCD y el backend local instalado
	@bash scripts/local-git.sh status

git-creds: ## Crea el secret argocd/git-creds para Image Updater (GIT_USER=... GIT_TOKEN=...)
	@test -n "$(GIT_USER)" -a -n "$(GIT_TOKEN)" || { echo "Uso: make git-creds GIT_USER=<usuario> GIT_TOKEN=<PAT con escritura>"; exit 1; }
	@kubectl -n argocd create secret generic git-creds \
		--from-literal=username="$(GIT_USER)" \
		--from-literal=password="$(GIT_TOKEN)" \
		--dry-run=client -o yaml | kubectl apply -f -

refresh: ## Fuerza a ArgoCD a releer Git para una app (APP=sample-app)
	@kubectl -n argocd annotate application $(APP) argocd.argoproj.io/refresh=hard --overwrite

logs-image-updater: ## Sigue los logs de ArgoCD Image Updater
	@kubectl -n argocd logs -f -l app.kubernetes.io/name=argocd-image-updater --tail=50

## ---------- Validacion (sin cluster, requiere Docker) ----------

lint: ## Valida YAML, Kustomize, scripts y workflows
	@echo "=== yamllint ==="
	@docker run --rm -v "$(CURDIR)":/data -w /data cytopia/yamllint -d '{extends: relaxed, rules: {line-length: disable}}' apps argocd-apps cluster infrastructure .github
	@echo "=== kustomize ==="
	@kubectl kustomize apps/sample-app >/dev/null && echo "apps/sample-app OK"
	@echo "=== bash -n ==="
	@for f in scripts/*.sh cluster/bootstrap/*.sh; do bash -n "$$f" || exit 1; done; echo "scripts OK"
	@echo "=== shellcheck ==="
	@docker run --rm -v "$(CURDIR)":/mnt -w /mnt koalaman/shellcheck:stable -x -S warning scripts/*.sh cluster/bootstrap/*.sh && echo "shellcheck OK"
	@echo "=== actionlint ==="
	@docker run --rm -v "$(CURDIR)":/repo -w /repo rhysd/actionlint:latest -ignore SC2129 && echo "workflows OK"
