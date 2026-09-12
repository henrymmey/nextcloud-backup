# Nextcloud Backup & Restore

A small Bash-based backup and restore solution for a Docker Compose-based Nextcloud installation using [BorgBackup](https://www.borgbackup.org/) and PostgreSQL.

This project is designed for a specific, file-based Nextcloud deployment where:

- Nextcloud runs in Docker Compose.
- PostgreSQL runs in a Docker container.
- Nextcloud data is stored on host-mounted directories.
- Nextcloud's application files are stored in a Docker volume.
- Backups are stored in a remote Borg repository.
- PostgreSQL is backed up using `pg_dump`.
- Nextcloud is put into maintenance mode while the backup is created.

> **Important:** This project is intended as an infrastructure script for a known Nextcloud layout. It is not a universal Nextcloud backup solution. Review the configuration and paths before using it on another server.

## Features

- PostgreSQL database dump using `pg_dump`
- BorgBackup with Zstandard compression
- Borg repository encryption using a passphrase
- Remote Borg repositories over SSH
- Nextcloud maintenance mode during the backup
- Automatic cleanup after success or failure
- Protection against concurrent backup executions using `flock`
- Borg retention using daily, weekly and monthly policies
- Separate restore procedure for disaster recovery
- Secrets loaded from a local `.env` file instead of hard-coding them into the scripts

## Repository files

| File | Purpose |
| --- | --- |
| `backup.sh` | Creates and prunes encrypted Borg backups |
| `restore.sh` | Restores a selected Borg archive |
| `.env.example` | Example configuration for secrets and Borg settings |
| `BACKUP.md` | Detailed backup documentation |
| `RESTORE.md` | Detailed disaster-recovery and restore documentation |

## How it works

The backup process is intentionally conservative:

1. The script verifies its configuration and required paths.
2. It checks that the Borg repository is reachable.
3. Nextcloud is put into maintenance mode.
4. PostgreSQL is exported with `pg_dump`.
5. Borg creates an encrypted archive containing the Nextcloud files and SQL dump.
6. Old Borg archives are removed according to the retention policy.
7. The temporary SQL dump is deleted.
8. Nextcloud maintenance mode is disabled.

The maintenance mode remains enabled until the Borg archive has been created successfully. This is important because backing up a database and the corresponding filesystem while Nextcloud is actively modifying files can produce an inconsistent backup.

For a detailed explanation, see [`BACKUP.md`](BACKUP.md).

## What is backed up?

With the intended deployment layout, the backup contains:

- `/opt/nextcloud/docker-compose.yml`
- `/opt/nextcloud/config`
- `/mnt/hdd/nextcloud/data`
- `/mnt/ssd-working/appdata_oc464t3i6cse`
- `/mnt/ssd-working/nc_external_storage`
- the Docker volume `nextcloud_nextcloud_html`
- a PostgreSQL SQL dump

The following are deliberately not backed up:

- `/mnt/ssd-working/nextcloud_tmp` because it is temporary data
- `/opt/nextcloud/postgres` as a live PostgreSQL data directory; PostgreSQL is backed up using `pg_dump`
- Redis runtime state; Redis is recreated by Docker Compose

See [`BACKUP.md`](BACKUP.md) for the exact backup layout and the reasons behind it.

## Requirements

The scripts expect a Linux host with:

- Bash
- Docker Engine
- Docker Compose v2 (`docker compose`)
- BorgBackup
- OpenSSH client
- `flock`
- root privileges

The Docker Compose project must be available at:

```text
/opt/nextcloud/docker-compose.yml
```

The backup repository must already exist and be accessible by the configured SSH account.

## Configuration

Create the real configuration file from the example:

```bash
cp .env.example /opt/nextcloud/.env
```

Edit it:

```bash
nano /opt/nextcloud/.env
```

At minimum, configure:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=your-postgres-password

BORG_REPO=user@backup-server:/path/to/repository
BORG_PASSPHRASE=your-long-borg-passphrase
```

Protect the file:

```bash
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

Never commit the real `.env` file to Git.

### SSH authentication

SSH authentication should preferably use a dedicated Ed25519 key instead of a password.

For example:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/borg_backup
```

Then configure:

```env
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

The private key must be protected:

```bash
chmod 600 /root/.ssh/borg_backup
```

For a dedicated backup server, the SSH key should ideally be restricted to Borg operations rather than providing unrestricted shell access.

## Installation

Copy the scripts to the Nextcloud host:

```bash
cp backup.sh /opt/nextcloud/backup.sh
cp restore.sh /opt/nextcloud/restore.sh
```

Make them executable:

```bash
chmod 700 /opt/nextcloud/backup.sh
chmod 700 /opt/nextcloud/restore.sh
```

Create and secure the environment file as described above.

Before relying on the backup, run it manually and verify the resulting Borg archive.

## Running a backup

Run:

```bash
sudo /opt/nextcloud/backup.sh
```

The script prints progress and Borg statistics to the terminal.

A successful run ends with:

```text
BACKUP ERFOLGREICH
```

The backup is not considered successful merely because the SQL dump was created. The Borg archive itself must be created successfully.

## Retention

The default policy is:

```text
7 daily
4 weekly
12 monthly
```

It is implemented using:

```bash
borg prune     --keep-daily=7     --keep-weekly=4     --keep-monthly=12
```

Adjust this according to the size of the repository and your recovery requirements.

## Restore

The restore process is destructive: it overwrites Nextcloud files and replaces the PostgreSQL database with the database contained in the selected backup.

Do not run it casually on a production system.

The complete procedure is documented in [`RESTORE.md`](RESTORE.md).

The high-level process is:

1. List available Borg archives.
2. Select an archive.
3. Confirm the destructive operation.
4. Stop the Docker Compose stack.
5. Extract the selected Borg archive.
6. Restore the Nextcloud directories.
7. Restore the Docker volume.
8. Start PostgreSQL.
9. Recreate the Nextcloud database.
10. Import the PostgreSQL SQL dump.
11. Start the complete stack.
12. Verify Nextcloud.

## Disaster recovery

For a complete server loss, you need more than the backup archive itself.

Keep safe copies of:

- this repository or the scripts
- the exact `docker-compose.yml`
- the real `.env` file or its secrets
- the Borg repository location
- the Borg passphrase
- the SSH private key used to access the Borg repository
- any SSH host-key information or access information required to reach the backup server

**The Borg passphrase is critical.** If the repository is encrypted and the passphrase is lost, the backup data cannot be recovered.

Likewise, losing the SSH key can prevent access to a remote repository even if the Borg passphrase is still available.

## Security notes

### Secrets

Do not put real passwords, Borg passphrases or private SSH keys into Git.

The repository should contain only an example environment file.

### Borg encryption

Borg encrypts the repository according to its configured encryption mode. The repository itself should be initialized securely on the backup server before production use.

### Backup server

A backup server should be treated as a security-sensitive system. Ideally:

- use a dedicated backup account
- use a dedicated SSH key
- restrict the SSH key to Borg operations
- disable password authentication where appropriate
- keep the backup server separate from the Nextcloud host
- restrict network access
- monitor repository health

### Backups are not automatically trustworthy

A backup that has never been restored is only an assumption.

Regularly test:

```bash
borg list "$BORG_REPO"
borg info "$BORG_REPO"
```

and periodically perform a full test restore on a separate system.

## Limitations

This project is intentionally tied to a specific filesystem layout and Docker Compose configuration.

Before using it elsewhere, review:

- Docker service names
- PostgreSQL database credentials
- Docker volume name
- Nextcloud config path
- Nextcloud data path
- appdata path
- external-storage path
- Docker volume mountpoint
- Borg repository
- SSH configuration

The scripts do not automatically discover an arbitrary Nextcloud installation.

## License

See the repository license for the applicable license terms.
