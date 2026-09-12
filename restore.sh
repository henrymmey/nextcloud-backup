#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/nextcloud}"
COMPOSE_FILE="${COMPOSE_FILE:-${COMPOSE_DIR}/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-${COMPOSE_DIR}/.env}"
APP_CONTAINER="${APP_CONTAINER:-app}"
DB_CONTAINER="${DB_CONTAINER:-db}"
NC_CONFIG="${NC_CONFIG:-/opt/nextcloud/config}"
NC_DATA="${NC_DATA:-/mnt/hdd/nextcloud/data}"
NC_APPDATA="${NC_APPDATA:-/mnt/ssd-working/appdata_oc464t3i6cse}"
NC_EXTERNAL="${NC_EXTERNAL:-/mnt/ssd-working/nc_external_storage}"
NC_VOLUME="${NC_VOLUME:-nextcloud_nextcloud_html}"
RESTORE_DIR="${RESTORE_DIR:-/tmp/nc-restore}"
LOCK_FILE="${LOCK_FILE:-/var/run/nextcloud-backup.lock}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://127.0.0.1/}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
ROLLBACK_DIR=""
ROLLBACK_TARGETS=()
ROLLBACK_OLDS=()
ROLLBACK_EXISTED=()
DB_ROLLBACK_DUMP=""
DB_ROLLBACK_AVAILABLE=false
BACKUP_NAME=""
STACK_WAS_RUNNING=false
RESTORE_APPLIED=false

log() { printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
error() { log ERROR "$@" >&2; }
success() { log SUCCESS "$@"; }
fatal() { error "$*"; exit 5; }

[[ -f "$ENV_FILE" ]] || { error ".env fehlt: $ENV_FILE"; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"
: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"
[[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { error "DB_NAME enthält ungültige Zeichen."; exit 2; }
[[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { error "DB_USER enthält ungültige Zeichen."; exit 2; }
export BORG_PASSPHRASE
[[ -n "${BORG_RSH:-}" ]] && export BORG_RSH

if [[ "$EUID" -ne 0 ]]; then error "Dieses Skript muss als root ausgeführt werden."; exit 2; fi
for cmd in bash docker borg flock mktemp find stat df sha256sum hostname date curl grep tr awk sed; do command -v "$cmd" >/dev/null 2>&1 || { error "Benötigtes Programm fehlt: $cmd"; exit 2; }; done
[[ -f "$COMPOSE_FILE" ]] || { error "Compose-Datei fehlt: $COMPOSE_FILE"; exit 2; }

exec 9>"$LOCK_FILE" || { error "Lock-Datei kann nicht geöffnet werden: $LOCK_FILE"; exit 2; }
flock -n 9 || { error "Ein Backup/Restore läuft bereits."; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" && "$RESTORE_APPLIED" == false ]]; then
        warn "Restore wurde vor Abschluss abgebrochen; versuche Rollback."
        restore_database_rollback || { error "Datenbank-Rollback konnte nicht vollständig durchgeführt werden."; rc=5; }
        rollback_all || { error "Datei-Rollback konnte nicht vollständig durchgeführt werden."; rc=5; }
    fi
    if [[ "$STACK_WAS_RUNNING" == true && "$RESTORE_APPLIED" == false ]]; then
        docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || true
    fi
    if [[ -d "$RESTORE_DIR" ]]; then rm -rf -- "$RESTORE_DIR"; fi
    if (( rc == 0 )); then success "Restore erfolgreich."; else error "Restore fehlgeschlagen (Exit-Code ${rc})."; fi
    exit "$rc"
}
trap cleanup EXIT
handle_signal() { case "$1" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; esac; }
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP

wait_for_db() {
    local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))
    while (( SECONDS < deadline )); do
        if docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; then return 0; fi
        sleep "$POLL_INTERVAL"
    done
    return 1
}

wait_for_nextcloud() {
    local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))
    while (( SECONDS < deadline )); do
        if docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ status >/dev/null 2>&1; then
            if curl --fail --silent --show-error --max-time 10 "$HEALTHCHECK_URL" >/dev/null 2>&1; then return 0; fi
        fi
        sleep "$POLL_INTERVAL"
    done
    return 1
}

restore_database_rollback() {
    [[ "$DB_ROLLBACK_AVAILABLE" == true && -s "$DB_ROLLBACK_DUMP" ]] || return 0
    info "Stelle ursprüngliche PostgreSQL-Datenbank aus Rollback-Dump wieder her."
    docker compose -f "$COMPOSE_FILE" up -d "$DB_CONTAINER" >/dev/null
    wait_for_db || return 1
    docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -v dbname="$DB_NAME" -U "$DB_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'dbname' AND pid <> pg_backend_pid();" \
        -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" \
        -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" || return 1
    cat "$DB_ROLLBACK_DUMP" | docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
        psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" || return 1
    return 0
}

rollback_all() {
    local i target old failed=0
    for (( i=${#ROLLBACK_TARGETS[@]}-1; i>=0; i-- )); do
        target="${ROLLBACK_TARGETS[$i]}"
        old="${ROLLBACK_OLDS[$i]}"
        if [[ -e "$old" ]]; then
            rm -rf -- "$target" || failed=1
            mv -- "$old" "$target" || failed=1
        elif [[ "${ROLLBACK_EXISTED[$i]}" == false ]]; then
            rm -rf -- "$target" || failed=1
        fi
    done
    return "$failed"
}

stage_dir() {
    local source="$1" target="$2" parent
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    rm -rf -- "$target"
    mkdir -p "$target"
    cp -a "$source/." "$target/"
}

apply_path() {
    local staged="$1" target="$2" parent old
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    old="$ROLLBACK_DIR/old-${#ROLLBACK_TARGETS[@]}"
    if [[ -e "$target" ]]; then
        mv -- "$target" "$old" || return 1
        ROLLBACK_EXISTED+=(true)
    else
        ROLLBACK_EXISTED+=(false)
    fi
    ROLLBACK_TARGETS+=("$target")
    ROLLBACK_OLDS+=("$old")
    if ! mv -- "$staged" "$target"; then
        if [[ -e "$old" ]]; then mv -- "$old" "$target" || true; fi
        return 1
    fi
}

info "Nextcloud Restore (Version $SCRIPT_VERSION)."
info "Prüfe Borg Repository."
borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nicht erreichbar."

borg list "$BORG_REPO"
read -rp "Welches Backup soll wiederhergestellt werden? [Name]: " BACKUP_NAME
[[ -n "$BACKUP_NAME" ]] || { error "Kein Backup angegeben."; exit 1; }
borg info "${BORG_REPO}::${BACKUP_NAME}" >/dev/null || { error "Archiv nicht gefunden oder nicht lesbar: $BACKUP_NAME"; exit 3; }

read -rp "Restore von '$BACKUP_NAME' starten? Es wird ein Rollback-Zustand erstellt. [yes/no]: " CONFIRM
[[ "$CONFIRM" == yes ]] || { info "Restore abgebrochen."; exit 0; }

rm -rf -- "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR/archive" "$RESTORE_DIR/stage"
chmod 700 "$RESTORE_DIR"

info "Extrahiere und validiere Archiv."
borg extract --list "${BORG_REPO}::${BACKUP_NAME}" --destination "$RESTORE_DIR/archive"

DUMP_FOUND="$(find "$RESTORE_DIR/archive" -type f -name 'nextcloud-db.sql' -print -quit)"
META_FOUND="$(find "$RESTORE_DIR/archive" -type f -name 'backup-metadata.json' -print -quit)"
[[ -n "$DUMP_FOUND" && -s "$DUMP_FOUND" ]] || fatal "Gültiger PostgreSQL-Dump fehlt im Archiv."
[[ -n "$META_FOUND" && -s "$META_FOUND" ]] || fatal "Backup-Metadaten fehlen im Archiv."

for required in \
    "${COMPOSE_FILE#/}" "${ENV_FILE#/}" "${NC_CONFIG#/}" "${NC_DATA#/}" "${NC_APPDATA#/}" "${NC_EXTERNAL#/}"; do
    [[ -e "$RESTORE_DIR/archive/$required" ]] || fatal "Erforderlicher Pfad fehlt im Backup: /$required"
done

VOLUME_PATH="$(docker volume inspect "$NC_VOLUME" --format '{{ .Mountpoint }}' 2>/dev/null)" || fatal "Docker-Volume fehlt: $NC_VOLUME"
[[ -d "$VOLUME_PATH" ]] || fatal "Docker-Volume-Mountpoint fehlt: $VOLUME_PATH"
[[ -e "$RESTORE_DIR/archive/${VOLUME_PATH#/}" ]] || fatal "Docker-Volume fehlt im Backup."

info "Backup-Metadaten:"
cat "$META_FOUND"
META_DUMP_SHA256="$(sed -n 's/.*"postgres_dump_sha256"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9]*\)".*/\1/p' "$META_FOUND" | head -n1)"
META_DUMP_SIZE="$(sed -n 's/.*"postgres_dump_size"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$META_FOUND" | head -n1)"
[[ "$META_DUMP_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || fatal "Backup-Metadaten enthalten keinen gültigen Dump-Hash."
[[ "$META_DUMP_SIZE" =~ ^[0-9]+$ && "$META_DUMP_SIZE" -gt 0 ]] || fatal "Backup-Metadaten enthalten keine gültige Dump-Größe."
ACTUAL_DUMP_SIZE="$(stat -c '%s' "$DUMP_FOUND")"
ACTUAL_DUMP_SHA256="$(sha256sum "$DUMP_FOUND" | awk '{print $1}')"
[[ "$ACTUAL_DUMP_SIZE" == "$META_DUMP_SIZE" ]] || fatal "Dump-Größe stimmt nicht mit den Backup-Metadaten überein."
[[ "$ACTUAL_DUMP_SHA256" == "$META_DUMP_SHA256" ]] || fatal "Dump-Hash stimmt nicht mit den Backup-Metadaten überein."
META_COMPOSE_HASH="$(sed -n 's/.*"compose_file_hash"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9]*\)".*/\1/p' "$META_FOUND" | head -n1)"
META_ENV_HASH="$(sed -n 's/.*"env_file_hash"[[:space:]]*:[[:space:]]*"\([a-fA-F0-9]*\)".*/\1/p' "$META_FOUND" | head -n1)"
[[ "$META_COMPOSE_HASH" =~ ^[a-fA-F0-9]{64}$ ]] || fatal "Backup-Metadaten enthalten keinen gültigen Compose-Hash."
[[ "$META_ENV_HASH" =~ ^[a-fA-F0-9]{64}$ ]] || fatal "Backup-Metadaten enthalten keinen gültigen .env-Hash."
ARCHIVE_COMPOSE_HASH="$(sha256sum "$RESTORE_DIR/archive/${COMPOSE_FILE#/}" | awk '{print $1}')"
ARCHIVE_ENV_HASH="$(sha256sum "$RESTORE_DIR/archive/${ENV_FILE#/}" | awk '{print $1}')"
[[ "$ARCHIVE_COMPOSE_HASH" == "$META_COMPOSE_HASH" ]] || fatal "Archivierte Compose-Datei stimmt nicht mit den Metadaten überein."
[[ "$ARCHIVE_ENV_HASH" == "$META_ENV_HASH" ]] || fatal "Archivierte .env stimmt nicht mit den Metadaten überein."

env_value() {
    local key="$1" file="$2" value
    value="$(awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$file")"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s' "$value"
}
ARCHIVE_DB_NAME="$(env_value DB_NAME "$RESTORE_DIR/archive/${ENV_FILE#/}")"
ARCHIVE_DB_USER="$(env_value DB_USER "$RESTORE_DIR/archive/${ENV_FILE#/}")"
ARCHIVE_DB_PASSWORD="$(env_value DB_PASSWORD "$RESTORE_DIR/archive/${ENV_FILE#/}")"
[[ "$ARCHIVE_DB_NAME" == "$DB_NAME" && "$ARCHIVE_DB_USER" == "$DB_USER" && "$ARCHIVE_DB_PASSWORD" == "$DB_PASSWORD" ]] || fatal "Die initialen DB-Zugangsdaten stimmen nicht mit der archivierten .env überein; Restore wird aus Sicherheitsgründen abgebrochen."

info "Stoppe Compose erst jetzt; bis hierhin wurden keine Produktionsdaten verändert."
RUNNING_SERVICES="$(docker compose -f "$COMPOSE_FILE" ps --status running -q)"
if [[ -n "$RUNNING_SERVICES" ]]; then STACK_WAS_RUNNING=true; fi
docker compose -f "$COMPOSE_FILE" down

ROLLBACK_DIR="$(mktemp -d -p "$(dirname "$RESTORE_DIR")" nc-restore-rollback.XXXXXX)"
chmod 700 "$ROLLBACK_DIR"

info "Erstelle Rollback-Dump der aktuellen PostgreSQL-Datenbank."
docker compose -f "$COMPOSE_FILE" up -d "$DB_CONTAINER" >/dev/null || fatal "Aktuelle PostgreSQL-Instanz konnte nicht gestartet werden; Restore wird nicht fortgesetzt."
wait_for_db || fatal "Aktuelle PostgreSQL-Instanz wurde nicht bereit; Restore wird nicht fortgesetzt."
DB_EXISTS="$(docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" 2>/dev/null | tr -d '\r')"
if [[ "$DB_EXISTS" == 1 ]]; then
    DB_ROLLBACK_DUMP="$ROLLBACK_DIR/current-db.sql"
    if ! docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain --no-owner --no-privileges > "$DB_ROLLBACK_DUMP"; then
        fatal "Rollback-Dump der aktuellen Datenbank konnte nicht erstellt werden; Restore wird nicht fortgesetzt."
    fi
    chmod 600 "$DB_ROLLBACK_DUMP"
    [[ -s "$DB_ROLLBACK_DUMP" ]] || fatal "Rollback-Dump der aktuellen Datenbank ist leer."
    DB_ROLLBACK_AVAILABLE=true
fi
docker compose -f "$COMPOSE_FILE" down

info "Bereite Restore-Dateien vor."
stage_dir "$RESTORE_DIR/archive/${NC_CONFIG#/}" "$RESTORE_DIR/stage/config"
stage_dir "$RESTORE_DIR/archive/${NC_DATA#/}" "$RESTORE_DIR/stage/data"
stage_dir "$RESTORE_DIR/archive/${NC_APPDATA#/}" "$RESTORE_DIR/stage/appdata"
stage_dir "$RESTORE_DIR/archive/${NC_EXTERNAL#/}" "$RESTORE_DIR/stage/external"
stage_dir "$RESTORE_DIR/archive/${VOLUME_PATH#/}" "$RESTORE_DIR/stage/volume"
cp -a -- "$RESTORE_DIR/archive/${COMPOSE_FILE#/}" "$RESTORE_DIR/stage/docker-compose.yml"
cp -a -- "$RESTORE_DIR/archive/${ENV_FILE#/}" "$RESTORE_DIR/stage/.env"
chmod 600 "$RESTORE_DIR/stage/.env"

apply_path "$RESTORE_DIR/stage/config" "$NC_CONFIG" || fatal "Config konnte nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/data" "$NC_DATA" || fatal "Nextcloud-Daten konnten nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/appdata" "$NC_APPDATA" || fatal "AppData konnte nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/external" "$NC_EXTERNAL" || fatal "External Storage konnte nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/volume" "$VOLUME_PATH" || fatal "Docker-Volume konnte nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/docker-compose.yml" "$COMPOSE_FILE" || fatal "Compose-Datei konnte nicht übernommen werden."
apply_path "$RESTORE_DIR/stage/.env" "$ENV_FILE" || fatal ".env konnte nicht übernommen werden."

# Do not source archived .env: it is untrusted data and must never be executed as shell code.
# Docker Compose reads the restored .env from COMPOSE_DIR. The original recovery credentials remain in memory.
export BORG_PASSPHRASE
[[ -n "${BORG_RSH:-}" ]] && export BORG_RSH

info "Starte PostgreSQL und warte auf Readiness."
docker compose -f "$COMPOSE_FILE" up -d "$DB_CONTAINER"
wait_for_db || fatal "PostgreSQL wurde nicht rechtzeitig bereit."
docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null || fatal "PostgreSQL-Verbindungstest fehlgeschlagen."

info "Bereite Datenbank für Import vor."
docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -v dbname="$DB_NAME" -U "$DB_USER" -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'dbname' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" \
    -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" || fatal "Datenbank konnte nicht vorbereitet werden."

info "Importiere PostgreSQL-Dump."
cat "$DUMP_FOUND" | docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" || fatal "PostgreSQL-Import fehlgeschlagen."

docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null || fatal "PostgreSQL ist nach dem Import nicht erreichbar."

info "Starte vollständigen Stack."
docker compose -f "$COMPOSE_FILE" up -d
info "Warte auf echte Nextcloud-Readiness."
wait_for_nextcloud || fatal "Nextcloud-Healthcheck fehlgeschlagen."

info "Führe finale Healthchecks aus."
docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ status
if docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ maintenance:mode 2>/dev/null | grep -qi 'enabled\|true'; then
    fatal "Nextcloud ist nach dem Restore noch im Maintenance Mode."
fi
curl --fail --silent --show-error --max-time 15 "$HEALTHCHECK_URL" >/dev/null || fatal "HTTP-Healthcheck fehlgeschlagen."
docker compose -f "$COMPOSE_FILE" ps
RESTORE_APPLIED=true
rm -rf -- "$ROLLBACK_DIR"
ROLLBACK_DIR=""
success "Restore abgeschlossen und Healthchecks bestanden: $BACKUP_NAME"
