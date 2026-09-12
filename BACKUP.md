# Backup einrichten und verwenden

Diese Anleitung erklärt, wie du das Nextcloud-Backup einrichtest und anschließend regelmäßig verwendest.

Das Backup erstellt mit `backup.sh` ein **verschlüsseltes BorgBackup** deiner Nextcloud-Dateien und einen **PostgreSQL-SQL-Dump**.

> **Wichtig:** Das Projekt ist auf eine konkrete Docker-Compose-Installation zugeschnitten. Prüfe vor der ersten Ausführung unbedingt die Service-Namen, Volumes und Pfade deiner echten `docker-compose.yml`.

## 1. Voraussetzungen

Auf dem Nextcloud-Server werden benötigt:

- Linux mit Root-Zugriff
- Docker Engine
- Docker Compose v2
- BorgBackup
- SSH-Zugriff auf das Borg-Backup-Repository
- eine laufende Nextcloud mit PostgreSQL
- ausreichend Speicher für einen temporären PostgreSQL-Dump

Das Repository muss außerdem erreichbar sein, bevor ein Backup erstellt werden kann.

## 2. Dateien installieren

Lege die Skripte beispielsweise unter `/opt/nextcloud` ab:

```text
/opt/nextcloud/
├── docker-compose.yml
├── .env
├── backup.sh
├── restore.sh
└── restore-test.sh
```

Die Skripte müssen ausführbar sein:

```bash
chmod +x /opt/nextcloud/backup.sh
chmod +x /opt/nextcloud/restore.sh
chmod +x /opt/nextcloud/restore-test.sh
```

## 3. `.env` einrichten

Erstelle die Konfiguration aus `.env.example`:

```bash
cp .env.example /opt/nextcloud/.env
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

Mindestens benötigt werden:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=DEIN_DB_PASSWORT

BORG_REPO=user@backup-server:/pfad/zum/repository
BORG_PASSPHRASE=DEINE_BORG_PASSPHRASE
```

Optional können unter anderem Healthcheck-Einstellungen gesetzt werden:

```env
HEALTHCHECK_URL=http://127.0.0.1/status.php
HEALTHCHECK_TIMEOUT=120
POLL_INTERVAL=2
```

**Passwörter und Passphrasen niemals in Git committen.** Die `.gitignore` verhindert das versehentliche Hinzufügen von `.env`.

## 4. Pfade und Container prüfen

`backup.sh` verwendet standardmäßig eine konkrete Nextcloud-Struktur. Die wichtigsten Einstellungen sind:

```text
COMPOSE_DIR
COMPOSE_FILE
ENV_FILE
APP_CONTAINER
DB_CONTAINER
NC_CONFIG
NC_DATA
NC_APPDATA
NC_EXTERNAL
NC_VOLUME
BORG_REPO
```

Wenn deine Installation andere Pfade oder Service-Namen verwendet, müssen die Werte angepasst werden.

Beispiel:

```bash
export APP_CONTAINER=nextcloud
export DB_CONTAINER=postgres
```

Noch besser ist eine dauerhafte Anpassung der Konfiguration bzw. der Umgebung des Skripts.

## 5. Borg-Zugriff testen

Bevor du das erste Backup startest, muss der Zugriff auf das Repository funktionieren:

```bash
borg info "$BORG_REPO"
```

Wenn SSH verwendet wird, sollte der benötigte Schlüssel bereits eingerichtet sein. Beispiel:

```env
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

Die Borg-Passphrase muss verfügbar sein.

## 6. Erstes Backup erstellen

Wenn Nextcloud läuft und die Konfiguration geprüft wurde:

```bash
sudo /opt/nextcloud/backup.sh
```

Das Skript führt vor dem eigentlichen Backup mehrere Prüfungen durch. Unter anderem werden Docker, Compose, PostgreSQL, Borg, die Datenpfade und der verfügbare Speicher geprüft.

Erst danach wird Nextcloud in den Maintenance Mode versetzt.

## 7. Was passiert während des Backups?

Der Ablauf ist vereinfacht:

```text
System prüfen
    ↓
Backup-Sperre setzen
    ↓
PostgreSQL prüfen
    ↓
Nextcloud Maintenance Mode
    ↓
PostgreSQL-Dump erstellen
    ↓
Dump prüfen + SHA-256 berechnen
    ↓
Metadaten erstellen
    ↓
Borg-Archiv erstellen
    ↓
Archiv prüfen
    ↓
Retention anwenden
    ↓
Maintenance Mode verlassen
```

Wenn das Skript abgebrochen wird oder ein Fehler auftritt, versucht es, den Maintenance Mode wieder zu deaktivieren und temporäre Dateien zu entfernen.

## 8. Was wird gesichert?

Das Archiv enthält die für diesen Restore benötigten Teile der Installation:

- `docker-compose.yml`
- `.env`
- Nextcloud-Konfiguration
- Nextcloud-Daten
- AppData
- konfiguriertes lokales External Storage
- konfiguriertes Nextcloud-Docker-Volume
- PostgreSQL-SQL-Dump
- `backup-metadata.json`

Das PostgreSQL-Live-Datenverzeichnis wird nicht als rohe Dateikopie gesichert.

## 9. Backup prüfen

Nach einem Backup kannst du die Archive anzeigen:

```bash
borg list "$BORG_REPO"
```

Informationen zum Repository:

```bash
borg info "$BORG_REPO"
```

Regelmäßig sollte zusätzlich eine vollständige Repository-Prüfung erfolgen:

```bash
borg check "$BORG_REPO"
```

Bei großen Repositories muss `borg check` nicht nach jedem einzelnen Backup laufen.

## 10. Aufbewahrung

Nach erfolgreicher Erstellung und Prüfung des neuen Backups verwendet das Skript folgende Aufbewahrung:

```text
7 tägliche Backups
4 wöchentliche Backups
12 monatliche Backups
```

Dadurch wächst das Repository nicht unbegrenzt weiter.

## 11. Regelmäßige Backups

Für einen produktiven Server sollte `backup.sh` automatisiert ausgeführt werden, beispielsweise über einen systemweiten Cronjob oder einen systemd-Timer.

Beispiel für einen Cronjob:

```cron
0 3 * * * /opt/nextcloud/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

Die konkrete Planung hängt davon ab, wie oft deine Nextcloud gesichert werden soll.

## 12. Restore regelmäßig testen

Ein Backup ist erst wirklich vertrauenswürdig, wenn die Wiederherstellung getestet wurde.

Dafür gibt es:

```bash
sudo /opt/nextcloud/restore-test.sh
```

Der Test verwendet eine separate Compose-Umgebung und ein separates Docker-Volume und soll die produktiven Daten nicht überschreiben.

Die vollständige Restore-Anleitung findest du in **[RESTORE.md](RESTORE.md)**.

## 13. Wenn das Backup fehlschlägt

Bei einem Fehler sollte zuerst die Ausgabe des Skripts geprüft werden. Typische Ursachen sind:

- Borg-Repository nicht erreichbar
- falsche Borg-Passphrase
- PostgreSQL nicht erreichbar
- falsche DB-Zugangsdaten
- falsche Container-Namen
- fehlende Verzeichnisse
- zu wenig temporärer Speicher
- ungültige Compose-Konfiguration
- fehlende Berechtigungen

**Nicht einfach die Prüfungen entfernen.** Sie sollen verhindern, dass ein fehlerhaftes oder unvollständiges Backup als erfolgreich behandelt wird.

## Nächster Schritt

Wenn du einen Restore durchführen musst, lies **[RESTORE.md](RESTORE.md)**.

Dort wird die Wiederherstellung, der Restore-Test und die Vorgehensweise bei einem vollständigen Serververlust erklärt.
