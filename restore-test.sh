#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/nextcloud/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-/opt/nextcloud/.env}"
APP_CONTAINER="${APP_CONTAINER:-app}"
DB_CONTAINER="${DB_CONTAINER:-db}"
NC_VOLUME="${NC_VOLUME:-nextcloud_nextcloud_html}"
RESTORE_TEST_DIR="${RESTORE_TEST_DIR:-/tmp/nextcloud-restore-test}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
BACKUP_NAME="${1:-}"

log() { printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
error() { log ERROR "$@" >&2; }
fatal() { error "$*"; exit 5; }

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n "${TEST_PROJECT:-}" && -f "${TEST_COMPOSE_FILE:-}" ]]; then
        docker compose -p "$TEST_PROJECT" -f "$TEST_COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    [[ -d "$RESTORE_TEST_DIR" ]] && rm -rf -- "$RESTORE_TEST_DIR"
    if (( rc == 0 )); then log SUCCESS "Restore-Test erfolgreich."; else error "Restore-Test fehlgeschlagen (Exit-Code $rc)."; fi
    exit "$rc"
}
trap cleanup EXIT
handle_signal() { case "$1" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; esac; }
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'handle_signal HUP' HUP

[[ "$EUID" -eq 0 ]] || fatal "Dieses Skript muss als root ausgeführt werden."
for cmd in docker borg flock mktemp find awk sed sha256sum curl date grep; do command -v "$cmd" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $cmd"; done
[[ -f "$COMPOSE_FILE" && -f "$ENV_FILE" ]] || fatal "Compose-Datei oder .env fehlt."
grep -Eq '^\s*container_name\s*:' "$COMPOSE_FILE" && fatal "restore-test verweigert Compose-Dateien mit container_name; das kann Produktionscontainer kollidieren lassen."
grep -Eq '^\s*network_mode\s*:\s*host\s*$' "$COMPOSE_FILE" && fatal "restore-test verweigert network_mode: host."
grep -Eq '^\s*ports\s*:\s*$' "$COMPOSE_FILE" && fatal "restore-test verweigert veröffentlichte Ports; für den Test muss eine portfreie Compose-Variante verwendet werden."
grep -Eq '^\s*external\s*:\s*true\s*$' "$COMPOSE_FILE" && fatal "restore-test verweigert externe Volumes/Netzwerke."
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${DB_NAME:?DB_NAME fehlt in .env}"
: "${DB_USER:?DB_USER fehlt in .env}"
: "${DB_PASSWORD:?DB_PASSWORD fehlt in .env}"
: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"
export BORG_PASSPHRASE
[[ -n "${BORG_RSH:-}" ]] && export BORG_RSH

exec 9>/var/run/nextcloud-backup.lock
flock -n 9 || fatal "Ein Backup/Restore läuft bereits."

borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nicht erreichbar."
if [[ -z "$BACKUP_NAME" ]]; then
    borg list "$BORG_REPO"
    read -rp "Welches Backup soll getestet werden? [Name]: " BACKUP_NAME
fi
[[ -n "$BACKUP_NAME" ]] || fatal "Kein Backup angegeben."
borg info "${BORG_REPO}::${BACKUP_NAME}" >/dev/null || fatal "Archiv nicht gefunden oder nicht lesbar."

rm -rf -- "$RESTORE_TEST_DIR"
mkdir -p "$RESTORE_TEST_DIR/archive" "$RESTORE_TEST_DIR/config" "$RESTORE_TEST_DIR/data" "$RESTORE_TEST_DIR/appdata" "$RESTORE_TEST_DIR/external" "$RESTORE_TEST_DIR/html" "$RESTORE_TEST_DIR/tmp"
chmod 700 "$RESTORE_TEST_DIR"

info "Extrahiere Backup in eine isolierte Testumgebung."
borg extract "${BORG_REPO}::${BACKUP_NAME}" --destination "$RESTORE_TEST_DIR/archive"
DUMP_FOUND="$(find "$RESTORE_TEST_DIR/archive" -type f -name 'nextcloud-db.sql' -print -quit)"
META_FOUND="$(find "$RESTORE_TEST_DIR/archive" -type f -name 'backup-metadata.json' -print -quit)"
[[ -s "$DUMP_FOUND" && -s "$META_FOUND" ]] || fatal "Backup-Dump oder Metadaten fehlen."

# Transform only known fixed host paths. The original Compose file is never modified.
sed \
    -e "s|/opt/nextcloud/config|$RESTORE_TEST_DIR/config|g" \
    -e "s|/mnt/hdd/nextcloud/data|$RESTORE_TEST_DIR/data|g" \
    -e "s|/mnt/ssd-working/appdata_oc464t3i6cse|$RESTORE_TEST_DIR/appdata|g" \
    -e "s|/mnt/ssd-working/nc_external_storage|$RESTORE_TEST_DIR/external|g" \
    -e "s|/mnt/ssd-working/nextcloud_tmp|$RESTORE_TEST_DIR/tmp|g" \
    -e 's/nextcloud_nextcloud_html/restore_test_html/g' \
    -e 's/nextcloud_html/restore_test_html/g' \
    "$COMPOSE_FILE" > "$RESTORE_TEST_DIR/compose.yml"
TEST_PROJECT="nextcloud-restore-test-$$"
TEST_COMPOSE_FILE="$RESTORE_TEST_DIR/compose.yml"

cp -a "$RESTORE_TEST_DIR/archive/opt/nextcloud/config/." "$RESTORE_TEST_DIR/config/"
cp -a "$RESTORE_TEST_DIR/archive/mnt/hdd/nextcloud/data/." "$RESTORE_TEST_DIR/data/"
cp -a "$RESTORE_TEST_DIR/archive/mnt/ssd-working/appdata_oc464t3i6cse/." "$RESTORE_TEST_DIR/appdata/"
cp -a "$RESTORE_TEST_DIR/archive/mnt/ssd-working/nc_external_storage/." "$RESTORE_TEST_DIR/external/"
ARCHIVE_ENV="$(find "$RESTORE_TEST_DIR/archive" -type f -path '*/opt/nextcloud/.env' -print -quit)"
[[ -s "$ARCHIVE_ENV" ]] || fatal "Archivierte .env fehlt."
cp -a "$ARCHIVE_ENV" "$RESTORE_TEST_DIR/test.env"
chmod 600 "$RESTORE_TEST_DIR/test.env"

VOLUME_ARCHIVE="$(find "$RESTORE_TEST_DIR/archive" -type d -name _data -path '*nextcloud_nextcloud_html*' -print -quit)"
if [[ -z "$VOLUME_ARCHIVE" ]]; then VOLUME_ARCHIVE="$(find "$RESTORE_TEST_DIR/archive" -type d -name _data -print -quit)"; fi
[[ -n "$VOLUME_ARCHIVE" ]] || fatal "Archiviertes Docker-Volume konnte nicht gefunden werden."

docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" up -d "$DB_CONTAINER"

deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))
while (( SECONDS < deadline )); do
    if docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d postgres >/dev/null 2>&1; then break; fi
    sleep "$POLL_INTERVAL"
done
(( SECONDS < deadline )) || fatal "Test-PostgreSQL wurde nicht bereit."

info "Importiere PostgreSQL-Dump in die Testumgebung."
docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
cat "$DUMP_FOUND" | docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME"

docker volume create "${TEST_PROJECT}_restore_test_html" >/dev/null
docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" up -d
APP_IMAGE="$(docker compose -p "$TEST_PROJECT" -f "$TEST_COMPOSE_FILE" images -q "$APP_CONTAINER" | head -n1)"
[[ -n "$APP_IMAGE" ]] || fatal "App-Image für Volume-Restore-Test konnte nicht ermittelt werden."
docker run --rm -v "${TEST_PROJECT}_restore_test_html:/dest" -v "$VOLUME_ARCHIVE:/src:ro" --entrypoint /bin/sh "$APP_IMAGE" -c 'cp -a /src/. /dest/'
docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" restart "$APP_CONTAINER"

info "Warte auf Nextcloud-Testumgebung."
deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))
while (( SECONDS < deadline )); do
    if docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ status >/dev/null 2>&1; then break; fi
    sleep "$POLL_INTERVAL"
done
(( SECONDS < deadline )) || fatal "Nextcloud-Testumgebung wurde nicht bereit."

docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T "$APP_CONTAINER" php /var/www/html/occ status
info "Prüfe PostgreSQL-Verbindung."
docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null
info "Prüfe Nextcloud HTTP innerhalb des Testcontainers."
docker compose -p "$TEST_PROJECT" --env-file "$RESTORE_TEST_DIR/test.env" -f "$TEST_COMPOSE_FILE" exec -T "$APP_CONTAINER" php -r 'exit((int)!@file_get_contents("http://127.0.0.1/status.php"));'

log SUCCESS "Backup '$BACKUP_NAME' wurde in einer separaten Compose-Umgebung erfolgreich wiederhergestellt und geprüft."
