# Restore Guide

This document explains how to restore a Nextcloud installation from a Borg archive created by `backup.sh`.

The procedure is designed for two situations:

1. **Recovery on the existing server**
2. **Disaster recovery after a complete server loss**

The restore is destructive. It replaces existing Nextcloud files and the PostgreSQL database with the contents of the selected backup.

Read this document completely before running `restore.sh`.

## 1. What the restore does

A complete restore follows this sequence:

```text
Select Borg archive
       |
       v
Stop Docker Compose
       |
       v
Extract Borg archive
       |
       v
Restore Nextcloud configuration
       |
       v
Restore Nextcloud data
       |
       v
Restore appdata
       |
       v
Restore external storage
       |
       v
Restore nextcloud_html Docker volume
       |
       v
Start PostgreSQL
       |
       v
Create empty database
       |
       v
Import SQL dump
       |
       v
Start complete Docker Compose stack
       |
       v
Verify Nextcloud
```

## 2. Before restoring

Make sure you have:

- root access to the server
- Docker installed
- Docker Compose v2 available as `docker compose`
- BorgBackup installed
- the correct `docker-compose.yml`
- the correct `.env`
- access to the remote Borg repository
- the Borg passphrase
- the SSH key required to access the Borg repository
- sufficient disk space for the extracted backup
- sufficient disk space for the restored Nextcloud data

Check:

```bash
docker --version
docker compose version
borg --version
```

## 3. Disaster recovery prerequisites

If the original server is completely lost, recreate the required filesystem layout first.

The deployment expects:

```text
/opt/nextcloud/
/mnt/hdd/nextcloud/data/
/mnt/ssd-working/appdata_oc464t3i6cse/
/mnt/ssd-working/nc_external_storage/
```

Create the parent directories if required:

```bash
mkdir -p /opt/nextcloud
mkdir -p /mnt/hdd/nextcloud/data
mkdir -p /mnt/ssd-working/appdata_oc464t3i6cse
mkdir -p /mnt/ssd-working/nc_external_storage
```

Copy the correct:

```text
docker-compose.yml
.env
restore.sh
```

into `/opt/nextcloud`.

The Compose file should match the installation for which the backup was created.

## 4. Restore credentials

The `.env` file is required because `restore.sh` needs:

```env
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PASSWORD=your-postgres-password

BORG_REPO=user@backup-server:/path/to/repository
BORG_PASSPHRASE=your-long-borg-passphrase
```

If a custom SSH key is used:

```env
BORG_RSH=ssh -i /root/.ssh/borg_backup
```

Secure the file:

```bash
chmod 600 /opt/nextcloud/.env
chown root:root /opt/nextcloud/.env
```

## 5. Verify access to the Borg repository

Before performing a destructive restore, verify that the repository is accessible:

```bash
borg list "$BORG_REPO"
```

You should see archives similar to:

```text
nextcloud-2026-09-10_03-00-01
nextcloud-2026-09-11_03-00-02
nextcloud-2026-09-12_03-00-01
```

If this command does not work, **do not start the restore**.

Fix the Borg repository or SSH configuration first.

## 6. Selecting a backup

`restore.sh` displays the available archives:

```bash
borg list "$BORG_REPO"
```

It then asks:

```text
Which backup should be restored?
```

Enter the exact archive name.

For example:

```text
nextcloud-2026-09-12_03-00-01
```

Use a backup that is known to be healthy.

When possible, choose the newest backup that was created before the incident.

## 7. Destructive confirmation

The script explicitly asks for confirmation.

You must enter:

```text
yes
```

to continue.

Anything else aborts the operation.

This is intentional. A restore should never happen accidentally.

## 8. Why Docker Compose is stopped

The complete Compose stack is stopped before files are replaced.

This prevents:

- Nextcloud from modifying restored files
- PostgreSQL from modifying its database
- PHP processes from holding files open
- application jobs from changing state during restoration

The restore should be treated as a controlled replacement of the entire application state.

## 9. Docker volume restoration

The Compose file defines:

```yaml
volumes:
  - nextcloud_html:/var/www/html
```

The restore script asks Docker for the volume's actual mountpoint:

```bash
docker volume inspect nextcloud_nextcloud_html
```

This usually points to a directory similar to:

```text
/var/lib/docker/volumes/nextcloud_nextcloud_html/_data
```

The script then restores the contents of the selected Borg archive into that location.

The mountpoint is discovered dynamically rather than assuming a fixed Docker storage path.

## 10. Restoring the Nextcloud directories

The following directories are restored:

```text
/opt/nextcloud/config
/mnt/hdd/nextcloud/data
/mnt/ssd-working/appdata_oc464t3i6cse
/mnt/ssd-working/nc_external_storage
```

Existing contents are removed before the backup contents are copied into place.

This is why the restore is destructive.

Do not use the script if you only want to recover one individual file.

## 11. PostgreSQL restoration

The backup contains:

```text
/tmp/nc-backup/nextcloud-db.sql
```

inside the Borg archive.

After the filesystem has been restored, PostgreSQL is started.

The script waits for PostgreSQL to become ready using:

```bash
pg_isready
```

It then recreates the Nextcloud database.

Conceptually:

```text
existing database
       |
       v
DROP DATABASE
       |
       v
CREATE DATABASE
       |
       v
import nextcloud-db.sql
```

The SQL dump is imported using PostgreSQL's `psql`.

## 12. Why the PostgreSQL data directory is recreated

The original PostgreSQL directory:

```text
/opt/nextcloud/postgres
```

is not restored from the backup.

This is intentional.

The backup contains a logical PostgreSQL dump rather than a raw copy of PostgreSQL's internal data directory.

The new PostgreSQL container creates a clean database storage directory and the SQL dump reconstructs the database contents.

This avoids relying on a potentially incompatible or incomplete copy of PostgreSQL's internal files.

## 13. Starting Nextcloud

After the database has been restored, the complete Compose stack is started:

```bash
docker compose -f /opt/nextcloud/docker-compose.yml up -d
```

Nextcloud should then start using:

- the restored configuration
- the restored files
- the restored appdata
- the restored PostgreSQL database
- the existing Compose configuration

## 14. Post-restore verification

Do not stop at:

```text
RESTORE ABGESCHLOSSEN
```

The script only confirms that the scripted restoration steps completed.

You must manually verify the actual application.

Check:

```bash
docker compose ps
```

All required services should be running.

For this deployment, check at least:

```text
db
redis
app
```

Then inspect logs:

```bash
docker compose logs --tail=100 app
docker compose logs --tail=100 db
docker compose logs --tail=100 redis
```

Look for errors.

## 15. Verify the Nextcloud web interface

Open the normal Nextcloud URL.

Check:

- login works
- existing users are present
- files are visible
- files can be opened
- uploads work
- downloads work
- application configuration is present
- external storage is available
- sharing functionality works
- background jobs operate normally

If the server is behind a reverse proxy, also verify:

- HTTPS works
- the correct hostname is used
- the reverse proxy can reach the Nextcloud container
- trusted proxy settings are correct

## 16. Verify the database

You can check that PostgreSQL is accepting connections:

```bash
docker compose exec -T db     pg_isready     -U "$DB_USER"     -d "$DB_NAME"
```

You can also inspect the database:

```bash
docker compose exec -T db     psql     -U "$DB_USER"     -d "$DB_NAME"     -c '\dt'
```

A restored Nextcloud database should contain many Nextcloud tables.

## 17. Check Nextcloud's status

Once the application is running, use:

```bash
docker compose exec -T app     php /var/www/html/occ status
```

The output should indicate a functioning Nextcloud installation.

You can also run:

```bash
docker compose exec -T app     php /var/www/html/occ maintenance:mode
```

to check whether maintenance mode is disabled.

## 18. File ownership and permissions

Docker containers and bind mounts can make file ownership important.

If Nextcloud reports permission errors after a restore, inspect:

```bash
ls -la /opt/nextcloud/config
ls -la /mnt/hdd/nextcloud/data
ls -la /mnt/ssd-working/appdata_oc464t3i6cse
ls -la /mnt/ssd-working/nc_external_storage
```

Also inspect the ownership of files inside the Docker volume.

Do not blindly run recursive `chmod 777` or `chown` commands.

Use the ownership expected by the official Nextcloud Docker image and your existing deployment.

## 19. Full server disaster recovery

If the entire server has been destroyed, the recovery order should be:

### Step 1 — Reinstall the operating system

Install a supported Linux distribution.

### Step 2 — Install Docker

Install Docker Engine and Docker Compose v2.

Verify:

```bash
docker --version
docker compose version
```

### Step 3 — Install Borg

Verify:

```bash
borg --version
```

### Step 4 — Restore SSH access

Install the SSH private key used to access the Borg repository:

```text
/root/.ssh/borg_backup
```

Protect it:

```bash
chmod 600 /root/.ssh/borg_backup
```

### Step 5 — Recreate the directory layout

Create:

```text
/opt/nextcloud
/mnt/hdd/nextcloud/data
/mnt/ssd-working/appdata_oc464t3i6cse
/mnt/ssd-working/nc_external_storage
```

### Step 6 — Restore configuration files

Restore:

```text
docker-compose.yml
.env
restore.sh
```

The Compose file must match the deployment that created the backup.

### Step 7 — Test Borg

Run:

```bash
borg list "$BORG_REPO"
```

Do not continue until the repository is accessible.

### Step 8 — Run restore

```bash
/opt/nextcloud/restore.sh
```

Select the desired archive.

### Step 9 — Verify the application

Follow the post-restore checks in this document.

## 20. What happens to `nextcloud_tmp`?

The deployment uses:

```text
/mnt/ssd-working/nextcloud_tmp
```

for temporary data.

It is intentionally not part of the backup.

After a disaster, recreate the directory if it does not exist:

```bash
mkdir -p /mnt/ssd-working/nextcloud_tmp
```

Docker Compose will then mount it into the container.

Temporary files are not considered part of the persistent Nextcloud state.

## 21. What happens to Redis?

Redis is configured without a persistent volume.

The restore therefore does not restore Redis data.

This is normally fine because Redis is used as runtime infrastructure in this deployment.

The container is recreated and starts with an empty Redis state.

## 22. What happens to the PostgreSQL directory?

The old directory:

```text
/opt/nextcloud/postgres
```

is recreated by PostgreSQL.

The restore script does not copy the old directory into the new PostgreSQL instance.

The database contents come from the SQL dump.

## 23. Recovery point considerations

Every Borg archive represents the state of the Nextcloud filesystem and PostgreSQL database at the time of the backup.

For example:

```text
nextcloud-2026-09-12_03-00-01
```

represents a recovery point around that time.

Any changes made after that backup are not present in the restored state.

If the backup runs once per day, you can lose up to roughly one day's worth of changes depending on when the failure occurs.

If this is unacceptable, increase the backup frequency.

## 24. Restore testing

A real disaster should not be the first time the restore procedure is tested.

Recommended procedure:

1. Deploy a separate test server.
2. Install Docker and Borg.
3. Provide the test server with access to the Borg repository.
4. Run `restore.sh`.
5. Restore the newest archive.
6. Verify the complete Nextcloud installation.
7. Document any manual steps required.
8. Repeat periodically.

This verifies both the backup itself and the documentation.

## 25. Important warning about the backup repository

Do not keep the only Borg repository on the same physical disk as the Nextcloud server.

A server failure, filesystem corruption, theft, accidental deletion or ransomware incident could destroy both the production data and the backup.

A better architecture is:

```text
                ┌──────────────────────┐
                │    Nextcloud Server  │
                │                      │
                │ Docker               │
                │ PostgreSQL           │
                │ Nextcloud data       │
                └──────────┬───────────┘
                           │
                           │ SSH / Borg
                           v
                ┌──────────────────────┐
                │   Remote Backup      │
                │                      │
                │ Encrypted Borg repo  │
                └──────────────────────┘
```

For stronger protection, maintain an additional independent copy of the backup repository.

## 26. What if the restore fails?

Do not immediately delete the selected Borg archive.

First determine which stage failed:

```text
Borg access
Docker startup
filesystem restore
PostgreSQL startup
database import
Nextcloud startup
application configuration
```

Useful commands include:

```bash
borg info "$BORG_REPO"
borg list "$BORG_REPO"
```

and:

```bash
docker compose ps
docker compose logs --tail=200
```

If PostgreSQL fails:

```bash
docker compose logs --tail=200 db
```

If Nextcloud fails:

```bash
docker compose logs --tail=200 app
```

If the SQL import fails, verify that the database credentials and PostgreSQL container version match the expected deployment.

## 27. Do not overwrite your only evidence

If you are investigating a failed restore, avoid repeatedly modifying the same production system.

If possible:

1. Clone the environment.
2. Keep the original Borg archive untouched.
3. Perform recovery on a separate system.
4. Record errors and commands.
5. Only migrate the restored instance into production after validation.

## 28. Final recovery checklist

After a successful restore, verify all of the following:

- [ ] Docker Compose is running.
- [ ] PostgreSQL is healthy.
- [ ] Redis is healthy.
- [ ] Nextcloud is reachable.
- [ ] Nextcloud maintenance mode is disabled.
- [ ] Login works.
- [ ] Existing users are present.
- [ ] Existing files are present.
- [ ] Existing files can be opened.
- [ ] Uploads work.
- [ ] Downloads work.
- [ ] External storage works.
- [ ] Nextcloud configuration is correct.
- [ ] Reverse proxy/HTTPS works.
- [ ] Background jobs work.
- [ ] No critical errors appear in the container logs.
- [ ] A new backup can be created after the restore.

Only after these checks should the recovered server be considered operational.
