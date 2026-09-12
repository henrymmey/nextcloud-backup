# Restore Guide

`restore.sh` ist ein vollständiger Restore und kein Werkzeug zum Wiederherstellen einzelner Dateien. Es darf nur mit bewusst ausgewähltem Recovery Point und ausreichendem Rollback-/Backup-Plan eingesetzt werden.

## Sicherheitsmodell

Der gefährliche Ablauf

```text
rm -rf produktive_daten
restore
```

wird vermieden.

Stattdessen:

```text
Borg-Archiv auswählen
        ↓
Archiv + Dump + Metadaten validieren
        ↓
Compose stoppen
        ↓
aktuellen DB-Zustand als Rollback-Dump sichern
        ↓
alle Restore-Daten vorbereiten
        ↓
Dateien kontrolliert umschalten
        ↓
PostgreSQL bereit machen
        ↓
DB neu erstellen + Dump importieren
        ↓
Nextcloud starten
        ↓
occ status + HTTP-Healthcheck
        ↓
Erfolg → Rollback-Zustand löschen
```

Bis zur Archivvalidierung werden keine Produktionsdaten verändert.

## Voraussetzungen

- root
- Docker Engine
- Docker Compose v2
- BorgBackup
- `curl`
- Zugriff auf das Borg Repository
- Borg-Passphrase
- initiale `.env` und Compose-Datei
- genügend Speicher für extrahiertes Archiv und Rollback-DB-Dump

## Restore starten

```bash
sudo /opt/nextcloud/restore.sh
```

Das Skript prüft zuerst das gewünschte Archiv mit `borg info`, extrahiert es anschließend temporär und validiert:

- PostgreSQL-Dump vorhanden und nicht leer
- Metadaten vorhanden
- Dumpgröße und SHA-256 passend zu den Metadaten
- Compose-Datei und `.env` passend zu den Metadaten
- erwartete Datenpfade vorhanden
- Docker-Volume vorhanden
- initiale DB-Zugangsdaten passend zur archivierten `.env`

Erst danach wird eine explizite Eingabe von `yes` verarbeitet und der produktive Zustand verändert.

## Rollback

Vor dem Austausch der produktiven Dateien wird die aktuelle PostgreSQL-Datenbank als SQL-Dump gesichert. Außerdem werden vorhandene Dateien und das Docker-Volume in einem privaten temporären Rollback-Verzeichnis aufbewahrt.

Bei einem Fehler nach dem Umschalten versucht das Skript:

1. die Datenbank aus dem Rollback-Dump wiederherzustellen
2. die vorherigen Dateien und das Docker-Volume zurückzusetzen
3. den Stack wieder zu starten, wenn er vorher lief

Ein Rollback ist eine Schutzmaßnahme, keine Garantie. Stromausfall, defektes Dateisystem oder fehlender Speicher können auch einen Rollback verhindern. Ein externes Backup bleibt zwingend erforderlich.

## PostgreSQL-Restore

Das Skript:

1. startet PostgreSQL
2. wartet mit `pg_isready` auf echte Bereitschaft
3. beendet bestehende Verbindungen zur Ziel-DB
4. erstellt die Datenbank neu
5. importiert mit `psql -v ON_ERROR_STOP=1`
6. prüft anschließend erneut die DB-Verbindung

Es gibt keine feste `sleep 15`-Annahme.

`DB_NAME` und `DB_USER` werden auf sichere SQL-Identifier-Zeichen beschränkt.

## Nextcloud-Healthcheck

Nach dem Start wird auf:

```bash
docker compose exec -T app php /var/www/html/occ status
```

und zusätzlich auf einen HTTP-Request gegen:

```env
HEALTHCHECK_URL=http://127.0.0.1/status.php
```

gewartet.

Timeout und Polling sind konfigurierbar:

```env
HEALTHCHECK_TIMEOUT=120
POLL_INTERVAL=2
```

## Konfiguration

Ein Recovery Point enthält die originale:

```text
docker-compose.yml
.env
```

Die archivierte `.env` wird **nicht als Shell-Code eingelesen**, da sie als Backupdaten untrusted ist. Docker Compose verwendet sie nach dem kontrollierten Austausch als Konfiguration.

Die initialen DB-Zugangsdaten müssen mit dem archivierten Recovery Point übereinstimmen. Das verhindert, dass versehentlich ein Restore in eine nicht passende Datenbankumgebung ausgeführt wird.

## Disaster Recovery

Bei komplettem Serververlust:

```text
Neuer Server
    ↓
Linux installieren
    ↓
Docker + Compose v2 installieren
    ↓
Borg installieren
    ↓
SSH-Key wiederherstellen
    ↓
Borg-Passphrase aus unabhängigem Speicher holen
    ↓
/opt/nextcloud + Mountpoints anlegen
    ↓
initiale .env + Compose bereitstellen
    ↓
borg list "$BORG_REPO"
    ↓
restore.sh
    ↓
Healthchecks
```

Danach mindestens Login, Benutzer, Dateien, Upload/Download, AppData, External Storage, Background Jobs und Reverse Proxy/HTTPS prüfen.

## Restore-Test

Zerstörungsfreier Test:

```bash
sudo /opt/nextcloud/restore-test.sh
```

oder:

```bash
sudo /opt/nextcloud/restore-test.sh nextcloud-YYYY-MM-DD_HH-MM-SS
```

Der Test verwendet ein eigenes Compose-Projekt, eigene Bind-Mounts und ein eigenes Docker-Volume. Die Produktionspfade werden nicht als Restore-Ziele verwendet.

Der Test verweigert Compose-Dateien mit `container_name:`, `network_mode: host`, veröffentlichten Ports oder externen Volumes/Netzwerken, weil eine sichere Isolation sonst nicht garantiert werden kann.

## Nach dem Restore

```bash
docker compose ps
docker compose exec -T app php /var/www/html/occ status
docker compose exec -T db pg_isready -U "$DB_USER" -d "$DB_NAME"
```

Zusätzlich manuell prüfen:

- Login
- vorhandene Benutzer
- Dateien öffnen
- Upload/Download
- AppData
- External Storage
- Sharing
- Background Jobs
- Reverse Proxy/HTTPS
- Container-Logs

Danach ein neues Backup erstellen.

## Grenzen

- PostgreSQL-/Nextcloud-/Compose-Versionen müssen zum Recovery Point kompatibel sein.
- Ein lokaler Mountpoint eines entfernten External Storages sichert nicht automatisch das entfernte System.
- Ein Rollback kann bei Hardware-/Filesystemfehlern scheitern.
- Ein HTTP-Healthcheck ersetzt keine vollständige manuelle Funktionsprüfung.
- Der Restore-Test simuliert nicht DNS, TLS-Zertifikate, Reverse Proxy oder externe Storage-Systeme vollständig.
