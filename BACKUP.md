# Backup Guide

This document explains the backup process implemented by `backup.sh`, including the filesystem layout, database handling, Borg configuration, security considerations, scheduling and verification.

## 1. Overview

`backup.sh` creates a disaster-recovery backup of a Docker-based Nextcloud installation.

The backup consists of two different types of data:

1. **Filesystem data**
   - Nextcloud configuration
   - user data
   - Nextcloud appdata
   - external-storage data
   - the Docker volume containing `/var/www/html`
   - the Docker Compose file

2. **Database data**
   - a PostgreSQL SQL dump created with `pg_dump`

All of these are stored together in one Borg archive.

The resulting Borg repository should normally be located on a different machine or storage system from the Nextcloud server. This protects against failure of the primary server.

## 2. Intended filesystem layout

The scripts are configured for the following installation:

```text
/opt/nextcloud/
├── docker-compose.yml
├── .env
└── config/

/opt/nextcloud/
└── postgres/

/mnt/hdd/nextcloud/data/

/mnt/ssd-working/appdata_oc464t3i6cse/

/mnt/ssd-working/nc_external_storage/

/var/lib/docker/volumes/nextcloud_nextcloud_html/_data/
```

The exact Docker volume mountpoint is not hard-coded. `backup.sh` asks Docker for the current mountpoint using:

```bash
docker volume inspect nextcloud_nextcloud_html
```

This avoids depending on Docker's internal directory layout.

## 3. Why the PostgreSQL directory is not copied

The PostgreSQL service stores its database in:

```text
/opt/nextcloud/postgres
```

That directory contains PostgreSQL's live database files.

It should not simply be copied while PostgreSQL is running. PostgreSQL may have partially written or internally inconsistent data at the time individual files are copied.

Instead, the script executes:

```bash
pg_dump
```

inside the PostgreSQL container.

The result is a logical SQL backup that can be imported into a fresh PostgreSQL instance.

This makes the database backup independent of PostgreSQL's on-disk file state.

## 4. Why Nextcloud maintenance mode is enabled

The backup script enables:

```bash
php /var/www/html/occ maintenance:mode --on
```

before creating the database dump.

This prevents normal Nextcloud activity from changing files while the filesystem and database are being captured.

The important sequence is:

```text
maintenance mode ON
        |
        v
PostgreSQL dump
        |
        v
Borg archive
        |
        v
Borg successful
        |
        v
maintenance mode OFF
```

Maintenance mode is **not** disabled before the Borg backup finishes.

This is deliberate.

If maintenance mode were disabled immediately after the database dump, users and background jobs could change files while Borg was still reading them. The resulting filesystem state could then differ from the database state represented by the SQL dump.

## 5. Failure handling

The script uses Bash error handling:

```bash
set -Eeuo pipefail
```

If an important command fails, the error handler attempts to:

1. disable Nextcloud maintenance mode
2. delete the temporary SQL dump
3. exit with an error code

This prevents a failed backup from leaving Nextcloud stuck in maintenance mode.

The script also uses a lock:

```text
/var/run/nextcloud-backup.lock
```

with `flock`.

This prevents two backup processes from running at the same time.

## 6. Environment variables

The script loads:

```text
/opt/nextcloud/.env
```

The following variables are required:

| Variable | Purpose |
| --- | --- |
| `DB_NAME` | PostgreSQL database name |
| `DB_USER` | PostgreSQL username |
| `DB_PASSWORD` | PostgreSQL password |
| `BORG_REPO` | Borg repository location |
| `BORG_PASSPHRASE` | Borg encryption passphrase |

Optionally:

| Variable | Purpose |
| --- | --- |
| `BORG_RSH` | SSH command used by Borg |

Example:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=REPLACE_ME

BORG_REPO=backup@backup-server:/srv/borg/nextcloud
BORG_PASSPHRASE=REPLACE_ME

BORG_RSH=ssh -i /root/.ssh/borg_backup
```

Protect the file:

```bash
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

## 7. PostgreSQL dump

The database dump is created inside the database container.

Conceptually, the command is:

```bash
pg_dump     -U "$DB_USER"     -d "$DB_NAME"     --format=plain     --no-owner     --no-privileges
```

The output is written to:

```text
/tmp/nc-backup/nextcloud-db.sql
```

The file is given restrictive permissions:

```bash
chmod 600 /tmp/nc-backup/nextcloud-db.sql
```

After Borg successfully stores the dump, the temporary file is removed.

The SQL dump is therefore not intended to remain permanently on the Nextcloud server.

## 8. Borg archive

The script creates an archive with a timestamped name:

```text
nextcloud-YYYY-MM-DD_HH-MM-SS
```

Borg is invoked with Zstandard compression:

```bash
--compression zstd
```

Borg provides deduplication, compression and repository encryption depending on the repository's configured encryption mode.

Because Borg is content-addressed and deduplicating, multiple backup archives can reference the same unchanged data without storing every file repeatedly.

## 9. What is included

The following paths are explicitly passed to Borg:

```text
/opt/nextcloud/docker-compose.yml
/opt/nextcloud/config
/mnt/hdd/nextcloud/data
/mnt/ssd-working/appdata_oc464t3i6cse
/mnt/ssd-working/nc_external_storage
<docker volume mountpoint>
/tmp/nc-backup/nextcloud-db.sql
```

### Docker Compose file

The Compose file is included because it documents how the containers and volumes are constructed.

It is especially useful during a disaster recovery.

### Nextcloud config

The configuration contains important instance settings, including the Nextcloud configuration file.

### Nextcloud data

This contains the actual user data stored in the configured Nextcloud data directory.

### Appdata

The configured `appdata_oc464t3i6cse` directory is included because Nextcloud uses appdata for application-generated data.

### External storage

The configured external-storage directory is included because the deployment stores this data on the local filesystem.

This is specific to this deployment. If an external storage points to a remote system, backing up the local mountpoint may not back up the remote data itself.

### Docker volume

The `nextcloud_html` volume contains `/var/www/html`.

Some of its contents are hidden by bind mounts from the Compose file, which means parts of the volume overlap with separately backed-up host directories.

This redundancy is intentional in this project because it makes the Docker volume independently recoverable.

### PostgreSQL

The live PostgreSQL data directory is not included. The logical SQL dump is included instead.

## 10. What is intentionally excluded

### Temporary directory

The Compose configuration contains:

```text
/mnt/ssd-working/nextcloud_tmp
```

This is treated as temporary data and is not backed up.

Temporary data should be recreated by the application after a restore.

### PostgreSQL data directory

The live PostgreSQL directory is excluded because `pg_dump` is used instead.

### Redis

Redis does not use a persistent volume in the provided Compose configuration.

Its runtime state is therefore recreated when the container starts.

## 11. Borg retention

After a successful archive creation, the script runs:

```bash
borg prune     --keep-daily=7     --keep-weekly=4     --keep-monthly=12
```

The intended retention policy is:

- 7 daily backups
- 4 weekly backups
- 12 monthly backups

This is a starting point, not a universal recommendation.

If the repository is small, increase retention only if storage capacity allows it.

If the repository is large, reduce retention according to your recovery requirements.

## 12. Scheduling

A common approach is a systemd timer or cron job.

For example, a cron entry running every night at 03:00 could be:

```cron
0 3 * * * /opt/nextcloud/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

Make sure the job runs as root because the script needs access to:

- Docker
- the Nextcloud files
- the Docker volume
- the temporary backup directory
- the lock file

For production systems, systemd timers are generally preferable because they provide better service management and logging.

## 13. Verifying a backup

After the first backup, verify that Borg can see the archive:

```bash
export BORG_PASSPHRASE='...'
borg list "$BORG_REPO"
```

Then inspect an archive:

```bash
borg info "$BORG_REPO::nextcloud-YYYY-MM-DD_HH-MM-SS"
```

You can also list its contents:

```bash
borg list "$BORG_REPO::nextcloud-YYYY-MM-DD_HH-MM-SS"
```

Do not consider a backup production-ready until you have successfully restored it somewhere.

## 14. Repository integrity checks

Borg provides repository checking:

```bash
borg check "$BORG_REPO"
```

A full repository check can be expensive for a large repository.

It is therefore reasonable to run it periodically rather than after every single backup.

For example, run a full check monthly and investigate every error.

## 15. SSH security

The remote Borg repository should preferably be accessed with a dedicated SSH key.

Example:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/borg_backup
```

Then:

```env
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

The private key should be:

```bash
chmod 600 /root/.ssh/borg_backup
```

For a hardened backup server, the public key can be restricted in `authorized_keys` so that it can only execute Borg and cannot be used as a normal interactive shell.

## 16. Borg passphrase security

The Borg passphrase is not recoverable from the repository.

Store it separately from the server where possible.

A sensible disaster-recovery setup therefore has:

```text
Nextcloud server
    |
    +-- .env
    +-- SSH private key
    |
    v
Remote Borg repository
    |
    +-- encrypted backup data
```

And an additional secure copy of the Borg passphrase should exist outside the server.

If the server and its `.env` are destroyed, you still need the passphrase and SSH credentials to access the remote repository.

## 17. Testing strategy

A useful backup test should include:

1. Create a backup.
2. Verify that Borg lists the archive.
3. Extract the archive to a separate test system.
4. Restore the filesystem.
5. Import the SQL dump.
6. Start Nextcloud.
7. Log in.
8. Open several existing files.
9. Verify that user accounts and application configuration are present.
10. Verify external-storage data if applicable.

A backup is only as valuable as your ability to restore it.

## 18. Important limitation

This script is not a generic Nextcloud backup framework.

It is designed around a specific Docker Compose deployment and its filesystem layout.

If any of the following change, review the script before using it:

- Nextcloud version
- Docker volume name
- mount paths
- PostgreSQL database name
- PostgreSQL username
- external-storage layout
- appdata location
- Docker Compose service names
- Borg repository
- SSH authentication

Do not assume the script will automatically adapt to a different installation.
