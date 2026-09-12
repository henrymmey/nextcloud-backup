# Nextcloud Backup & Restore

Bash-basierte, produktionsorientierte Backup- und Restore-Lösung für eine Docker-Compose-Nextcloud mit BorgBackup und PostgreSQL.

Das Projekt behält bewusst das bestehende Konzept bei:

- BorgBackup mit Zstandard und Repository-Verschlüsselung
- PostgreSQL `pg_dump`
- Nextcloud Maintenance Mode während des Backups
- Remote-Borg-Repository über SSH
- `flock` gegen parallele Ausführung
- Borg Retention: 7 täglich / 4 wöchentlich / 12 monatlich
- Docker-Volume + bind-mounted Nextcloud-Daten

Die Skripte sind weiterhin auf eine konkrete Nextcloud-Installation zugeschnitten. Die Standardpfade stehen oben in den Skripten und können per Umgebungsvariable überschrieben werden.

## Was wurde verbessert?

Das bestehende Backup-System wurde gehärtet, nicht durch ein neues System ersetzt:

- Preflight-Checks vor Maintenance Mode und Backup
- robuste Fehler-/Signalbehandlung mit Cleanup
- PostgreSQL-Dump wird auf Exit-Code, Existenz, Größe und Hash geprüft
- jedes Backup erhält automatisch `backup-metadata.json`
- neues Borg-Archiv wird mit `borg info` und `borg list` validiert
- optional wird der gespeicherte SQL-Dump direkt aus dem Borg-Archiv gelesen und erneut gehasht
- `.env` wird für Disaster Recovery mitgesichert, aber niemals in Git
- Restore validiert Archiv, Dump und Metadaten vor Änderungen
- Restore erstellt einen lokalen Rollback-Zustand inklusive DB-Dump
- Restore verwendet echte Readiness-Prüfungen statt einer festen 15-Sekunden-Wartezeit
- `occ status` und HTTP werden nach Restore geprüft
- `restore-test.sh` testet einen vollständigen Restore isoliert
- temporäre Dateien werden über `mktemp` und Cleanup entfernt
- Logging gibt keine Passphrasen oder Passwörter aus

## Dateien

| Datei | Zweck |
| --- | --- |
| `backup.sh` | Backup, Validierung, Retention und Cleanup |
| `restore.sh` | Validierter, rollbackfähiger Restore |
| `restore-test.sh` | Vollständiger Restore-Test in einer isolierten Compose-Umgebung |
| `.env.example` | Beispielkonfiguration |
| `.gitignore` | Verhindert versehentliches Committen sensibler Dateien |
| `BACKUP.md` | Backup-/Betriebsdokumentation |
| `RESTORE.md` | Restore- und Disaster-Recovery-Anleitung |

## Konfiguration

Auf dem Nextcloud-Server:

```bash
cp .env.example /opt/nextcloud/.env
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

Mindestens erforderlich:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=...

BORG_REPO=user@backup-server:/path/to/repository
BORG_PASSPHRASE=...

# optional
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

Für Restore-Healthchecks können zusätzlich gesetzt werden:

```env
HEALTHCHECK_URL=http://127.0.0.1/status.php
HEALTHCHECK_TIMEOUT=120
POLL_INTERVAL=2
```

**Die echte `.env` darf niemals in Git eingecheckt werden.** Sie wird im Borg-Archiv mitgesichert und liegt dort innerhalb des verschlüsselten Repositories. Für Disaster Recovery muss trotzdem eine separate Kopie der Zugangsdaten und der Borg-Passphrase existieren.

## Was wird gesichert?

Das Backup enthält:

- `/opt/nextcloud/docker-compose.yml`
- `/opt/nextcloud/.env`
- `/opt/nextcloud/config`
- `/mnt/hdd/nextcloud/data`
- `/mnt/ssd-working/appdata_oc464t3i6cse`
- `/mnt/ssd-working/nc_external_storage`
- das Docker-Volume `nextcloud_nextcloud_html`
- einen PostgreSQL-Plain-SQL-Dump
- automatisch erzeugte Backup-Metadaten

Nicht als persistenter Zustand gesichert werden weiterhin PostgreSQLs Live-Datenverzeichnis und Redis-Runtime-Daten. Das PostgreSQL-Datenverzeichnis wird nicht als rohe Dateikopie gesichert; der logische Dump ist die Restore-Quelle.

### Redundanz

Das Docker-Volume und einige Host-Verzeichnisse können sich durch Docker-Bind-Mounts teilweise überschneiden. Diese Redundanz wird **nicht automatisch entfernt**, weil sie die unabhängige Wiederherstellbarkeit verbessert. Eine Reduktion darf erst nach Prüfung der tatsächlichen Compose-Mounts erfolgen.

Remote External Storage wird nur dann vollständig gesichert, wenn die Daten tatsächlich auf dem angegebenen lokalen Pfad liegen. Ein bloßer Mountpoint ist kein Backup eines entfernten Systems.

## Backup-Metadaten

Jedes Archiv enthält `backup-metadata.json` mit u. a.:

```json
{
  "timestamp": "...",
  "hostname": "...",
  "nextcloud_version": "...",
  "postgres_version": "...",
  "docker_version": "...",
  "compose_version": "...",
  "compose_file_hash": "...",
  "env_file_hash": "...",
  "backup_script_version": "2.0.0",
  "postgres_dump_size": 123456,
  "postgres_dump_sha256": "..."
}
```

Secrets selbst werden nicht in die Metadaten geschrieben.

## Backup ausführen

```bash
sudo /opt/nextcloud/backup.sh
```

Ein erfolgreicher Lauf endet mit `SUCCESS` und der Archiv-ID. Das Skript listet nach dem Prune die verbleibenden Archive.

## Restore ausführen

**Nicht auf einem produktiven Server testen.** `restore.sh` ist für einen kontrollierten vollständigen Restore gedacht.

```bash
sudo /opt/nextcloud/restore.sh
```

Der Ablauf ist:

```text
Borg-Archiv auswählen
        ↓
Archiv + Metadaten + Dump validieren
        ↓
Compose stoppen
        ↓
Rollback-Dump der aktuellen DB erstellen
        ↓
Restore-Dateien vollständig vorbereiten
        ↓
Produktive Pfade umschalten
        ↓
PostgreSQL starten und prüfen
        ↓
Datenbank neu erstellen + Dump importieren
        ↓
Nextcloud starten
        ↓
occ status + HTTP-Healthcheck
        ↓
Erfolg → Rollback-Zustand löschen
```

Bei einem Fehler versucht das Skript, den vorherigen Dateizustand und die vorherige Datenbank wiederherzustellen.

## Restore-Test

```bash
sudo /opt/nextcloud/restore-test.sh
```

Oder mit einem konkreten Archiv:

```bash
sudo /opt/nextcloud/restore-test.sh nextcloud-YYYY-MM-DD_HH-MM-SS
```

Der Test extrahiert das Archiv in ein temporäres Verzeichnis, verwendet einen eigenen Compose-Projektnamen und ein eigenes Docker-Volume und importiert den PostgreSQL-Dump. Produktionsdateien werden nicht als Restore-Ziele verwendet.

Der Test verweigert absichtlich Compose-Dateien mit `container_name:`, `network_mode: host`, veröffentlichten Ports oder externen Volumes/Netzwerken, weil damit eine sichere Isolation nicht garantiert werden kann. Bei ungewöhnlichen Compose-Konstruktionen ist ein separates Testsystem die sichere Wahl.

## Repository-Checks

Nach Backups:

```bash
borg info "$BORG_REPO"
borg list "$BORG_REPO"
```

Regelmäßig, z. B. monatlich oder nach größeren Änderungen:

```bash
borg check "$BORG_REPO"
```

Ein vollständiges `borg check` nach jedem Backup ist für große Repositories unnötig teuer.

## Retention

Die bestehende Policy bleibt:

```text
7 täglich
4 wöchentlich
12 monatlich
```

Implementiert als:

```bash
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=12 "$BORG_REPO"
```

Prune läuft erst nach erfolgreicher Archiv-Erstellung und Validierung. Danach wird das Repository erneut gelistet.

## Disaster Recovery bei komplettem Serververlust

Ein neuer Server benötigt mindestens:

1. unterstütztes Linux installieren
2. Docker Engine + Compose v2 installieren
3. BorgBackup installieren
4. SSH-Key für das Remote-Borg-Repository wiederherstellen
5. Borg-Passphrase aus einem unabhängigen sicheren Speicher holen
6. `/opt/nextcloud` und die benötigten Mountpoints anlegen
7. initiale `.env` und Compose-Konfiguration bereitstellen
8. `borg list "$BORG_REPO"` erfolgreich ausführen
9. `restore.sh` starten und einen Recovery Point auswählen
10. Healthchecks und Anwendung manuell prüfen
11. nach erfolgreicher Recovery ein neues Backup ausführen

**Wichtig:** Die echte `.env`, SSH-Zugangsdaten und Borg-Passphrase müssen auch dann verfügbar sein, wenn der ursprüngliche Server vollständig verloren ist.

## 3-2-1-Backup

Ein Borg-Repository auf demselben physischen Server schützt nicht vor einem vollständigen Serverausfall, Diebstahl, Defekt oder Ransomware.

Empfohlen ist mindestens:

```text
Produktivserver
      ↓
externer Backupserver / Storage
      ↓
zweite unabhängige Kopie
```

Die zweite Kopie sollte idealerweise offline, unveränderbar oder an einem anderen Standort liegen.

## Sicherheit

- Keine echten Secrets in Git.
- `.env` auf dem Server mit `chmod 600` schützen.
- Dedizierten SSH-Key für Borg verwenden.
- SSH-Key auf dem Backupserver möglichst auf Borg beschränken.
- Borg-Passphrase getrennt vom Server aufbewahren.
- Temporäre SQL-Dumps nur in privaten `mktemp`-Verzeichnissen erzeugen.
- Keine Passwörter, Tokens oder Passphrasen in Logs ausgeben.
- Shell-Quoting konsequent verwenden.
- Restore niemals als ungeprüften `rm -rf`-Workflow betrachten.

## Tests

Lokale Syntaxprüfungen:

```bash
bash -n backup.sh
bash -n restore.sh
bash -n restore-test.sh
```

Zusätzlich:

```bash
shellcheck backup.sh
shellcheck restore.sh
shellcheck restore-test.sh
```

Auf der Ausführungsumgebung dieses Änderungsdurchlaufs war `shellcheck` nicht installiert; daher konnte die ShellCheck-Prüfung hier nicht ausgeführt werden. Die `bash -n`-Syntaxprüfungen aller drei Skripte waren erfolgreich.

Wichtige Negativtests sollten in einer Testumgebung erfolgen:

- `.env` fehlt
- falsche Borg-Verbindung
- Repository nicht erreichbar
- PostgreSQL nicht erreichbar
- `pg_dump` schlägt fehl
- Borg `create` schlägt fehl
- Backup wird unterbrochen
- Archiv ist unvollständig
- PostgreSQL-Import schlägt fehl
- Nextcloud startet nicht
- HTTP-Healthcheck schlägt fehl

Dieses Repository führt beim Ändern der Skripte keinen echten Produktions-Restore aus.

## Bekannte Grenzen

Die Lösung ist absichtlich kein universelles Nextcloud-Backup-Framework. Sie kennt eine konkrete Docker-/Filesystem-Struktur. Vor Änderungen an Compose, Volumes, Mountpoints, PostgreSQL, Nextcloud oder Reverse Proxy müssen Backup und Restore erneut geprüft werden.

Ein Restore-Test ist besonders wichtig, weil nur ein tatsächlich durchgeführter Restore beweist, dass Backup, Compose-Konfiguration, Datenbankdump und Dateistruktur gemeinsam funktionieren.
