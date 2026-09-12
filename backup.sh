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
DUMP_DIR="${DUMP_DIR:-/tmp/nc-backup}"
LOCK_FILE="${LOCK_FILE:-/var/run/nextcloud-backup.lock}"
TEMP_MIN_FREE_MB="${TEMP_MIN_FREE_MB:-1024}"
VERIFY_ARCHIVE_DATA="${VERIFY_ARCHIVE_DATA:-true}"
MAINTENANCE_ENABLED=false
BACKUP_NAME=""
TMP_ROOT=""

log() { printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
error() { log ERROR "$@" >&2; }
success() { log SUCCESS "$@"; }
fatal() { error "$*"; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ "$MAINTENANCE_ENABLED" == true ]]; then
        if docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ maintenance:mode --off >/dev/null 2>&1; then
            info "Nextcloud Maintenance Mode deaktiviert."
        else
            error "Maintenance Mode konnte beim Cleanup nicht deaktiviert werden."
            rc=1
        fi
        MAINTENANCE_ENABLED=false
    fi
    if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
        rm -rf -- "$TMP_ROOT"
    fi
    if (( rc == 0 )); then
        success "Backup beendet."
    else
        error "Backup fehlgeschlagen (Exit-Code ${rc})."
    fi
    exit "$rc"
}
trap cleanup EXIT
handle_signal() { case "$1" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; esac; }
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP

require_command() { command -v "$1" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $1"; }

[[ -f "$ENV_FILE" ]] || { trap - EXIT INT TERM HUP; error ".env fehlt: $ENV_FILE"; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"
: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"
export BORG_PASSPHRASE
[[ -n "${BORG_RSH:-}" ]] && export BORG_RSH

if [[ "$EUID" -ne 0 ]]; then fatal "Dieses Skript muss als root ausgeführt werden."; fi
for cmd in bash docker borg flock mktemp find stat df du sha256sum hostname date grep awk sed tr; do require_command "$cmd"; done

exec 9>"$LOCK_FILE" || fatal "Lock-Datei kann nicht geöffnet werden: $LOCK_FILE"
if ! flock -n 9; then fatal "Es läuft bereits ein Nextcloud-Backup."; fi

info "Starte Nextcloud Backup (Version $SCRIPT_VERSION)."
info "Repository: $BORG_REPO"
info "Prüfe Docker/Compose und Konfiguration."
[[ -f "$COMPOSE_FILE" ]] || fatal "Compose-Datei fehlt: $COMPOSE_FILE"
cd "$COMPOSE_DIR"
docker version >/dev/null 2>&1 || fatal "Docker ist nicht erreichbar."
docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 ist nicht verfügbar."
docker compose -f "$COMPOSE_FILE" config -q || fatal "Docker Compose Konfiguration ist ungültig."

docker compose -f "$COMPOSE_FILE" ps >/dev/null 2>&1 || true
RUNNING_SERVICES="$(docker compose -f "$COMPOSE_FILE" ps --status running -q)"
[[ -n "$RUNNING_SERVICES" ]] || fatal "Kein Compose-Service läuft; Nextcloud muss für den Backup-Preflight verfügbar sein."
docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ status >/dev/null 2>&1 || fatal "Nextcloud occ status ist nicht erfolgreich."

for path in "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL"; do
    [[ -e "$path" ]] || fatal "Benötigter Pfad fehlt: $path"
done

VOLUME_PATH="$(docker volume inspect "$NC_VOLUME" --format '{{ .Mountpoint }}' 2>/dev/null)" || fatal "Docker-Volume fehlt: $NC_VOLUME"
[[ -d "$VOLUME_PATH" ]] || fatal "Docker-Volume-Mountpoint fehlt: $VOLUME_PATH"

borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nicht erreichbar."

docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 || fatal "PostgreSQL ist nicht erreichbar."
DB_SIZE_BYTES="$(docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atqc 'SELECT pg_database_size(current_database());' 2>/dev/null | tr -d '\r')"
[[ "$DB_SIZE_BYTES" =~ ^[0-9]+$ ]] || fatal "PostgreSQL-Datenbankgröße konnte nicht ermittelt werden."
TMP_ROOT="$(mktemp -d -p "${TMPDIR:-/tmp}" nextcloud-backup.XXXXXX)" || fatal "Temporäres Verzeichnis konnte nicht erstellt werden."
chmod 700 "$TMP_ROOT"
DUMP_FILE="$TMP_ROOT/nextcloud-db.sql"
META_FILE="$TMP_ROOT/backup-metadata.json"
FREE_BYTES="$(df -Pk "$TMP_ROOT" | awk 'NR==2 {print $4 * 1024}')"
REQUIRED_BYTES=$((DB_SIZE_BYTES * 2 + 100 * 1024 * 1024))
(( FREE_BYTES >= REQUIRED_BYTES && FREE_BYTES >= TEMP_MIN_FREE_MB * 1024 * 1024 )) || fatal "Zu wenig temporärer Speicher. Frei: ${FREE_BYTES} Bytes, benötigt mindestens ${REQUIRED_BYTES} Bytes."

COMPOSE_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
ENV_HASH="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
DOCKER_VERSION="$(docker --version)"
COMPOSE_VERSION="$(docker compose version)"
NC_VERSION="$(docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ -V 2>/dev/null | head -n1)"
PG_VERSION="$(docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atqc 'SELECT version();' 2>/dev/null | tr -d '\r')"
[[ -n "$NC_VERSION" && -n "$PG_VERSION" ]] || fatal "Nextcloud-/PostgreSQL-Version konnte nicht ermittelt werden."

info "Preflight erfolgreich. Aktiviere Maintenance Mode."
docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ maintenance:mode --on
MAINTENANCE_ENABLED=true

info "Erstelle PostgreSQL-Dump."
if ! docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain --no-owner --no-privileges >"$DUMP_FILE"; then
    fatal "pg_dump ist fehlgeschlagen."
fi
chmod 600 "$DUMP_FILE"
[[ -f "$DUMP_FILE" ]] || fatal "PostgreSQL-Dump wurde nicht erstellt."
DUMP_SIZE="$(stat -c '%s' "$DUMP_FILE")"
(( DUMP_SIZE > 0 )) || fatal "PostgreSQL-Dump ist leer."
DUMP_SHA256="$(sha256sum "$DUMP_FILE" | awk '{print $1}')"
success "PostgreSQL-Dump erstellt (${DUMP_SIZE} Bytes, SHA-256 ${DUMP_SHA256})."

json_escape() { printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r/\\r/g'; }
TIMESTAMP="$(date --iso-8601=seconds)"
printf '{\n  "timestamp": "%s",\n  "hostname": "%s",\n  "nextcloud_version": "%s",\n  "postgres_version": "%s",\n  "docker_version": "%s",\n  "compose_version": "%s",\n  "compose_file_hash": "%s",\n  "env_file_hash": "%s",\n  "backup_script_version": "%s",\n  "postgres_dump_size": %s,\n  "postgres_dump_sha256": "%s"\n}\n' \
    "$(json_escape "$TIMESTAMP")" "$(json_escape "$(hostname)")" "$(json_escape "$NC_VERSION")" "$(json_escape "$PG_VERSION")" "$(json_escape "$DOCKER_VERSION")" "$(json_escape "$COMPOSE_VERSION")" "$COMPOSE_HASH" "$ENV_HASH" "$SCRIPT_VERSION" "$DUMP_SIZE" "$DUMP_SHA256" > "$META_FILE"
chmod 600 "$META_FILE"

BACKUP_NAME="nextcloud-$(date '+%Y-%m-%d_%H-%M-%S')"
info "Erstelle Borg-Archiv: $BACKUP_NAME"
borg create --stats --compression zstd "${BORG_REPO}::${BACKUP_NAME}" \
    "$COMPOSE_FILE" "$ENV_FILE" "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL" "$VOLUME_PATH" "$DUMP_FILE" "$META_FILE"

borg info "${BORG_REPO}::${BACKUP_NAME}" >/dev/null || fatal "Neues Borg-Archiv ist nicht lesbar."
BORG_LIST="$(borg list "${BORG_REPO}::${BACKUP_NAME}" 2>/dev/null)" || fatal "Neues Borg-Archiv konnte nicht gelistet werden."
for expected in "$COMPOSE_FILE" "$ENV_FILE" "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL" "$DUMP_FILE" "$META_FILE"; do
    [[ "$BORG_LIST" == *"${expected#/}"* ]] || fatal "Archivvalidierung fehlgeschlagen: Pfad fehlt: $expected"
done
VOLUME_ARCHIVE_PATH="${VOLUME_PATH#/}"
[[ "$BORG_LIST" == *"$VOLUME_ARCHIVE_PATH"* ]] || fatal "Archivvalidierung fehlgeschlagen: Docker-Volume fehlt."

if [[ "$VERIFY_ARCHIVE_DATA" == true ]]; then
    VERIFY_DUMP="$TMP_ROOT/verified-db.sql"
    borg extract --stdout "${BORG_REPO}::${BACKUP_NAME}" "${DUMP_FILE#/}" > "$VERIFY_DUMP" || fatal "Gespeicherter PostgreSQL-Dump konnte nicht aus dem Borg-Archiv gelesen werden."
    VERIFIED_SHA256="$(sha256sum "$VERIFY_DUMP" | awk '{print $1}')"
    [[ "$VERIFIED_SHA256" == "$DUMP_SHA256" ]] || fatal "Archivvalidierung fehlgeschlagen: PostgreSQL-Dump-Hash stimmt nicht überein."
    success "Archivdaten des PostgreSQL-Dumps erfolgreich gelesen und verifiziert."
fi
success "Borg-Archiv erstellt und validiert: $BACKUP_NAME"

info "Führe Borg Retention aus (7 täglich / 4 wöchentlich / 12 monatlich)."
borg prune --list --stats --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$BORG_REPO"
info "Verbleibende Archive:"
borg list "$BORG_REPO"
borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nach Retention nicht lesbar."
success "Backup erfolgreich: $BACKUP_NAME"
