# Nextcloud Backup & Restore

Dieses Projekt sichert eine **Nextcloud-Installation mit Docker Compose** und stellt sie bei Bedarf aus einem Backup wieder her.

Es verwendet:

- **BorgBackup** für verschlüsselte Backups und Aufbewahrung
- **PostgreSQL `pg_dump`** für die Datenbank
- **Docker Compose** für die Nextcloud-Umgebung
- **Maintenance Mode**, damit während des Backups keine Änderungen an Nextcloud-Daten erfolgen
- **Prüfungen und Metadaten**, damit fehlerhafte Backups möglichst früh erkannt werden
- einen **Restore mit Rollback-Schutz**
- einen **separaten Restore-Test**, ohne den produktiven Zustand zu überschreiben

Das Projekt ist auf eine konkrete Docker-/Filesystem-Struktur ausgelegt. Die Pfade und Container-Namen werden über die Konfiguration angepasst.

## Schnellüberblick

```text
Nextcloud
   │
   ├── Dateien / Konfiguration
   ├── PostgreSQL-Datenbank
   └── Docker-Umgebung
           │
           ▼
      backup.sh
           │
           ▼
      BorgBackup
           │
           ▼
   externes Backup-Repository
```

Für die tägliche Nutzung sind vor allem diese drei Skripte wichtig:

| Datei | Wofür? |
|---|---|
| `backup.sh` | Erstellt und prüft ein Backup und wendet die Aufbewahrungsregeln an. |
| `restore.sh` | Stellt einen ausgewählten Backup-Stand wieder her. |
| `restore-test.sh` | Testet einen Restore möglichst isoliert, ohne die produktiven Daten zu ersetzen. |

## Dokumentation

### Backup einrichten und verwenden

➡️ **[BACKUP.md](BACKUP.md)**

Dort wird Schritt für Schritt erklärt:

- welche Voraussetzungen benötigt werden
- wie `.env` eingerichtet wird
- welche Pfade konfiguriert werden müssen
- wie `backup.sh` installiert und ausgeführt wird
- was während eines Backups passiert
- welche Daten gesichert werden
- wie Backups überprüft werden
- wie die Aufbewahrung funktioniert
- wie regelmäßige Restore-Tests durchgeführt werden

### Restore und Disaster Recovery

➡️ **[RESTORE.md](RESTORE.md)**

Dort wird erklärt:

- wie ein Restore vorbereitet und gestartet wird
- wie ein Backup-Stand ausgewählt wird
- welche Sicherheitsprüfungen vor dem Restore stattfinden
- wie der vorhandene Zustand geschützt wird
- wie PostgreSQL wiederhergestellt wird
- wie Nextcloud nach dem Restore geprüft wird
- wie ein kompletter Serververlust behandelt wird
- wie der zerstörungsfreie Restore-Test funktioniert
- was nach einem erfolgreichen Restore geprüft werden sollte

**Wenn du das Projekt neu einrichtest, lies zuerst `BACKUP.md`. Für einen Restore oder einen Serverausfall ist `RESTORE.md` die maßgebliche Anleitung.**

## Was wird gesichert?

Ein Backup enthält die für die Wiederherstellung benötigten Teile der Nextcloud-Umgebung:

- Docker-Compose-Konfiguration
- `.env`
- Nextcloud-Konfiguration
- Nextcloud-Daten
- AppData
- lokales External Storage
- das konfigurierte Nextcloud-Docker-Volume
- PostgreSQL als logischen SQL-Dump
- automatisch erzeugte Backup-Metadaten

Das PostgreSQL-Live-Datenverzeichnis wird **nicht** als rohe Dateikopie gesichert. Stattdessen wird `pg_dump` verwendet.

Ein entfernter External Storage wird nur dann durch dieses Backup erfasst, wenn seine Daten tatsächlich auf dem angegebenen lokalen Pfad liegen.

## Wie funktioniert ein Backup?

`backup.sh` prüft zunächst die Umgebung, bevor Nextcloud in den Maintenance Mode versetzt wird. Anschließend wird die Datenbank gesichert und zusammen mit den Nextcloud-Daten in ein Borg-Archiv geschrieben.

Das neu erstellte Archiv wird anschließend geprüft. Optional wird der SQL-Dump sogar direkt aus dem Borg-Archiv gelesen und erneut mit seinem ursprünglichen Hash verglichen.

Bei einem erfolgreichen Backup wird anschließend die konfigurierte Aufbewahrung angewendet:

```text
7 tägliche Backups
4 wöchentliche Backups
12 monatliche Backups
```

Weitere Informationen: **[BACKUP.md](BACKUP.md)**

## Wie funktioniert ein Restore?

`restore.sh` löscht nicht einfach zuerst die produktiven Daten. Vor dem eigentlichen Restore werden das Archiv und seine Inhalte geprüft. Der aktuelle Zustand wird zusätzlich für einen möglichen Rollback vorbereitet.

Vereinfacht:

```text
Backup auswählen
      ↓
Backup prüfen
      ↓
aktuellen Zustand absichern
      ↓
Restore vorbereiten
      ↓
PostgreSQL wiederherstellen
      ↓
Nextcloud starten
      ↓
Nextcloud + HTTP prüfen
      ↓
Erfolg oder Rollback
```

Weitere Informationen: **[RESTORE.md](RESTORE.md)**

## Restore-Test

Ein Backup sollte nicht nur existieren, sondern auch wiederherstellbar sein. Dafür gibt es `restore-test.sh`.

Der Test verwendet eine separate Compose-Umgebung und ein separates Docker-Volume. Er ist dafür gedacht, regelmäßig zu überprüfen, ob ein Backup tatsächlich wiederhergestellt werden kann.

```bash
sudo /opt/nextcloud/restore-test.sh
```

Details und Einschränkungen des Tests stehen in **[RESTORE.md](RESTORE.md)**.

## Sicherheit

Die echte `.env` gehört **nicht in Git**. Sie kann im verschlüsselten Borg-Backup enthalten sein, muss aber zusätzlich an einem sicheren, unabhängigen Ort verfügbar sein. Dasselbe gilt für die Borg-Passphrase und den für das Repository benötigten SSH-Zugang.

Ein Backup auf demselben Server schützt nicht vor einem vollständigen Serverausfall. Für wichtige Daten wird deshalb eine **3-2-1-Backup-Strategie** empfohlen.

## Wichtiger Hinweis zur Einrichtung

Dieses Repository enthält die Backup-/Restore-Skripte und Dokumentation, aber nicht zwingend die tatsächliche produktive `docker-compose.yml` deiner Nextcloud-Installation.

Vor dem Einsatz müssen deshalb insbesondere folgende Punkte mit der echten Compose-Konfiguration abgeglichen werden:

- Service-Namen
- Docker-Volumes
- Bind-Mounts
- Nextcloud-Datenpfade
- PostgreSQL-Konfiguration
- External Storage
- Reverse Proxy / Ports

**Nicht blind die Beispielwerte übernehmen.** Die konkrete Installation muss zu den konfigurierten Pfaden und Containern passen.

## Lizenz

Siehe die Lizenzdatei bzw. die Repository-Einstellungen.
