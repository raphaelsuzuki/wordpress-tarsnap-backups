# WordPress Tarsnap Backups

Automated WordPress backup script using Tarsnap for multiple sites, designed for WordOps environments.

## Overview

1. **Site Discovery:** Finds all WordPress installations in the configured root directory (typically `/var/www/`).
2. **Credentials Extraction:** Securely extracts database credentials from `wp-config.php` files of each installation.
3. **Database Backup:** Creates SQL dumps with timeout protection.
4. **File Backup:** Archives site files excluding cache and backup directories.
5. **Secure Storage:** Uses Tarsnap for encrypted, deduplicated remote storage.
6. **Retention Management:** Automatically removes old backups based on configurable policies.
7. **Error Handling:** Comprehensive error checking with secure cleanup of temporary files.
8. **Logging:** Detailed logging of all backup operations and errors.
9. **Email Notifications:** Sends completion and error (if any) notifications via email.

## Requirements

- `tarsnap`: Tarsnap account configured with key file installed
- `mysqldump`
- [Optional] Mail sending configured (for notifications).

## Limitations

- Requires root access for comprehensive site backup
- Backups are stored with deduplication only
- No builtin restoration functionality: You'll need to use tarsnap commands to manually restore your sites
 
## Retention Policy

The script uses a dual retention approach for maximum safety:

- **Time-based**: Archives older than `RETENTION_DAYS` are eligible for deletion
- **Count-based**: Always keeps at least `MIN_BACKUPS_TO_KEEP` newest backups per site

An archive is only deleted if **both** conditions are met:
1. The archive is older than the retention period
2. There are enough newer backups to meet the minimum count requirement

This prevents accidental deletion of all backups if the script hasn't run for an extended period while still maintaining the desired retention schedule during regular operations.

## Usage

1. Place `wordpress-tarsnap-backups.sh` in a secure location (e.g., `/usr/local/bin/`).
2. Make it executable and set appropriate ownership:
   ```sh
   sudo chmod +x /usr/local/bin/wordpress-tarsnap-backups.sh
   sudo chown root:root /usr/local/bin/wordpress-tarsnap-backups.sh
   ```
3. Confirm that your Tarsnap key file has the following secure permissions:
   ```sh
   sudo chmod 600 /root/tarsnap.key
   sudo chown root:root /root/tarsnap.key
   ```
4. Set up a cron job as `root` user (required for permissions to read `/var/www/` directories, run `mysqldump`, and access the Tarsnap key file):
   ```sh
   sudo crontab -e
   ```
   Add sommething like the following line for daily backups at 3:00 AM:
   ```
   0 3 * * * /usr/local/bin/wordpress-tarsnap-backups.sh >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1
   ```
  
   The `>> /var/log/wordpress-tarsnap-backups/cron.log 2>&1` redirects all output and errors to a log file for monitoring.

## Configuration

Edit the script variables as needed:

- **Site root:** Change `SITES_ROOT` if your WordPress sites are not in `/var/www/`.
- **Temp directory:** Set `TEMP_BACKUP_DIR` for database dumps. **Warning:** `/tmp` can be a small RAM-based filesystem (tmpfs). For large databases, consider `/var/tmp`.
- **Tarsnap key:** Set `TARSNAP_KEY_FILE` path to your Tarsnap key file.
- **Log directory:** Set `LOG_DIR` for log storage (default: `/var/log/wordpress-tarsnap-backups`).
- **Excluded sites:** Add site directory names to `EXCLUDED_SITES` array (e.g., `"22222"`, `"html"`, `"staging.example.com"`).
- **Retention policy:** Configure `RETENTION_DAYS` (days to keep backups) and `MIN_BACKUPS_TO_KEEP` (minimum backups to always retain per site).
- **Email notifications:** Set `NOTIFY_EMAIL` to receive completion notifications and error alerts.

## Log Management

The script uses a two-tiered logging approach:

- **Main log**: `/var/log/wordpress-tarsnap-backups/backup.log` captures all backup operations
- **Per-site logs**: `/var/log/wordpress-tarsnap-backups/site-name.log` contain detailed logs for each WordPress site
- **Cron log**: `/var/log/wordpress-tarsnap-backups/cron.log` captures console output for monitoring

Log entries include timestamps and severity levels (INFO, WARNING, ERROR).

### Log Rotation

Add the following to `/etc/logrotate.d/wordpress-tarsnap-backups` for automatic log rotation:

```
# Logrotate configuration for WordPress Tarsnap backups
/var/log/wordpress-tarsnap-backups/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 root adm
    postrotate
        /bin/killall -HUP rsyslog 2>/dev/null || true
    endscript
}
```

## Restore Instructions

To restore a backup created by this script:

1. List available archives:
   ```bash
   TARSNAP_KEYFILE=/root/tarsnap.key tarsnap --list-archives
   ```
2. Restore the desired archive:
   ```bash
   TARSNAP_KEYFILE=/root/tarsnap.key tarsnap -x -f <archive-name> -C /
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

## Safety

**Test in a non-production environment before deploying!**

## Troubleshooting

- **Tarsnap not found:** Ensure Tarsnap is installed and in PATH
- **Permission errors:** Run as root or ensure access to all site directories
- **Database connection fails:** Check MySQL credentials and connectivity
- **Disk space issues:** Monitor temp directory space, especially for large databases
- **Key file errors:** Verify Tarsnap key file path and permissions
- **Log file not created:** Verify that `$LOG_DIR` exists and is writable by the script user
- **Check per-site logs:** Review individual site logs in `/var/log/wordpress-tarsnap-backups/` for detailed error information

## Contributing

Pull requests and suggestions are welcome! Please open issues for bugs or feature requests.

## License

MIT License. See [LICENSE](LICENSE) for details.

## Disclaimer

This repository and its documentation were created with the assistance of AI. While efforts have been made to ensure accuracy and completeness, no guarantee is provided. Use at your own risk. Always test in a safe environment before deploying to production.