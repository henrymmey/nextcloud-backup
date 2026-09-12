#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="4.0.0"
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
LOCK_FILE="${LOCK_FILE:-/var/run/nextcloud-backup.lock}"
TEMP_MIN_FREE_MB="${TEMP_MIN_FREE_MB:-1024}"
VERIFY_ARCHIVE_DATA="${VERIFY_ARCHIVE_DATA:-true}"
VERIFY_ARCHIVE_CONTENT="${VERIFY_ARCHIVE_CONTENT:-true}"
PRUNE_DAILY="${PRUNE_DAILY:-7}"
PRUNE_WEEKLY="${PRUNE_WEEKLY:-4}"
PRUNE_MONTHLY="${PRUNE_MONTHLY:-12}"
MAINTENANCE_ENABLED=false
TMP_ROOT=""
BACKUP_NAME=""
STOPPED_SERVICES=()

log() { printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
error() { log ERROR "$@" >&2; }
success() { log SUCCESS "$@"; }
fatal() { error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $1"; }

# .env is data, never executable shell code.
env_value() {
    local key="$1" file="$2" value
    value="$(awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$file")"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s' "$value"
}

[[ -f "$ENV_FILE" ]] || fatal ".env fehlt: $ENV_FILE"
[[ "$(stat -c '%u' "$ENV_FILE")" == "0" ]] || fatal ".env muss root gehören: $ENV_FILE"
ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
(( 10#$ENV_MODE % 100 < 20 )) || fatal ".env darf nicht für Gruppe/Andere schreibbar sein."

DB_NAME="$(env_value DB_NAME "$ENV_FILE")"
DB_USER="$(env_value DB_USER "$ENV_FILE")"
DB_PASSWORD="$(env_value DB_PASSWORD "$ENV_FILE")"
BORG_REPO="$(env_value BORG_REPO "$ENV_FILE")"
BORG_PASSPHRASE="$(env_value BORG_PASSPHRASE "$ENV_FILE")"
BORG_RSH="$(env_value BORG_RSH "$ENV_FILE")"
: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"
: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"
[[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fatal "DB_NAME enthält ungültige Zeichen."
[[ "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fatal "DB_USER enthält ungültige Zeichen."
export BORG_PASSPHRASE
[[ -n "$BORG_RSH" ]] && export BORG_RSH

if [[ "$EUID" -ne 0 ]]; then fatal "Dieses Skript muss als root ausgeführt werden."; fi
for cmd in bash docker borg flock mktemp find stat df sha256sum hostname date grep awk sed tr head sort; do require_command "$cmd"; done

exec 9>"$LOCK_FILE" || fatal "Lock-Datei kann nicht geöffnet werden: $LOCK_FILE"
flock -n 9 || fatal "Es läuft bereits ein Nextcloud-Backup oder Restore."

restart_stopped_services() {
    if ((${#STOPPED_SERVICES[@]} > 0)); then
        info "Starte zuvor laufende Compose-Dienste wieder: ${STOPPED_SERVICES[*]}"
        docker compose -f "$COMPOSE_FILE" up -d "${STOPPED_SERVICES[@]}" >/dev/null 2>&1 || {
            error "Mindestens ein zuvor laufender Compose-Dienst konnte nicht automatisch gestartet werden."
            return 1
        }
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP

    if [[ "$MAINTENANCE_ENABLED" == true ]]; then
        docker compose -f "$COMPOSE_FILE" up -d "$APP_CONTAINER" >/dev/null 2>&1 || true
        if docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ maintenance:mode --off >/dev/null 2>&1; then
            info "Nextcloud Maintenance Mode deaktiviert."
        else
            error "Maintenance Mode konnte beim Cleanup nicht deaktiviert werden."
            rc=1
        fi
        MAINTENANCE_ENABLED=false
    fi

    if ! restart_stopped_services; then
        rc=1
    fi

    [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf -- "$TMP_ROOT"
    if (( rc == 0 )); then success "Backup beendet."; else error "Backup fehlgeschlagen (Exit-Code ${rc})."; fi
    exit "$rc"
}
trap cleanup EXIT
handle_signal() { case "$1" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; esac; }
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r/\\r/g'
}

info "Starte Nextcloud Backup (Version $SCRIPT_VERSION)."
[[ -f "$COMPOSE_FILE" ]] || fatal "Compose-Datei fehlt: $COMPOSE_FILE"
cd "$COMPOSE_DIR"
docker version >/dev/null 2>&1 || fatal "Docker ist nicht erreichbar."
docker compose version >/dev/null 2>&1 || fatal "Docker Compose v2 ist nicht verfügbar."
docker compose -f "$COMPOSE_FILE" config -q || fatal "Docker Compose Konfiguration ist ungültig."

RUNNING_SERVICES="$(docker compose -f "$COMPOSE_FILE" ps --services --status running)"
[[ -n "$RUNNING_SERVICES" ]] || fatal "Kein Compose-Service läuft."
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
REQUIRED_BYTES=$((DB_SIZE_BYTES * 3 + TEMP_MIN_FREE_MB * 1024 * 1024))
(( FREE_BYTES >= REQUIRED_BYTES )) || fatal "Zu wenig temporärer Speicher. Frei: ${FREE_BYTES} Bytes, konservativ benötigt: ${REQUIRED_BYTES} Bytes."

COMPOSE_HASH="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
ENV_HASH="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
DOCKER_VERSION="$(docker --version)"
COMPOSE_VERSION="$(docker compose version)"
NC_VERSION="$(docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ -V 2>/dev/null | head -n1)"
PG_VERSION="$(docker compose -f "$COMPOSE_FILE" exec -T "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atqc 'SELECT version();' 2>/dev/null | tr -d '\r')"
[[ -n "$NC_VERSION" && -n "$PG_VERSION" ]] || fatal "Nextcloud-/PostgreSQL-Version konnte nicht ermittelt werden."

info "Aktiviere Nextcloud Maintenance Mode."
docker compose -f "$COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ maintenance:mode --on
MAINTENANCE_ENABLED=true
sleep 3

mapfile -t SERVICES_TO_STOP < <(docker compose -f "$COMPOSE_FILE" ps --services --status running | grep -vxF "$DB_CONTAINER" || true)
if ((${#SERVICES_TO_STOP[@]} > 0)); then
    STOPPED_SERVICES=("${SERVICES_TO_STOP[@]}")
    info "Stoppe während des Snapshots: ${STOPPED_SERVICES[*]}"
    docker compose -f "$COMPOSE_FILE" stop "${STOPPED_SERVICES[@]}"
fi

info "Erstelle PostgreSQL-Dump."
docker compose -f "$COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain --no-owner --no-privileges >"$DUMP_FILE" || fatal "pg_dump ist fehlgeschlagen."
chmod 600 "$DUMP_FILE"
DUMP_SIZE="$(stat -c '%s' "$DUMP_FILE")"
(( DUMP_SIZE > 0 )) || fatal "PostgreSQL-Dump ist leer."
DUMP_SHA256="$(sha256sum "$DUMP_FILE" | awk '{print $1}')"
FREE_AFTER_DUMP="$(df -Pk "$TMP_ROOT" | awk 'NR==2 {print $4 * 1024}')"
(( FREE_AFTER_DUMP >= TEMP_MIN_FREE_MB * 1024 * 1024 )) || fatal "Nach pg_dump ist zu wenig temporärer Speicher übrig."
success "PostgreSQL-Dump erstellt (${DUMP_SIZE} Bytes, SHA-256 ${DUMP_SHA256})."

TIMESTAMP="$(date --iso-8601=seconds)"
printf '{\n  "timestamp": "%s",\n  "hostname": "%s",\n  "nextcloud_version": "%s",\n  "postgres_version": "%s",\n  "docker_version": "%s",\n  "compose_version": "%s",\n  "compose_file_hash": "%s",\n  "env_file_hash": "%s",\n  "backup_script_version": "%s",\n  "postgres_dump_size": %s,\n  "postgres_dump_sha256": "%s"\n}\n' \
    "$(json_escape "$TIMESTAMP")" "$(json_escape "$(hostname)")" "$(json_escape "$NC_VERSION")" "$(json_escape "$PG_VERSION")" \
    "$(json_escape "$DOCKER_VERSION")" "$(json_escape "$COMPOSE_VERSION")" "$COMPOSE_HASH" "$ENV_HASH" "$SCRIPT_VERSION" "$DUMP_SIZE" "$DUMP_SHA256" >"$META_FILE"
chmod 600 "$META_FILE"

BACKUP_NAME="nextcloud-$(date '+%Y-%m-%d_%H-%M-%S')"
info "Erstelle Borg-Archiv: $BACKUP_NAME"
borg create --stats --compression zstd "${BORG_REPO}::${BACKUP_NAME}" \
    "$COMPOSE_FILE" "$ENV_FILE" "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL" "$VOLUME_PATH" "$DUMP_FILE" "$META_FILE"

info "Prüfe das neu erstellte Borg-Archiv."
borg info "${BORG_REPO}::${BACKUP_NAME}" >/dev/null || fatal "Neues Borg-Archiv ist nicht lesbar."

# Check the repository metadata and archive structure before anything is pruned.
borg check --archives-only "$BORG_REPO" -a "${BACKUP_NAME}" || fatal "Borg-Archivprüfung fehlgeschlagen."
BORG_LIST="$(borg list "${BORG_REPO}::${BACKUP_NAME}" 2>/dev/null)" || fatal "Neues Borg-Archiv konnte nicht gelistet werden."
for expected in "$COMPOSE_FILE" "$ENV_FILE" "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL" "$DUMP_FILE" "$META_FILE"; do
    [[ "$BORG_LIST" == *"${expected#/}"* ]] || fatal "Archivvalidierung fehlgeschlagen: Pfad fehlt: $expected"
done
VOLUME_ARCHIVE_PATH="${VOLUME_PATH#/}"
[[ "$BORG_LIST" == *"$VOLUME_ARCHIVE_PATH"* ]] || fatal "Archivvalidierung fehlgeschlagen: Docker-Volume fehlt."

if [[ "$VERIFY_ARCHIVE_CONTENT" == true ]]; then
    info "Prüfe, ob alle gesicherten Pfade aus dem Archiv extrahierbar sind."
    borg extract --dry-run "${BORG_REPO}::${BACKUP_NAME}" "$COMPOSE_FILE" "$ENV_FILE" "$NC_CONFIG" "$NC_DATA" "$NC_APPDATA" "$NC_EXTERNAL" "$VOLUME_PATH" "$DUMP_FILE" "$META_FILE" >/dev/null || fatal "Archiv-Struktur ist nicht vollständig extrahierbar."
fi

if [[ "$VERIFY_ARCHIVE_DATA" == true ]]; then
    info "Führe kryptografische Borg-Datenprüfung für das neue Archiv durch."
    borg check --archives-only --verify-data "$BORG_REPO" -a "${BACKUP_NAME}" || fatal "Borg-Datenintegritätsprüfung fehlgeschlagen."

    VERIFY_DUMP="$TMP_ROOT/verified-db.sql"
    borg extract --stdout "${BORG_REPO}::${BACKUP_NAME}" "${DUMP_FILE#/}" >"$VERIFY_DUMP" || fatal "Gespeicherter PostgreSQL-Dump konnte nicht gelesen werden."
    VERIFIED_SHA256="$(sha256sum "$VERIFY_DUMP" | awk '{print $1}')"
    [[ "$VERIFIED_SHA256" == "$DUMP_SHA256" ]] || fatal "PostgreSQL-Dump-Hash stimmt nach Archivierung nicht überein."
    VERIFIED_SIZE="$(stat -c '%s' "$VERIFY_DUMP")"
    [[ "$VERIFIED_SIZE" == "$DUMP_SIZE" ]] || fatal "PostgreSQL-Dump-Größe stimmt nach Archivierung nicht überein."
    success "Neues Archiv und PostgreSQL-Dump vollständig verifiziert."
fi

info "Führe Borg Retention aus (${PRUNE_DAILY} täglich / ${PRUNE_WEEKLY} wöchentlich / ${PRUNE_MONTHLY} monatlich)."
borg prune --list --stats \
    --keep-daily="$PRUNE_DAILY" \
    --keep-weekly="$PRUNE_WEEKLY" \
    --keep-monthly="$PRUNE_MONTHLY" \
    "$BORG_REPO" || fatal "Borg Retention fehlgeschlagen."

borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nach Retention nicht lesbar."
info "Verbleibende Archive:"
borg list "$BORG_REPO"
success "Backup erfolgreich: $BACKUP_NAME"
