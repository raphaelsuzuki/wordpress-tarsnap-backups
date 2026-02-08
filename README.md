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
7. **Error Handling:** Error checking with secure cleanup of temporary files.
8. **Logging:** Detailed logging of all backup operations and errors.
9. **Email Notifications:** Sends completion and error (if any) notifications via email.

## Requirements

- `tarsnap`: Tarsnap account configured with key file installed
- `mysqldump`
- [Optional] Mail sending configured (for notifications).

## Limitations

- Requires root access for site backups and restores
- Backups are stored with deduplication only
 
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

### Quick Install

Install directly from GitHub:

```sh
curl -fsSL https://raw.githubusercontent.com/raphaelsuzuki/wordpress-tarsnap-backups/main/install.sh | sudo bash
```

Or from your local copy:

```sh
sudo ./install.sh
```

Test the installation first with dry-run mode:

```sh
./install.sh --dry-run
```

### Manual Installation

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

### Backup Operations

4. Cron jobs must strict follow what type of retention policy you choose. Set up a cron job as `root` user (required for permissions to read `/var/www/` directories, run `mysqldump`, and access the Tarsnap key file):
   ```sh
   sudo crontab -e
   ```
   If you are using Simple Retention, add the following line for daily backups at 2:30 AM:
   ```sh
   30 2 * * * /usr/local/bin/wordpress-tarsnap-backups.sh >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1
   ```

   Or this one if you are using hourly GFS backups:
   ```sh
   30 * * * * /usr/local/bin/wordpress-tarsnap-backups.sh >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1
   ```

### Restore Operations

5. To restore a WordPress site from backup:
   ```sh
   sudo /usr/local/bin/wordpress-tarsnap-backups.sh --restore
   ```



## Configuration

The script uses an external configuration file `wordpress-tarsnap-backups.conf`.

### Configuration File Loading Priority:

When run **without arguments**, the script searches for configuration files in this order:
1. `/etc/wordpress-tarsnap-backups.conf` (system-wide config)
2. `wordpress-tarsnap-backups.conf` (same directory as script)
3. Built-in defaults (if no config file found)

### Configuration File Examples:

```bash
# Use automatic config discovery (recommended)
./wordpress-tarsnap-backups.sh

# Use specific config file
./wordpress-tarsnap-backups.sh /path/to/custom.conf
```

### Configuration Options:

- **Site root:** `SITES_ROOT` - Directory containing WordPress sites (default: `/var/www`)
- **Temp directory:** `TEMP_BACKUP_DIR` - For database dumps (default: `/tmp`)
- **Tarsnap key:** `TARSNAP_KEY_FILE` - Path to Tarsnap key file (default: `/root/tarsnap.key`)
- **Log directory:** `LOG_DIR` - Log storage location (default: `/var/log/wordpress-tarsnap-backups`)
- **Site selection:** 
  - `EXCLUDED_SITES` - Space-separated list of site directories to skip
  - `INCLUDED_SITES` - Space-separated list of site directories to backup exclusively (overrides EXCLUDED_SITES when set)
- **Directory exclusion:** `EXCLUDED_DIRECTORIES` - Space-separated list of directory patterns to exclude from all site backups
- **Retention policy:** `RETENTION_SCHEME` - Choose `"simple"`, `"gfs"`, or `"manual"`
  - Simple: `RETENTION_DAYS` and `MIN_BACKUPS_TO_KEEP`
  - GFS: `GFS_HOURLY_KEEP`, `GFS_DAILY_KEEP`, `GFS_WEEKLY_KEEP`, `GFS_MONTHLY_KEEP`, `GFS_YEARLY_KEEP`
- **Email notifications:** `NOTIFY_EMAIL` - Email address for notifications
- **Performance options:**
  - `SHOW_PROGRESS` - Show progress indicators during long operations (`yes`/`no`, default: `yes`)
  - `PRINT_STATS` - Print detailed archive statistics after backup (`yes`/`no`, default: `yes`)
    - Note: When enabled, makes an additional network call to Tarsnap servers

### Performance Tuning

The script includes configurable performance options:

- **Progress Indicators** (`SHOW_PROGRESS`): Shows real-time progress during database dumps and Tarsnap uploads. Disable for slightly faster operations in automated environments where output isn't monitored.

- **Archive Statistics** (`PRINT_STATS`): Fetches detailed size information after each backup. Disable to skip the additional network call to Tarsnap servers, reducing backup time by a few seconds per site.

## Selective Site Processing

The script supports two modes for controlling which sites get backed up:

### Default Mode (All Sites)
```bash
# Backup all sites except excluded ones
INCLUDED_SITES=""
EXCLUDED_SITES="22222 html staging"
```

### Selective Mode (Specific Sites Only)
```bash
# Backup ONLY these sites (ignores EXCLUDED_SITES)
INCLUDED_SITES="example.com site2.com"
EXCLUDED_SITES="22222 html"  # This is ignored when INCLUDED_SITES is set
```

### Use Cases
- **Single site backups:** Set `INCLUDED_SITES="example.com"` for site-specific configurations
- **Subset backups:** Backup only critical sites during maintenance windows
- **Testing:** Backup staging sites separately from production
- **Flexible scheduling:** Different cron jobs for different site groups

## Directory Exclusion

The script supports fine-grained directory exclusion through the `EXCLUDED_DIRECTORIES` configuration:

```bash
# Exclude specific directory patterns from all site backups
EXCLUDED_DIRECTORIES="cache logs tmp uploads/cache wp-content/cache wp-content/updraft wp-content/backup*"
```

### Default Exclusions
- `cache` - General cache directories
- `logs` - Log directories
- `tmp` - Temporary directories
- `uploads/cache` - WordPress upload cache
- `wp-content/cache` - WordPress cache
- `wp-content/updraft` - UpdraftPlus backups
- `wp-content/backup*` - General backup directories
- `wp-content/uploads/backup*` - Upload backup directories

### Customization
- Modify the list to suit your specific needs
- Supports wildcard patterns (e.g., `backup*`)
- Applies to all sites in the backup process
- Helps reduce backup size and avoid backing up temporary files

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

Use the built-in restore wizard for safe, automated restoration:

```bash
sudo /usr/local/bin/wordpress-tarsnap-backups.sh --restore
```

### Restore Process

1. **Site Selection**: Choose from available WordPress sites
2. **Backup Selection**: Browse backups with pagination (10 per page)
3. **Safety Confirmation**: Type 'RESTORE' to confirm the operation
4. **Optional Dry Run**: Test restore without making changes
5. **Automatic Backup**: Creates safety backup of existing site
6. **Atomic Restore**: Complete success or automatic rollback
7. **Validation**: Ensures WordPress installation is functional

### Safety Features

- **Pre-restore validation**: Checks disk space, database connectivity, and archive integrity
- **Automatic backup**: Creates timestamped backup of existing site and database
- **Atomic operations**: All changes staged before final deployment
- **Automatic rollback**: Restores from backup if any step fails
- **WordPress validation**: Verifies core files, structure, and configuration
- **Comprehensive logging**: Full audit trail with timestamps
- **Permission management**: Sets proper ownership and file permissions

### Restore Logs

Detailed logs are created at `/var/log/wordpress-tarsnap-backups/restore_<site>_<timestamp>.log` for troubleshooting and audit purposes.

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