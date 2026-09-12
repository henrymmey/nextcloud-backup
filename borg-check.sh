#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
ENV_FILE="${ENV_FILE:-/opt/nextcloud/.env}"
LOCK_FILE="${LOCK_FILE:-/var/run/nextcloud-backup.lock}"

log() { printf '[%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}"; }
info() { log INFO "$@"; }
error() { log ERROR "$*" >&2; }
fatal() { error "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $1"; }

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

[[ "$EUID" -eq 0 ]] || fatal "Dieses Skript muss als root ausgeführt werden."
for cmd in borg flock stat awk date; do require_command "$cmd"; done
[[ -f "$ENV_FILE" ]] || fatal ".env fehlt: $ENV_FILE"
[[ "$(stat -c '%u' "$ENV_FILE")" == "0" ]] || fatal ".env muss root gehören: $ENV_FILE"
ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
(( 10#$ENV_MODE % 100 < 20 )) || fatal ".env darf nicht für Gruppe/Andere schreibbar sein."

BORG_REPO="$(env_value BORG_REPO "$ENV_FILE")"
BORG_PASSPHRASE="$(env_value BORG_PASSPHRASE "$ENV_FILE")"
BORG_RSH="$(env_value BORG_RSH "$ENV_FILE")"
: "${BORG_REPO:?BORG_REPO fehlt in .env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE fehlt in .env}"
export BORG_PASSPHRASE
[[ -n "$BORG_RSH" ]] && export BORG_RSH

exec 9>"$LOCK_FILE" || fatal "Lock-Datei kann nicht geöffnet werden: $LOCK_FILE"
flock -n 9 || fatal "Ein Backup/Restore läuft bereits."

info "Starte Borg Repository-Integritätsprüfung (Version $SCRIPT_VERSION)."
borg info "$BORG_REPO" >/dev/null || fatal "Borg Repository ist nicht erreichbar."

# --verify-data reads and authenticates archive data instead of checking metadata only.
# Run this script separately (for example weekly) because it can be expensive on large repositories.
borg check --verify-data "$BORG_REPO"

info "Borg Repository-Integritätsprüfung erfolgreich abgeschlossen."
