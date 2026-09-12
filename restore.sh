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

NC_CONFIG="/opt/nextcloud/config"
NC_DATA="/mnt/hdd/nextcloud/data"
NC_APPDATA="/mnt/ssd-working/appdata_oc464t3i6cse"
NC_EXTERNAL="/mnt/ssd-working/nc_external_storage"

NC_VOLUME="nextcloud_nextcloud_html"

RESTORE_DIR="/tmp/nc-restore"

# ==========================================
# .ENV
# ==========================================

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env wurde nicht gefunden:"
    echo "$ENV_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"

: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"

export BORG_PASSPHRASE

if [[ -n "${BORG_RSH:-}" ]]; then
    export BORG_RSH
fi


# ==========================================
# ROOT
# ==========================================

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Dieses Skript muss als root ausgeführt werden."
    exit 1
fi


# ==========================================
# ARCHIV AUSWÄHLEN
# ==========================================

echo
echo "=========================================="
echo " Nextcloud Restore"
echo "=========================================="
echo

echo "Verfügbare Backups:"
echo

borg list "$BORG_REPO"

echo
read -rp "Welches Backup soll wiederhergestellt werden? [Name]: " BACKUP_NAME

if [[ -z "$BACKUP_NAME" ]]; then
    echo "[ERROR] Kein Backup angegeben."
    exit 1
fi


# ==========================================
# BESTÄTIGUNG
# ==========================================

echo
echo "WARNUNG!"
echo
echo "Das Restore überschreibt:"
echo "  - Nextcloud config"
echo "  - Nextcloud data"
echo "  - Nextcloud appdata"
echo "  - External Storage"
echo "  - Nextcloud Docker-Volume"
echo "  - PostgreSQL-Datenbank"
echo

read -rp "Wirklich fortfahren? [yes/no]: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Restore abgebrochen."
    exit 0
fi


# ==========================================
# TEMP
# ==========================================

rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"
chmod 700 "$RESTORE_DIR"


# ==========================================
# DOCKER STOPPEN
# ==========================================

echo
echo "[1/7] Stoppe Nextcloud..."

docker compose \
    -f "$COMPOSE_FILE" \
    down


# ==========================================
# VOLUME ERMITTELN
# ==========================================

echo
echo "[2/7] Ermittle Docker-Volume..."

VOLUME_PATH="$(
    docker volume inspect "$NC_VOLUME" \
        --format '{{ .Mountpoint }}'
)"

if [[ -z "$VOLUME_PATH" ]]; then
    echo "[ERROR] Docker-Volume nicht gefunden."
    exit 1
fi

echo "Volume: $VOLUME_PATH"


# ==========================================
# BACKUP EXTRAHIEREN
# ==========================================

echo
echo "[3/7] Extrahiere Backup..."

mkdir -p "$RESTORE_DIR/archive"

borg extract \
    --list \
    "${BORG_REPO}::${BACKUP_NAME}" \
    --destination "$RESTORE_DIR/archive"


# ==========================================
# PFAD DES DB-DUMPS FINDEN
# ==========================================

DUMP_FOUND="$(
    find "$RESTORE_DIR/archive" \
        -type f \
        -name "nextcloud-db.sql" \
        -print -quit
)"

if [[ -z "$DUMP_FOUND" ]]; then
    echo "[ERROR] PostgreSQL-Dump wurde im Backup nicht gefunden."
    exit 1
fi

echo
echo "PostgreSQL-Dump:"
echo "$DUMP_FOUND"


# ==========================================
# NEXTCLOUD DATEIEN RESTOREN
# ==========================================

echo
echo "[4/7] Stelle Nextcloud-Dateien wieder her..."

# Config
if [[ -d "$RESTORE_DIR/archive/opt/nextcloud/config" ]]; then
    rm -rf "$NC_CONFIG"
    mkdir -p "$NC_CONFIG"

    cp -a \
        "$RESTORE_DIR/archive/opt/nextcloud/config/." \
        "$NC_CONFIG/"
fi


# Data
if [[ -d "$RESTORE_DIR/archive/mnt/hdd/nextcloud/data" ]]; then
    rm -rf "$NC_DATA"
    mkdir -p "$NC_DATA"

    cp -a \
        "$RESTORE_DIR/archive/mnt/hdd/nextcloud/data/." \
        "$NC_DATA/"
fi


# Appdata
if [[ -d "$RESTORE_DIR/archive/mnt/ssd-working/appdata_oc464t3i6cse" ]]; then
    rm -rf "$NC_APPDATA"
    mkdir -p "$NC_APPDATA"

    cp -a \
        "$RESTORE_DIR/archive/mnt/ssd-working/appdata_oc464t3i6cse/." \
        "$NC_APPDATA/"
fi


# External Storage
if [[ -d "$RESTORE_DIR/archive/mnt/ssd-working/nc_external_storage" ]]; then
    rm -rf "$NC_EXTERNAL"
    mkdir -p "$NC_EXTERNAL"

    cp -a \
        "$RESTORE_DIR/archive/mnt/ssd-working/nc_external_storage/." \
        "$NC_EXTERNAL/"
fi


# ==========================================
# DOCKER VOLUME RESTOREN
# ==========================================

echo
echo "[5/7] Stelle Docker-Volume wieder her..."

if [[ -d "$RESTORE_DIR/archive${VOLUME_PATH}" ]]; then

    rm -rf "${VOLUME_PATH:?}/"*

    cp -a \
        "$RESTORE_DIR/archive${VOLUME_PATH}/." \
        "$VOLUME_PATH/"

else
    echo "[WARNUNG] Docker-Volume-Pfad wurde im Backup nicht gefunden:"
    echo "$VOLUME_PATH"
fi


# ==========================================
# DOCKER STARTEN
# ==========================================

echo
echo "[6/7] Starte PostgreSQL..."

docker compose \
    -f "$COMPOSE_FILE" \
    up -d db

echo "Warte auf PostgreSQL..."

for i in {1..60}; do

    if docker compose \
        -f "$COMPOSE_FILE" \
        exec -T "$DB_CONTAINER" \
        pg_isready \
            -U "$DB_USER" \
            -d "$DB_NAME" >/dev/null 2>&1
    then
        break
    fi

    if [[ "$i" -eq 60 ]]; then
        echo "[ERROR] PostgreSQL wurde nicht bereit."
        exit 1
    fi

    sleep 2

done


# ==========================================
# DATENBANK LEEREN
# ==========================================

echo
echo "Leere vorhandene Nextcloud-Datenbank..."

docker compose \
    -f "$COMPOSE_FILE" \
    exec -T "$DB_CONTAINER" \
    psql \
        -U "$DB_USER" \
        -d postgres \
        -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" \
        -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"


# ==========================================
# SQL RESTORE
# ==========================================

echo
echo "Stelle PostgreSQL-Datenbank wieder her..."

cat "$DUMP_FOUND" | \
docker compose \
    -f "$COMPOSE_FILE" \
    exec -T "$DB_CONTAINER" \
    psql \
        -U "$DB_USER" \
        -d "$DB_NAME"


# ==========================================
# NEXTCLOUD STARTEN
# ==========================================

echo
echo "[7/7] Starte Nextcloud..."

docker compose \
    -f "$COMPOSE_FILE" \
    up -d


# ==========================================
# WARTEN
# ==========================================

echo
echo "Warte auf Nextcloud..."

sleep 15


# ==========================================
# STATUS
# ==========================================

docker compose \
    -f "$COMPOSE_FILE" \
    ps


echo
echo "=========================================="
echo " RESTORE ABGESCHLOSSEN"
echo "=========================================="
echo

echo "Backup:"
echo "$BACKUP_NAME"
echo

echo "Bitte Nextcloud prüfen."
echo
