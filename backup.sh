#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# KONFIGURATION
# ==========================================

COMPOSE_DIR="/opt/nextcloud"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"

APP_CONTAINER="app"
DB_CONTAINER="db"

# Nextcloud
NC_CONFIG="/opt/nextcloud/config"
NC_DATA="/mnt/hdd/nextcloud/data"
NC_APPDATA="/mnt/ssd-working/appdata_oc464t3i6cse"
NC_EXTERNAL="/mnt/ssd-working/nc_external_storage"

# Docker-Volume
NC_VOLUME="nextcloud_nextcloud_html"

# Temporärer PostgreSQL-Dump
DUMP_DIR="/tmp/nc-backup"
DUMP_FILE="${DUMP_DIR}/nextcloud-db.sql"

# Lock
LOCK_FILE="/var/run/nextcloud-backup.lock"

# Status
MAINTENANCE_ENABLED=false


# ==========================================
# FUNKTIONEN
# ==========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


error_handler() {
    local exit_code=$?

    echo
    echo "=========================================="
    echo " BACKUP FEHLGESCHLAGEN"
    echo "=========================================="
    echo

    if [[ "$MAINTENANCE_ENABLED" == "true" ]]; then
        log "Deaktiviere Nextcloud Wartungsmodus..."

        docker compose \
            -f "$COMPOSE_FILE" \
            exec -T "$APP_CONTAINER" \
            php /var/www/html/occ maintenance:mode --off \
            || log "WARNUNG: Wartungsmodus konnte nicht deaktiviert werden."
    fi

    rm -f "$DUMP_FILE"

    exit "$exit_code"
}


cleanup_success() {
    log "Deaktiviere Nextcloud Wartungsmodus..."

    docker compose \
        -f "$COMPOSE_FILE" \
        exec -T "$APP_CONTAINER" \
        php /var/www/html/occ maintenance:mode --off

    MAINTENANCE_ENABLED=false

    log "Entferne temporären Datenbank-Dump..."
    rm -f "$DUMP_FILE"
}


trap error_handler ERR


# ==========================================
# .ENV LADEN
# ==========================================

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env wurde nicht gefunden:"
    echo "$ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"


# ==========================================
# VARIABLEN PRÜFEN
# ==========================================

: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"

: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"


# ==========================================
# BORG
# ==========================================

export BORG_PASSPHRASE

if [[ -n "${BORG_RSH:-}" ]]; then
    export BORG_RSH
fi


# ==========================================
# VORBEREITUNG
# ==========================================

cd "$COMPOSE_DIR"

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"


# ==========================================
# LOCK
# ==========================================

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "[ERROR] Es läuft bereits ein Nextcloud-Backup."
    exit 1
fi


# ==========================================
# START
# ==========================================

echo
echo "=========================================="
echo " Nextcloud Docker Backup"
echo "=========================================="
echo

log "Prüfe Docker Compose..."

docker compose \
    -f "$COMPOSE_FILE" \
    ps


# ==========================================
# EXISTENZPRÜFUNGEN
# ==========================================

log "Prüfe Backup-Verzeichnisse..."

for path in \
    "$COMPOSE_FILE" \
    "$NC_CONFIG" \
    "$NC_DATA" \
    "$NC_APPDATA" \
    "$NC_EXTERNAL"
do
    if [[ ! -e "$path" ]]; then
        echo "[ERROR] Pfad nicht gefunden:"
        echo "$path"
        exit 1
    fi
done


# ==========================================
# DOCKER-VOLUME
# ==========================================

log "Ermittle Docker-Volume..."

VOLUME_PATH="$(
    docker volume inspect "$NC_VOLUME" \
        --format '{{ .Mountpoint }}'
)"

if [[ -z "$VOLUME_PATH" || ! -d "$VOLUME_PATH" ]]; then
    echo "[ERROR] Docker-Volume konnte nicht gefunden werden:"
    echo "$NC_VOLUME"
    exit 1
fi

log "Docker-Volume:"
log "$VOLUME_PATH"


# ==========================================
# BORG REPOSITORY
# ==========================================

log "Prüfe Borg Repository..."

borg info "$BORG_REPO" >/dev/null

log "Borg Repository erreichbar."


# ==========================================
# 1. WARTUNGSMODUS
# ==========================================

echo
echo "[1/5] Aktiviere Nextcloud Wartungsmodus..."

docker compose \
    -f "$COMPOSE_FILE" \
    exec -T "$APP_CONTAINER" \
    php /var/www/html/occ maintenance:mode --on

MAINTENANCE_ENABLED=true


# ==========================================
# 2. POSTGRESQL DUMP
# ==========================================

echo
echo "[2/5] Erstelle PostgreSQL-Dump..."

PGPASSWORD="$DB_PASSWORD" \
docker compose \
    -f "$COMPOSE_FILE" \
    exec -T \
    -e PGPASSWORD="$DB_PASSWORD" \
    "$DB_CONTAINER" \
    pg_dump \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        --format=plain \
        --no-owner \
        --no-privileges \
    > "$DUMP_FILE"

chmod 600 "$DUMP_FILE"

log "PostgreSQL-Dump erstellt:"
ls -lh "$DUMP_FILE"


# ==========================================
# 3. BORG BACKUP
# ==========================================

echo
echo "[3/5] Erstelle Borg-Backup..."

BACKUP_NAME="nextcloud-{now:%Y-%m-%d_%H-%M-%S}"

borg create \
    --stats \
    --progress \
    --compression zstd \
    "${BORG_REPO}::${BACKUP_NAME}" \
    "$COMPOSE_FILE" \
    "$NC_CONFIG" \
    "$NC_DATA" \
    "$NC_APPDATA" \
    "$NC_EXTERNAL" \
    "$VOLUME_PATH" \
    "$DUMP_FILE"

log "Borg Backup erfolgreich erstellt."


# ==========================================
# 4. RETENTION
# ==========================================

echo
echo "[4/5] Lösche alte Backups gemäß Retention..."

borg prune \
    --list \
    --stats \
    --keep-daily=7 \
    --keep-weekly=4 \
    --keep-monthly=12 \
    "$BORG_REPO"

log "Borg Retention abgeschlossen."


# ==========================================
# 5. AUFRÄUMEN
# ==========================================

echo
echo "[5/5] Cleanup..."

cleanup_success


# ==========================================
# ERFOLG
# ==========================================

echo
echo "=========================================="
echo " BACKUP ERFOLGREICH"
echo "=========================================="
echo

echo "Gesichert:"
echo "  - docker-compose.yml"
echo "  - Nextcloud config"
echo "  - Nextcloud data"
echo "  - Nextcloud appdata"
echo "  - Nextcloud external storage"
echo "  - Nextcloud Docker-Volume"
echo "  - PostgreSQL SQL-Dump"
echo

echo "Nicht gesichert:"
echo "  - nextcloud_tmp (temporär)"
echo "  - PostgreSQL-Datenverzeichnis (SQL-Dump wird verwendet)"
echo

echo "Borg Repository:"
echo "$BORG_REPO"
echo
