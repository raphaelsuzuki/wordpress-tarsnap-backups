# WordPress Tarsnap Backups

This script automates the backup of WordPress sites using Tarsnap. It creates a backup of the site files and database, excluding cache and backup directories. It is designed to be run as a cron job for daily backups.

## Features

- Backs up WordPress site files and databases
- Excludes cache and backup directories
- Uses Tarsnap for secure, encrypted backups
- Implements a retention policy to manage backup storage
- Designed to be run as a cron job for daily backups

## Requirements

- Tarsnap
- mysqldump
- grep with PCRE support

## Configuration

Before running the script, you need to configure the following variables in the script:

- `SITES_ROOT`: Root directory containing your WordOps sites
- `TEMP_BACKUP_DIR`: Temporary directory for database dumps
- `TARSNAP_KEY_FILE`: Path to your Tarsnap key file
- `EXCLUDED_SITES`: Array of site directory names to exclude from the backup process
- `RETENTION_DAYS`: Number of days to keep backups
- `MIN_BACKUPS_TO_KEEP`: Minimum number of backups to always keep per site

## Usage

1. Configure the script by setting the variables in the Configuration section.
2. Ensure the script has execute permissions:
   ```bash
   chmod +x /path/to/your/backup_wordpress_tarsnap.sh
   ```
3. Ensure your Tarsnap key file has appropriate permissions (usually 600 for the root user):
   ```bash
   chmod 600 /path/to/tarsnap.key
   ```
4. Add the script to the root user's crontab to run daily:
   ```bash
   sudo crontab -e
   ```
   Add the following line to the end of the file:
   ```bash
   0 3 * * * /bin/bash /path/to/your/backup_wordpress_tarsnap.sh >> /var/log/wo_backup.log 2>&1
   ```
   This example runs the script daily at 3:00 AM.

## Restore Instructions

To restore a backup created by this script using Tarsnap, follow these steps:

1. List all available Tarsnap archives to find the one you want to restore:
   ```bash
   tarsnap --key-file /path/to/tarsnap.key --list-archives
   ```
2. Restore the desired archive. This will restore site files and the temporary DB dump:
   ```bash
   tarsnap --key-file /path/to/tarsnap.key -x -f <archive-name> -C /
   ```
   (Replace `<archive-name>` with the name of the archive, e.g., `site-2025-05-31-030000`)
3. Locate the database dump file in the temporary directory specified in the configuration.
4. Restore the database from the dump file:
   ```bash
   mysql -u <db_user> -p<db_password> <db_name> < /path/to/temp/dir/site-name_db_timestamp.sql
   ```
5. Verify the restoration by checking site files and database content.
   Then, fix file ownership and permissions:
   ```bash
   chown -R www-data:www-data /var/www/<site-name>
   ```
6. Restart WordOps services:
   ```bash
   wo stack restart
   ```

Note: Always test the restoration process in a staging environment first.