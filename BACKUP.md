# Backup Setup & Usage

This guide explains how to install, configure and use the Nextcloud backup system.

`backup.sh` creates an encrypted BorgBackup archive containing the configured Nextcloud files and a PostgreSQL SQL dump.

## 1. Requirements

The Nextcloud server needs:

- Linux with root access
- Docker Engine
- Docker Compose v2
- BorgBackup
- SSH access to the Borg backup repository
- a running Nextcloud installation using PostgreSQL
- enough temporary disk space for the PostgreSQL dump

## 2. Install the scripts

A typical installation:

```text
/opt/nextcloud/
├── docker-compose.yml
├── .env
├── backup.sh
├── restore.sh
├── restore-test.sh
└── borg-check.sh
```

Make the scripts executable:

```bash
chmod +x /opt/nextcloud/backup.sh
chmod +x /opt/nextcloud/restore.sh
chmod +x /opt/nextcloud/restore-test.sh
chmod +x /opt/nextcloud/borg-check.sh
```

## 3. Configure `.env`

Create the file from `.env.example` and protect it:

```bash
cp .env.example /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
chmod 600 /opt/nextcloud/.env
```

At minimum:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=YOUR_DATABASE_PASSWORD

BORG_REPO=user@backup-server:/path/to/repository
BORG_PASSPHRASE=YOUR_BORG_PASSPHRASE
```

The scripts deliberately do **not** execute `.env` as shell code. Only simple `KEY=VALUE` settings are read. This prevents arbitrary commands in `.env` from being executed as root.

Never commit the real `.env` to Git.

## 4. Backup consistency

Before touching the data, the script performs its preflight checks. It then enables Nextcloud Maintenance Mode and stops all currently running Compose services except PostgreSQL. PostgreSQL remains available for `pg_dump`.

This reduces the risk of files changing while the database dump and filesystem backup are created. It is stronger than Maintenance Mode alone, but it is not a filesystem snapshot. If the underlying filesystem or an external process changes files independently, absolute atomicity cannot be guaranteed.

After the backup completes, the script starts the Nextcloud app service again and disables Maintenance Mode. If startup fails, the backup is reported as failed rather than silently claiming success.

## 5. Temporary storage checks

The script checks free space before `pg_dump` using a conservative multiple of the database size because a plain SQL dump can be larger than PostgreSQL's internal database size.

After `pg_dump`, it checks free space again and refuses to continue if the configured safety margin has been exhausted.

## 6. What is backed up?

The archive contains:

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

## 7. Backup validation

After the Borg archive is created, the script checks that all expected paths are present.

When `VERIFY_ARCHIVE_DATA=true` (the default), it also:

1. runs `borg check --archives-only --verify-data` for the new archive
2. extracts the PostgreSQL dump again
3. compares its SHA-256 hash with the original dump

This means the new archive's encrypted data is actually read and authenticated instead of merely checking that an archive listing exists.

## 8. Regular repository integrity checks

`borg-check.sh` performs a repository-wide integrity check including data verification:

```bash
sudo /opt/nextcloud/borg-check.sh
```

Run this separately, for example weekly. A full `borg check --verify-data` can be expensive for large repositories and therefore does not need to run after every daily backup.

## 9. Retention

After a new archive has been successfully created and validated, the script applies:

```text
7 daily backups
4 weekly backups
12 monthly backups
```

Retention is only applied after the new archive passed validation.

## 10. Automatic backups

Use a system-wide cron job or systemd timer. Example:

```cron
0 3 * * * /opt/nextcloud/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

A separate weekly integrity check can run, for example, Sunday at 04:00:

```cron
0 4 * * 0 /opt/nextcloud/borg-check.sh >> /var/log/nextcloud-borg-check.log 2>&1
```

## 11. Restore tests

A backup is only trustworthy if it can actually be restored.

Use:

```bash
sudo /opt/nextcloud/restore-test.sh
```

The test uses a separate Compose project and a separate Docker volume and is designed not to overwrite production data.

## 12. Remote backup repository

The destination is controlled by `BORG_REPO`. For example:

```env
BORG_REPO=user@backup-server:/path/to/repository
```

In that configuration Borg transfers the backup to the remote server over SSH. `BORG_RSH` can optionally select a dedicated SSH key.

## 13. Security

Keep the Borg passphrase and SSH recovery credentials independently from the production server. A remote backup is not sufficient if a total server loss also destroys the only copy of the credentials needed to access it.

For important installations, use a 3-2-1 strategy with an additional independent backup copy.

## 14. Troubleshooting

Common causes of failure include:

- Borg repository is unreachable
- incorrect Borg passphrase
- PostgreSQL is unavailable
- incorrect database credentials
- incorrect container names
- missing directories
- insufficient temporary disk space
- invalid Docker Compose configuration
- insufficient permissions
- failed Borg data verification

Do not disable the safety checks just to make a backup report success. Fix the underlying problem instead.
