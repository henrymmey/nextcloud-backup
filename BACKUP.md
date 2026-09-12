# Backup Setup & Usage

This guide explains how to install, configure and use the Nextcloud backup system.

`backup.sh` creates an **encrypted BorgBackup archive** containing the configured Nextcloud files and a **PostgreSQL SQL dump**.

> **Important:** This project is designed for a specific Docker Compose installation. Before the first run, compare the service names, volumes and filesystem paths with your actual `docker-compose.yml`.

## 1. Requirements

The Nextcloud server needs:

- Linux with root access
- Docker Engine
- Docker Compose v2
- BorgBackup
- SSH access to the Borg backup repository
- a running Nextcloud installation using PostgreSQL
- enough temporary disk space for the PostgreSQL dump

The backup repository must be reachable before a backup can be created.

## 2. Install the scripts

A typical installation could look like this:

```text
/opt/nextcloud/
├── docker-compose.yml
├── .env
├── backup.sh
├── restore.sh
└── restore-test.sh
```

Make the scripts executable:

```bash
chmod +x /opt/nextcloud/backup.sh
chmod +x /opt/nextcloud/restore.sh
chmod +x /opt/nextcloud/restore-test.sh
```

## 3. Configure `.env`

Start with the example configuration:

```bash
cp .env.example /opt/nextcloud/.env
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

At minimum, configure:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=YOUR_DATABASE_PASSWORD

BORG_REPO=user@backup-server:/path/to/repository
BORG_PASSPHRASE=YOUR_BORG_PASSPHRASE
```

Optional health-check settings:

```env
HEALTHCHECK_URL=http://127.0.0.1/status.php
HEALTHCHECK_TIMEOUT=120
POLL_INTERVAL=2
```

**Never commit passwords or passphrases to Git.** The repository contains a `.gitignore` that protects the real `.env` from accidental commits.

## 4. Check paths and container names

The scripts use defaults for a specific Nextcloud layout. Important settings include:

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

If your installation uses different paths, service names or volume names, adjust the configuration accordingly.

For example:

```bash
export APP_CONTAINER=nextcloud
export DB_CONTAINER=postgres
```

Do not change these values until you have checked the actual Docker Compose configuration.

## 5. Test Borg access

Before creating the first backup, verify that Borg can access the repository:

```bash
borg info "$BORG_REPO"
```

If SSH is used, make sure the required key is available. For example:

```env
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

The Borg passphrase must also be available to the backup script.

## 6. Create the first backup

Once Nextcloud is running and the configuration has been checked:

```bash
sudo /opt/nextcloud/backup.sh
```

The script performs several preflight checks before starting the backup. It checks, among other things, Docker, Docker Compose, PostgreSQL, Borg, configured paths and available temporary storage.

Only after the preflight checks succeed is Nextcloud placed into Maintenance Mode.

## 7. What happens during a backup?

The process is roughly:

```text
Check the system
      ↓
Acquire backup lock
      ↓
Check PostgreSQL
      ↓
Enable Nextcloud Maintenance Mode
      ↓
Create PostgreSQL dump
      ↓
Validate dump + calculate SHA-256
      ↓
Create backup metadata
      ↓
Create Borg archive
      ↓
Validate archive
      ↓
Apply retention policy
      ↓
Disable Maintenance Mode
```

If the script is interrupted or an error occurs, it attempts to disable Maintenance Mode and remove temporary files.

## 8. What is backed up?

The archive contains the configured parts required for a restore:

- `docker-compose.yml`
- `.env`
- Nextcloud configuration
- Nextcloud data
- AppData
- configured local External Storage
- configured Nextcloud Docker volume
- PostgreSQL SQL dump
- `backup-metadata.json`

The PostgreSQL live data directory is not copied as raw database files. The logical SQL dump is used instead.

## 9. Verify backups

List the available archives:

```bash
borg list "$BORG_REPO"
```

Show repository information:

```bash
borg info "$BORG_REPO"
```

A full repository consistency check should also be performed regularly:

```bash
borg check "$BORG_REPO"
```

For large repositories, a full `borg check` does not need to run after every backup.

## 10. Retention

After a new archive has been successfully created and validated, the script applies this retention policy:

```text
7 daily backups
4 weekly backups
12 monthly backups
```

This prevents the repository from growing indefinitely.

## 11. Automatic backups

For a production server, `backup.sh` should normally be executed automatically, for example with a system-wide cron job or a systemd timer.

Example cron job:

```cron
0 3 * * * /opt/nextcloud/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

Choose a schedule appropriate for your data and recovery requirements.

## 12. Test your backups regularly

A backup is only trustworthy if it can actually be restored.

Use the separate restore test:

```bash
sudo /opt/nextcloud/restore-test.sh
```

The test uses an isolated Compose environment and a separate Docker volume and is designed not to overwrite production data.

See **[RESTORE.md](RESTORE.md)** for the restore test and its limitations.

## 13. Troubleshooting failed backups

If a backup fails, first inspect the script output and logs. Common causes include:

- Borg repository is unreachable
- incorrect Borg passphrase
- PostgreSQL is unavailable
- incorrect database credentials
- incorrect container names
- missing directories
- insufficient temporary disk space
- invalid Docker Compose configuration
- insufficient permissions

**Do not simply remove or disable the safety checks.** They are intended to prevent an incomplete backup from being reported as successful.

## Next step

For restoring a backup, continue with **[RESTORE.md](RESTORE.md)**.

It explains the complete restore process, the isolated restore test and disaster recovery after a complete server failure.
