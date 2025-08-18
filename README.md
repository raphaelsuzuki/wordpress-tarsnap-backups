# WordPress Tarsnap Backups

Automated WordPress backup script using Tarsnap for multiple sites, designed for WordOps environments.

## Overview

1. **Site Discovery:** Finds all WordPress installations in the configured root directory (typically `/var/www/`).
2. **Database Extraction:** Securely extracts database credentials from `wp-config.php` files.
3. **Database Backup:** Creates compressed SQL dumps with timeout protection.
4. **File Backup:** Archives site files excluding cache and backup directories.
5. **Secure Storage:** Uses Tarsnap for encrypted, deduplicated remote storage.
6. **Retention Management:** Automatically removes old backups based on configurable policies.
7. **Error Handling:** Comprehensive error checking with secure cleanup of temporary files.
8. **Logging:** Detailed logging of all backup operations and errors.

## Requirements

- `tarsnap` (with account and key file)
- `mysqldump`

## Usage

1. Place `backup-wordpress-tarsnap.sh` in a secure location (e.g., `/usr/local/bin/`).
2. Make it executable and set appropriate ownership:
   ```sh
   sudo chmod +x /usr/local/bin/backup-wordpress-tarsnap.sh
   sudo chown root:root /usr/local/bin/backup-wordpress-tarsnap.sh
   ```
3. Configure your Tarsnap key file with secure permissions:
   ```sh
   sudo chmod 600 /path/to/tarsnap.key
   sudo chown root:root /path/to/tarsnap.key
   ```
4. Set up a cron job as `root` user (required for permissions to read `/var/www/` directories, run `mysqldump`, and access the Tarsnap key file):
   ```sh
   sudo crontab -e
   ```
   Add sommething like the following line for daily backups at 3:00 AM:
   ```
   0 3 * * * /usr/local/bin/backup-wordpress-tarsnap.sh >> /var/log/wo_backup.log 2>&1
   ```
  
   The `>> /var/log/wo_backup.log 2>&1` redirects all output and errors to a log file for monitoring.

## Configuration

Edit the script variables as needed:

- **Site root:** Change `SITES_ROOT` if your WordPress sites are not in `/var/www/`.
- **Temp directory:** Set `TEMP_BACKUP_DIR` for database dumps. **Warning:** `/tmp` can be a small RAM-based filesystem (tmpfs). For large databases, consider `/var/tmp`.
- **Tarsnap key:** Set `TARSNAP_KEY_FILE` path to your Tarsnap key file.
- **Excluded sites:** Add site directory names to `EXCLUDED_SITES` array (e.g., `"22222"`, `"html"`, `"staging.example.com"`).
- **Retention policy:** Configure `RETENTION_DAYS` (days to keep backups) and `MIN_BACKUPS_TO_KEEP` (minimum backups to always retain per site).

## Restore Instructions

To restore a backup created by this script:

1. List available archives:
   ```bash
   tarsnap --key-file /path/to/tarsnap.key --list-archives
   ```
2. Restore the desired archive:
   ```bash
   tarsnap --key-file /path/to/tarsnap.key -x -f <archive-name> -C /
   ```
3. Restore the database from the dump file:
   ```bash
   mysql -u <db_user> -p<db_password> <db_name> < /path/to/temp/dir/site-name_db_timestamp.sql
   ```
4. Fix file ownership and permissions:
   ```bash
   chown -R www-data:www-data /var/www/<site-name>
   ```
5. Restart services:
   ```bash
   wo stack restart
   ```

## Security Features

- Secure temporary file creation with proper permissions
- Input validation and sanitization of database credentials
- Protection against command injection and ReDoS attacks
- Automatic cleanup of sensitive temporary files
- Timeout protection for long-running operations

## Limitations

- Requires root access for comprehensive site backup
- Database dumps stored temporarily in plaintext (secured with 600 permissions)
- No incremental backup support (Tarsnap handles deduplication)
- Limited to MySQL/MariaDB databases

## Safety

**Test in a non-production environment before deploying!**

## Troubleshooting

- **Tarsnap not found:** Ensure Tarsnap is installed and in PATH
- **Permission errors:** Run as root or ensure access to all site directories
- **Database connection fails:** Check MySQL credentials and connectivity
- **Disk space issues:** Monitor temp directory space, especially for large databases
- **Key file errors:** Verify Tarsnap key file path and permissions

## Contributing

Pull requests and suggestions are welcome! Please open issues for bugs or feature requests.

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

This repository and its documentation were created with the assistance of AI. While efforts have been made to ensure accuracy and completeness, no guarantee is provided. Use at your own risk. Always test in a safe environment before deploying to production.