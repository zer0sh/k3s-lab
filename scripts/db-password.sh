#!/bin/bash
# Cambia contraseñas de las bases de datos del lab y actualiza su Secret.
#
# Uso:
#   bash scripts/db-password.sh show                 # muestra las credenciales actuales
#   bash scripts/db-password.sh <target>             # pide la nueva contraseña (vacía = generar)
#   NEW_PASSWORD=... bash scripts/db-password.sh <target>
#
# Targets:
#   postgres     usuario admin de PostgreSQL (ns postgres)
#   pgadmin      login web de pgAdmin (reinicia pgAdmin)
#   mysql        usuario admin de MySQL (ns mysql)
#   mysql-root   usuario root de MySQL
#
# Git solo guarda los valores iniciales: las Applications de ArgoCD ignoran los cambios
# en vivo de estos Secrets. Tras `make down` + `make up` vuelven los valores de Git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

secret_get() { # ns secret key
  kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d
}

secret_set() { # ns secret key value
  local b64
  b64="$(printf '%s' "$4" | base64 -w0)"
  kubectl -n "$1" patch secret "$2" --type merge -p "{\"data\":{\"$3\":\"$b64\"}}" >/dev/null
}

wait_ready() { # ns pod
  kubectl -n "$1" wait "pod/$2" --for=condition=Ready --timeout=60s >/dev/null \
    || die "el pod $1/$2 no está listo (make status)"
}

read_password() {
  PW="${NEW_PASSWORD:-}"
  GENERATED=false
  if [ -z "$PW" ] && [ -t 0 ]; then
    read -rsp "Nueva contraseña (vacío = generar una aleatoria): " PW
    echo
    if [ -n "$PW" ]; then
      local confirm
      read -rsp "Repite la contraseña: " confirm
      echo
      [ "$PW" = "$confirm" ] || die "las contraseñas no coinciden"
    fi
  fi
  if [ -z "$PW" ]; then
    PW="$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
    GENERATED=true
  fi
  # Juego de caracteres acotado: se usa dentro de SQL y de un fichero de opciones de MySQL
  [[ "$PW" =~ ^[A-Za-z0-9._@%+=:,-]{8,64}$ ]] \
    || die "la contraseña debe tener 8-64 caracteres: letras, números y . _ @ % + = : , -"
}

# Ejecuta SQL como root en MySQL. La password de root viaja por stdin a un fichero de opciones temporal.
mysql_root_exec() { # sql
  local root
  root="$(secret_get mysql mysql-secret MYSQL_ROOT_PASSWORD)"
  { printf '%s\n' "$root"; printf '%s\n' "$1"; } | kubectl -n mysql exec -i mysql-0 -c mysql -- sh -c '
    read -r p
    f=$(mktemp)
    printf "[client]\npassword=%s\n" "$p" > "$f"
    mysql --defaults-extra-file="$f" -uroot
    rc=$?
    rm -f "$f"
    exit $rc'
}

# Si la BD ya cambió pero el Secret no, muestra la contraseña para no perderla
update_secret() { # ns secret key
  secret_set "$1" "$2" "$3" "$PW" \
    || die "la contraseña se cambió pero no se pudo actualizar el Secret $1/$2 ($3). Nueva contraseña: $PW"
}

show() {
  v() { secret_get "$@" 2>/dev/null || echo "(no disponible)"; }
  echo "PostgreSQL (ns postgres, svc postgres:5432, base devlab)"
  echo "  usuario:  $(v postgres postgres-secret POSTGRES_USER)"
  echo "  password: $(v postgres postgres-secret POSTGRES_PASSWORD)"
  echo "pgAdmin (http://localhost:5050)"
  echo "  email:    $(v postgres postgres-secret PGADMIN_DEFAULT_EMAIL)"
  echo "  password: $(v postgres postgres-secret PGADMIN_DEFAULT_PASSWORD)"
  echo "MySQL (ns mysql, svc mysql:3306, base devlab)"
  echo "  admin:    $(v mysql mysql-secret MYSQL_USER) / $(v mysql mysql-secret MYSQL_PASSWORD)"
  echo "  root:     root / $(v mysql mysql-secret MYSQL_ROOT_PASSWORD)"
  echo "phpMyAdmin (http://localhost:8082): usa los usuarios de MySQL"
}

TARGET="${1:-}"
case "$TARGET" in
  show)
    show
    exit 0
    ;;
  postgres)
    wait_ready postgres postgres-0
    read_password
    user="$(secret_get postgres postgres-secret POSTGRES_USER)"
    # Dentro del contenedor, psql entra por socket local sin password
    kubectl -n postgres exec -i postgres-0 -c postgres -- psql -q -v ON_ERROR_STOP=1 -U "$user" -d postgres \
      <<<"ALTER USER \"$user\" WITH PASSWORD '$PW';"
    update_secret postgres postgres-secret POSTGRES_PASSWORD
    label="PostgreSQL ($user)"
    ;;
  pgadmin)
    read_password
    update_secret postgres postgres-secret PGADMIN_DEFAULT_PASSWORD
    # pgAdmin no tiene volumen: al reiniciar crea el usuario con la password del Secret
    kubectl -n postgres rollout restart deployment/pgadmin >/dev/null
    kubectl -n postgres rollout status deployment/pgadmin --timeout=180s >/dev/null
    label="pgAdmin ($(secret_get postgres postgres-secret PGADMIN_DEFAULT_EMAIL))"
    ;;
  mysql)
    wait_ready mysql mysql-0
    read_password
    user="$(secret_get mysql mysql-secret MYSQL_USER)"
    mysql_root_exec "ALTER USER '$user'@'%' IDENTIFIED BY '$PW';"
    update_secret mysql mysql-secret MYSQL_PASSWORD
    label="MySQL ($user)"
    ;;
  mysql-root)
    wait_ready mysql mysql-0
    read_password
    mysql_root_exec "ALTER USER 'root'@'%' IDENTIFIED BY '$PW'; ALTER USER 'root'@'localhost' IDENTIFIED BY '$PW';"
    update_secret mysql mysql-secret MYSQL_ROOT_PASSWORD
    label="MySQL (root)"
    ;;
  *)
    usage
    ;;
esac

echo "Contraseña de $label actualizada (en la base de datos y en el Secret)."
if [ "$GENERATED" = true ]; then
  echo "Contraseña generada: $PW"
fi
echo "Credenciales actuales: make db-creds"
