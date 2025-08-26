# WordPress Tarsnap Backups

Automated backup solution for WordPress sites using Tarsnap

Tarsnap is one of the most advanced backup systems ever created. This script utilizes the online service to create secure, deduplicated, and end-to-end encrypted backups of your WordPress sites. With all the important features at a fraction of the cost of other solutions, it offers the best combination of security, reliability and affordability.

**Note**: This is an unofficial script and is not affiliated with or endorsed by Tarsnap Inc.

## Overview

1. **Site Discovery:** Finds all WordPress installations in the configured root directory (typically `/var/www/`).
2. **Credentials Extraction:** Securely extracts database credentials from `wp-config.php` files of each installation.
3. **Database Backup:** Creates SQL dumps with timeout protection.
4. **File Backup:** Archives site files excluding cache and backup directories. You can also exclude any unwanted site from your backups.
5. **Secure Storage:** Tarsnap is end-to-end encrypted and has deduplication on remote storages by default.
6. **Retention Management:** Automatically removes old backups based on many configurable policies.
7. **Error Handling:** Comprehensive error checking with secure cleanup of temporary files.
8. **Logging:** Detailed logging of all backup operations and errors.
9. **Email Notifications:** Sends completion and error (if any) notifications via email.

## Requirements

- `tarsnap`: Tarsnap account configured with key file installed
- `mysqldump`
- [Optional] Mail sending configured (for notifications).

## Limitations

- Requires root access for site backups
- Backups are stored with deduplication only
- No builtin restoration functionality: You'll need to use the tarsnap command-line to manually restore your sites
 
## Retention Policy

The script supports multiple retention schemes:

### Simple Retention (default)

A dual-criteria retention system commonly used by WordPress backup plugins that ensures backup safety:
- **Age limit**: Archives older than `RETENTION_DAYS` become candidates for deletion
- **Minimum count**: Always preserves at least `MIN_BACKUPS_TO_KEEP` most recent backups per site

Archives are deleted only when **both** conditions are satisfied:
1. The archive exceeds the age limit
2. Sufficient newer backups exist to maintain the minimum count

### GFS Retention (Grandfather-Father-Son)

A hierarchical backup scheme that provides data protection through multiple retention periods. Popular among Tarsnap users and backup solutions like Apple's Time Machine. It consists of:
- **Hourly backups**: Recent backups for immediate recovery (default: 24 hours)
- **Daily backups**: Recent backups for quick recovery (default: 7 days)
- **Weekly backups**: Sunday backups for medium-term retention (default: 4 weeks)
- **Monthly backups**: First-of-month backups for long-term retention (default: 12 months)
- **Yearly backups**: First-of-year backups for archival purposes (default: 3 years)

To enable GFS retention, set `RETENTION_SCHEME="gfs"` and configure the GFS_* variables.

### Manual Retention

No automatic cleanup is performed - you manage all backup deletion manually.

To enable manual retention, set `RETENTION_SCHEME="manual"`.

**Warning**: Manual retention can lead to:
- **High storage costs** - Tarsnap charges for all stored data
- **Performance issues** - Large numbers of archives slow operations
- **Forgotten cleanup** - Archives accumulate indefinitely without manual intervention

Use manual retention only when you have specific requirements and will actively manage archive cleanup.

## Usage

1. Place the script and configuration file in a secure location:
   ```sh
   sudo cp wordpress-tarsnap-backups.sh /usr/local/bin/
   sudo cp wordpress-tarsnap-backups.conf /etc/
   sudo chmod +x /usr/local/bin/wordpress-tarsnap-backups.sh
   sudo chown root:root /usr/local/bin/wordpress-tarsnap-backups.sh /etc/wordpress-tarsnap-backups.conf
   ```
2. Edit the configuration file according to your environment:
   ```sh
   sudo nano /etc/wordpress-tarsnap-backups.conf
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
   Add something like the following line for daily backups at 3:00 AM:
   ```
   0 3 * * * /usr/local/bin/wordpress-tarsnap-backups.sh /etc/wordpress-tarsnap-backups.conf >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1
   ```

   Or this one if you are using hourly GFS backups:
   ```sh
   0 * * * * /usr/local/bin/wordpress-tarsnap-backups.sh >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1
   ```

   The `>> /var/log/wordpress-tarsnap-backups/cron.log 2>&1` redirects all output and errors to a log file for monitoring.

## Configuration

The script uses an external configuration file `wordpress-tarsnap-backups.conf`.

### Configuration Options:

- **Site root:** `SITES_ROOT` - Directory containing WordPress sites (default: `/var/www`)
- **Temp directory:** `TEMP_BACKUP_DIR` - For database dumps (default: `/tmp`)
- **Tarsnap key:** `TARSNAP_KEY_FILE` - Path to Tarsnap key file (default: `/root/tarsnap.key`)
- **Log directory:** `LOG_DIR` - Log storage location (default: `/var/log/wordpress-tarsnap-backups`)
- **Excluded sites:** `EXCLUDED_SITES` - Space-separated list of site directories to skip
- **Retention policy:** `RETENTION_SCHEME` - Choose `"simple"`, `"gfs"`, or `"manual"`
  - Simple: `RETENTION_DAYS` and `MIN_BACKUPS_TO_KEEP`
  - GFS: `GFS_HOURLY_KEEP`, `GFS_DAILY_KEEP`, `GFS_WEEKLY_KEEP`, `GFS_MONTHLY_KEEP`, `GFS_YEARLY_KEEP`
- **Email notifications:** `NOTIFY_EMAIL` - Email address for notifications

### Using Custom Configuration Examples:

```bash
# Use default config file (same directory as script)
./wordpress-tarsnap-backups.sh

# Use system config
./wordpress-tarsnap-backups.sh /etc/wordpress-tarsnap-backups.conf

# Use custom config file
./wordpress-tarsnap-backups.sh /path/to/custom.conf
```

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
5. Restart all required services.

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