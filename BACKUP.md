# Backup Guide

`backup.sh` härtet das bestehende Borg-/PostgreSQL-Backup, ohne das Grundkonzept zu ändern.

## Ablauf

```text
Preflight
  ↓
Lock
  ↓
Docker/Compose/DB/Borg/Pfade prüfen
  ↓
temporären Speicher prüfen
  ↓
Maintenance Mode ON
  ↓
pg_dump
  ↓
Dumpgröße + SHA-256 prüfen
  ↓
Metadaten erzeugen
  ↓
Borg create (zstd + Repository-Verschlüsselung)
  ↓
borg info + borg list des neuen Archives
  ↓
optional gespeicherten Dump aus Borg lesen und Hash prüfen
  ↓
Retention
  ↓
Archive erneut listen
  ↓
Maintenance Mode OFF + temporäre Daten löschen
```

## Preflight

Vor dem Maintenance Mode werden geprüft:

- Bash und benötigte Werkzeuge
- Docker Engine
- Docker Compose v2
- BorgBackup
- Compose-Datei und Compose-Syntax
- laufender Compose-Stack und `occ status`
- alle konfigurierten Datenpfade
- Docker-Volume
- Borg Repository
- PostgreSQL mit `pg_isready`
- PostgreSQL-Datenbankgröße
- freier temporärer Speicher
- benötigte Variablen aus `.env`

Bei einem Preflight-Fehler startet kein Backup.

## PostgreSQL

Der Dump wird innerhalb des PostgreSQL-Containers erstellt:

```bash
pg_dump -U "$DB_USER" -d "$DB_NAME" \
  --format=plain \
  --no-owner \
  --no-privileges
```

Danach werden Exit-Code, Existenz und Größe geprüft. Ein leerer Dump wird abgelehnt. Zusätzlich wird ein SHA-256-Hash in die Metadaten geschrieben und der gespeicherte Dump kann direkt aus dem neuen Borg-Archiv gelesen und erneut gehasht werden.

Das ist ein logischer Dump und damit unabhängig von PostgreSQLs internem Datenverzeichnis. Die verwendete PostgreSQL-Version wird in den Metadaten dokumentiert; beim Restore sollte eine kompatible PostgreSQL-Version verwendet werden.

## Maintenance Mode und Fehler

Maintenance Mode wird vor `pg_dump` aktiviert und bleibt aktiv, bis das Borg-Archiv erstellt und validiert wurde.

Ein `EXIT`-Cleanup sowie Handler für `SIGINT`, `SIGTERM` und `SIGHUP` versuchen immer:

1. Maintenance Mode zu deaktivieren
2. temporäre Dumps/Metadaten zu löschen
3. einen korrekten Exit-Code zurückzugeben

Damit soll insbesondere ein abgebrochener Backup-Lauf nicht dauerhaft in Maintenance Mode hängen bleiben.

## Gesicherte Daten

Das Backup enthält weiterhin:

```text
/opt/nextcloud/docker-compose.yml
/opt/nextcloud/.env
/opt/nextcloud/config
/mnt/hdd/nextcloud/data
/mnt/ssd-working/appdata_oc464t3i6cse
/mnt/ssd-working/nc_external_storage
<aktueller Mountpoint des Docker-Volumes nextcloud_nextcloud_html>
<temporärer PostgreSQL-Dump>
<Backup-Metadaten>
```

Das PostgreSQL-Live-Datenverzeichnis und Redis-Runtime-Daten werden nicht als Dateikopie gesichert.

### Redundanz

Docker-Volume und Bind-Mounts können Teile desselben Nextcloud-Baums enthalten. Diese Redundanz wird nicht automatisch entfernt, weil sie die unabhängige Wiederherstellbarkeit verbessert. Eine Reduktion darf erst nach Prüfung der tatsächlichen Compose-Mounts erfolgen.

Ein lokaler Mountpoint eines entfernten External Storages ist nicht automatisch ein Backup des entfernten Systems.

## Metadaten

`backup-metadata.json` dokumentiert:

- Zeitpunkt
- Hostname
- Nextcloud-Version
- PostgreSQL-Version
- Docker-Version
- Compose-Version
- SHA-256 der Compose-Datei
- SHA-256 der `.env`
- Backup-Skript-Version
- Dumpgröße
- Dump-SHA-256

Secrets selbst werden nicht in die Metadaten geschrieben.

## Borg-Validierung

Nach `borg create` werden mindestens ausgeführt:

```bash
borg info "$BORG_REPO::ARCHIV"
borg list "$BORG_REPO::ARCHIV"
```

Das Skript prüft, dass die erwarteten Pfade im Archiv vorhanden sind. Optional (`VERIFY_ARCHIVE_DATA=true`, Standard) wird der gespeicherte SQL-Dump zusätzlich aus dem Archiv gelesen und mit dem während `pg_dump` berechneten Hash verglichen.

Ein vollständiges:

```bash
borg check "$BORG_REPO"
```

wird nicht nach jedem Backup ausgeführt. Es sollte regelmäßig, z. B. monatlich, erfolgen.

## Retention

Die bestehende Retention bleibt:

```text
7 täglich
4 wöchentlich
12 monatlich
```

`borg prune` läuft erst nach erfolgreicher Erstellung und Validierung des neuen Archives. Danach wird das Repository erneut gelistet.

## Logging

Log-Level:

```text
INFO
WARN
ERROR
SUCCESS
```

Repository- und Archivnamen dürfen geloggt werden. Passwörter, Borg-Passphrasen, Tokens und private Schlüssel dürfen nicht geloggt werden.

## Tests

```bash
bash -n backup.sh
shellcheck backup.sh
```

Zusätzlich sollte regelmäßig ein vollständiger Restore in einer getrennten Testumgebung ausgeführt werden:

```bash
sudo /opt/nextcloud/restore-test.sh
```

