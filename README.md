# Nextcloud Backup & Restore

A simple and reliable backup and restore solution for a **Docker Compose-based Nextcloud installation**.

This project is designed to protect the important parts of your Nextcloud installation and make it possible to restore a complete working state when something goes wrong.

It uses:

- **BorgBackup** for encrypted backups and retention
- **PostgreSQL `pg_dump`** for database backups
- **Docker Compose** for the Nextcloud environment
- **Nextcloud Maintenance Mode** during backups
- **Backup validation and metadata** to detect incomplete backups
- **Rollback protection** during restores
- a separate **restore test** that does not replace the production installation

> **Important:** This project is designed for a specific Docker/Filesystem layout. Before using it, compare the configuration with your actual `docker-compose.yml`, volume definitions and filesystem paths.

## How it works

```text
Nextcloud
   │
   ├── Files & configuration
   ├── PostgreSQL database
   └── Docker environment
           │
           ▼
      backup.sh
           │
           ▼
      BorgBackup
           │
           ▼
   Backup repository
```

The backup contains the files needed to rebuild the configured Nextcloud environment together with a PostgreSQL database dump.

## Main scripts

| File | Purpose |
| --- | --- |
| `backup.sh` | Creates, validates and retains backups. |
| `restore.sh` | Restores a selected backup with validation and rollback protection. |
| `restore-test.sh` | Tests whether a backup can be restored in an isolated environment. |

## Documentation

The README intentionally provides only an overview. The detailed user documentation is split into two guides.

### Backup setup and daily use

➡️ **[BACKUP.md](BACKUP.md)**

This guide explains step by step:

- what you need before installing the backup
- how to install the scripts
- how to configure `.env`
- how to configure paths and container names
- how to configure BorgBackup
- how to run the first backup
- what happens during a backup
- what is included in a backup
- how to verify backups
- how retention works
- how to schedule automatic backups
- how to perform regular restore tests
- how to troubleshoot failed backups

**If you are setting up this project for the first time, start with `BACKUP.md`.**

### Restore and disaster recovery

➡️ **[RESTORE.md](RESTORE.md)**

This guide explains:

- when you should use a restore
- how to select a recovery point
- how to safely start a restore
- what the restore script checks before changing anything
- how rollback protection works
- how PostgreSQL is restored
- how Nextcloud is checked afterwards
- how to test a backup without touching production
- how to recover after a complete server failure
- what you should manually verify after a restore

**If you need to restore Nextcloud or recover from a server failure, use `RESTORE.md`.**

## What is backed up?

A backup contains the configured parts of the Nextcloud environment, including:

- Docker Compose configuration
- `.env`
- Nextcloud configuration
- Nextcloud data
- AppData
- configured local External Storage
- the configured Nextcloud Docker volume
- a PostgreSQL SQL dump
- automatically generated backup metadata

The PostgreSQL live data directory is **not** copied as raw database files. PostgreSQL is backed up using `pg_dump` instead.

A remote External Storage system is only covered if its actual data is available on the local path being backed up. Backing up a mount point does not automatically back up the remote system itself.

## Backup validation

Before creating a backup, the script performs several checks, including Docker, Docker Compose, PostgreSQL, BorgBackup, configured paths and available temporary storage.

Nextcloud is only placed into Maintenance Mode after these checks succeed.

After the Borg archive has been created, the archive is checked again. The PostgreSQL dump can also be read directly from the new Borg archive and verified using its SHA-256 hash.

The default retention policy is:

```text
7 daily backups
4 weekly backups
12 monthly backups
```

## Restore protection

`restore.sh` does not simply delete the production data and copy the backup over it.

Before changing the production environment, it:

1. validates the selected archive
2. validates the database dump and metadata
3. prepares a rollback copy of the current database
4. prepares the existing files and Docker volume for rollback
5. applies the restored data
6. restores PostgreSQL
7. starts Nextcloud
8. checks `occ status` and HTTP availability
9. keeps the rollback data until the restore succeeds

If a restore fails, the script attempts to restore the previous state.

> A rollback is a safety mechanism, not a guarantee. Hardware, filesystem or storage failures can also prevent rollback.

## Restore testing

A backup should not only exist — it should also be restorable.

`restore-test.sh` is provided to test a backup without replacing the production data:

```bash
sudo /opt/nextcloud/restore-test.sh
```

The test uses a separate Docker Compose project, temporary bind mounts and a separate Docker volume.

See **[RESTORE.md](RESTORE.md)** for details and limitations.

## Security

Never commit the real `.env` file to Git. It contains credentials and other sensitive configuration.

The Borg passphrase, SSH credentials and other recovery credentials should also be stored independently from the production server. Otherwise, a complete server loss could also mean losing the information required to access the backups.

For important installations, use a **3-2-1 backup strategy** with an additional independent backup copy.

## Important: check your Docker Compose setup

This repository contains the backup and restore scripts, but it does not necessarily contain your actual production `docker-compose.yml`.

Before using the scripts, verify at least:

- service names
- Docker volume names
- bind mounts
- Nextcloud data paths
- PostgreSQL configuration
- External Storage paths
- reverse proxy and network configuration

**Do not blindly use the example values.** The configuration must match your actual Nextcloud installation.

## License

See the repository license information.
