# Restore und Disaster Recovery

Diese Anleitung erklärt, wie du eine Nextcloud aus einem vorhandenen Borg-Backup wiederherstellst.

> **Achtung:** `restore.sh` ist ein vollständiger Restore. Dabei werden die aktuelle Datenbank und produktive Dateien ersetzt. Verwende das Skript nur, wenn du bewusst einen bestimmten Backup-Stand wiederherstellen möchtest.

Für einen normalen Test eines Backups verwende stattdessen `restore-test.sh`.

## 1. Wann brauche ich einen Restore?

Ein Restore kann beispielsweise notwendig sein, wenn:

- Dateien versehentlich gelöscht wurden
- die Nextcloud-Installation beschädigt wurde
- die Datenbank beschädigt wurde
- nach einem größeren Fehler ein älterer Stand benötigt wird
- ein kompletter Server neu aufgebaut werden muss

Ein einzelnes Dokument wird dabei nicht separat wiederhergestellt. `restore.sh` stellt den ausgewählten Recovery Point als gesamten Nextcloud-Zustand wieder her.

## 2. Voraussetzungen

Vor dem Restore müssen vorhanden sein:

- Root-Zugriff auf den Nextcloud-Server
- Docker Engine
- Docker Compose v2
- BorgBackup
- Zugriff auf das Borg-Repository
- Borg-Passphrase
- SSH-Zugang zum Backup-Repository, falls erforderlich
- die initiale `.env`
- eine passende Docker-Compose-Konfiguration
- ausreichend freier Speicher für Archiv und Rollback-Daten

Bei einem komplett zerstörten Server müssen diese Voraussetzungen zuerst auf dem neuen System eingerichtet werden.

## 3. Vor dem Restore

**Wenn der aktuelle Server noch funktioniert, erstelle nach Möglichkeit ein aktuelles Backup.**

Prüfe außerdem:

```bash
docker compose ps
borg list "$BORG_REPO"
```

Wenn möglich, sollte der gewünschte Recovery Point vorher eindeutig festgelegt werden.

## 4. Restore starten

Starte:

```bash
sudo /opt/nextcloud/restore.sh
```

Das Skript zeigt die verfügbaren Borg-Archive an. Wähle den gewünschten Recovery Point aus und bestätige den eigentlichen Restore anschließend ausdrücklich mit `yes`.

Bis zur Archivprüfung werden keine produktiven Daten verändert.

## 5. Was prüft das Skript?

Vor dem eigentlichen Restore wird unter anderem geprüft:

- Borg-Archiv ist erreichbar
- Archiv enthält die erwarteten Dateien
- PostgreSQL-Dump ist vorhanden und nicht leer
- Dump-Größe und SHA-256 passen zu den Metadaten
- Compose-Datei und `.env` passen zu den gespeicherten Metadaten
- benötigte Nextcloud-Pfade sind vorhanden
- Docker-Volume ist vorhanden
- Datenbank-Zugangsdaten passen zur gespeicherten Konfiguration

Die archivierte `.env` wird dabei nicht als Shell-Skript ausgeführt.

## 6. Was passiert beim Restore?

Der Ablauf sieht vereinfacht so aus:

```text
Recovery Point auswählen
        ↓
Archiv vollständig prüfen
        ↓
aktuellen Zustand vorbereiten
        ↓
aktuellen PostgreSQL-Zustand als Rollback-Dump sichern
        ↓
Nextcloud/Compose kontrolliert stoppen
        ↓
Backup-Dateien bereitstellen
        ↓
Dateien und Docker-Volume umschalten
        ↓
PostgreSQL starten
        ↓
Datenbank neu erstellen
        ↓
SQL-Dump importieren
        ↓
Nextcloud starten
        ↓
occ status + HTTP prüfen
        ↓
Erfolg → Rollback-Daten löschen
```

Es gibt keine feste Wartezeit wie `sleep 15`. Stattdessen wartet das Skript mit Readiness-Prüfungen auf PostgreSQL und Nextcloud.

## 7. Rollback-Schutz

Vor dem Austausch des produktiven Zustands wird die aktuelle PostgreSQL-Datenbank als SQL-Dump gesichert. Außerdem werden vorhandene Dateien und das Docker-Volume in einem temporären Rollback-Verzeichnis aufbewahrt.

Wenn der Restore nach dem Umschalten fehlschlägt, versucht das Skript:

1. die vorherige Datenbank wiederherzustellen
2. die vorherigen Dateien wiederherzustellen
3. das vorherige Docker-Volume wiederherzustellen
4. den Compose-Stack wieder zu starten, wenn er vorher lief

Ein Rollback ist **keine Garantie**. Bei beispielsweise einem Stromausfall, einem defekten Dateisystem oder fehlendem Speicher kann auch das Rollback scheitern. Deshalb sind zusätzliche externe Backups wichtig.

## 8. PostgreSQL

Beim Datenbank-Restore wird:

1. PostgreSQL gestartet
2. mit `pg_isready` auf Bereitschaft gewartet
3. die Ziel-Datenbank neu erstellt
4. der SQL-Dump mit `ON_ERROR_STOP=1` importiert
5. die Verbindung erneut geprüft

Die verwendete PostgreSQL-Version sollte mit dem Backup bzw. der Nextcloud-Installation kompatibel sein.

## 9. Nextcloud prüfen

Nach dem Restore prüft das Skript unter anderem:

```bash
docker compose exec -T app php /var/www/html/occ status
```

Zusätzlich wird die konfigurierte URL geprüft:

```env
HEALTHCHECK_URL=http://127.0.0.1/status.php
```

Timeout und Polling können angepasst werden:

```env
HEALTHCHECK_TIMEOUT=120
POLL_INTERVAL=2
```

## 10. Nach dem Restore manuell prüfen

Auch wenn das Skript erfolgreich endet, sollte Nextcloud manuell geprüft werden:

- Anmeldung funktioniert
- Benutzer sind vorhanden
- Dateien lassen sich öffnen
- Upload funktioniert
- Download funktioniert
- AppData funktioniert
- External Storage funktioniert
- Freigaben funktionieren
- Background Jobs funktionieren
- Reverse Proxy und HTTPS funktionieren
- Docker-Logs enthalten keine neuen kritischen Fehler

Danach sollte möglichst bald wieder ein neues Backup erstellt werden.

## 11. Restore-Test ohne produktive Daten zu ersetzen

Wenn du nur überprüfen möchtest, ob ein Backup grundsätzlich wiederherstellbar ist, verwende:

```bash
sudo /opt/nextcloud/restore-test.sh
```

Oder für ein bestimmtes Archiv:

```bash
sudo /opt/nextcloud/restore-test.sh nextcloud-YYYY-MM-DD_HH-MM-SS
```

Der Test verwendet ein eigenes Compose-Projekt, eigene temporäre Bind-Mounts und ein eigenes Docker-Volume.

Der Test ist absichtlich eingeschränkt und verweigert unter anderem Compose-Dateien mit:

- `container_name:`
- `network_mode: host`
- veröffentlichten Ports
- externen Volumes oder Netzwerken

Damit soll verhindert werden, dass ein vermeintlich isolierter Test versehentlich die produktive Umgebung beeinflusst.

## 12. Kompletter Serververlust

Wenn der gesamte Server ausgefallen ist:

```text
Neuen Server bereitstellen
        ↓
Linux installieren
        ↓
Docker + Compose v2 installieren
        ↓
BorgBackup installieren
        ↓
SSH-Zugang zum Backup-Repository wiederherstellen
        ↓
Borg-Passphrase bereitstellen
        ↓
Mountpoints + Compose vorbereiten
        ↓
.env bereitstellen
        ↓
borg list "$BORG_REPO"
        ↓
restore.sh
        ↓
Nextcloud prüfen
        ↓
neues Backup erstellen
```

Die Borg-Passphrase, der SSH-Zugang und die benötigten Zugangsdaten dürfen deshalb nicht ausschließlich auf dem ursprünglichen Server gespeichert werden.

## 13. Wichtige Grenzen

- `restore.sh` ist kein Werkzeug für einzelne Dateien.
- PostgreSQL-, Nextcloud- und Compose-Versionen müssen kompatibel sein.
- Ein lokaler Mountpoint eines entfernten External Storages bedeutet nicht automatisch, dass das entfernte System gesichert wurde.
- Der HTTP-Healthcheck ersetzt keine vollständige manuelle Prüfung.
- Der Restore-Test bildet DNS, TLS, Reverse Proxy und externe Storage-Systeme nicht vollständig nach.
- Die tatsächliche `docker-compose.yml` muss zur erwarteten Struktur des Projekts passen.

## Weiterführend

Für die Einrichtung und den normalen Backup-Betrieb siehe **[BACKUP.md](BACKUP.md)**.

Für einen Test des Backups ohne produktiven Restore verwende **`restore-test.sh`**.
