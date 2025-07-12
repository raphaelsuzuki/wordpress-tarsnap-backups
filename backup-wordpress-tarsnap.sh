#!/bin/bash

# WordOps Site Backup Script
# This script automates the backup of WordOps sites using Tarsnap.
# It creates a backup of the site files and database, excluding cache and backup directories.
# It is designed to be run as a cron job for daily backups.
#
# --- Cron Job Setup Instructions ---
#
# To automate this script to run daily, you can add it to the root user's crontab.
# This is recommended because the script needs permissions to:
#
# - Read /var/www directories and files
# - Run mysqldump
# - Access the Tarsnap key file (often owned by root and located in /root)
#
# 1. Open the root user's crontab for editing:
#    sudo crontab -e
#
# 2. Add the following line to the end of the file. This example runs the script daily at 3:00 AM.
#    Make sure to replace "/path/to/your/backup_wo_sites.sh" with the actual path to this script file.
#    The ">> /var/log/wo_backup.log 2>&1" part redirects all output (standard output and standard error)
#    to a log file, which is very useful for checking if the backup ran successfully or if there were errors.
#
#    0 3 * * * /bin/bash /path/to/your/backup_wo_sites.sh >> /var/log/wo_backup.log 2>&1
#
#    Explanation of the cron time fields (0 3 * * *):
#    - 0: Minute (00)
#    - 3: Hour (03:00 AM)
#    - *: Day of the month (every day)
#    - *: Month (every month)
#    - *: Day of the week (every day of the week)
#
# 3. Save and close the crontab file. Cron will automatically pick up the changes.
#
# 4. Ensure this script file has execute permissions:
#    chmod +x /path/to/your/backup_wo_sites.sh
#
# 5. Ensure your Tarsnap key file has appropriate permissions (usually 600 for the root user):
#    chmod 600 /path/to/tarsnap.key # (Adjust path if your key is elsewhere)
#
# You can check the log file (/var/log/wo_backup.log) after the scheduled time to verify the backup ran.
# --- End Cron Job Setup Instructions ---
#
# --- Restore Instructions ---
#
# To restore a backup created by this script using Tarsnap, follow these steps:
#
# 1. List all available Tarsnap archives to find the one you want to restore:
#    tarsnap --key-file /path/to/tarsnap.key --list-archives
#
# 2. Restore the desired archive to the WordOps sites directory (/var/www):
#    tarsnap --key-file /path/to/tarsnap.key -x -f <archive-name> -C /var/www
#    Replace <archive-name> with the name of the archive (e.g., site-2025-05-06-030000).
#
# 3. Locate the database dump file:
#    The database dump file will be extracted to the temporary backup directory (e.g., /tmp).
#    Look for a file named <site-name>_db_<timestamp>.sql in /tmp.
#
# 4. Restore the database from the dump file:
#    mysql -u <db_user> -p<db_password> <db_name> < /tmp/<site-name>_db_<timestamp>.sql
#    Replace <db_user>, <db_password>, and <db_name> with the appropriate database credentials.
#    Replace <site-name>_db_<timestamp>.sql with the name of the extracted SQL dump file.
#
# 5. Verify the restoration:
#    - Ensure the site files are restored to their original location in /var/www/<site-name>.
#    - Check the database to confirm the data is restored.
#    - Update file permissions and ownership if necessary:
#      chown -R www-data:www-data /var/www/<site-name>
#
# 6. Restart WordOps services:
#    Use the following command to restart all WordOps-related services:
#    wo stack restart
#
# Note: Always test the restoration process in a staging environment before applying it to production.
# --- End Restore Instructions ---
#
# --- Configuration ---
SITES_ROOT="/var/www"             # Root directory containing your WordOps sites
TEMP_BACKUP_DIR="/tmp"            # Temporary directory for database dumps
TARSNAP_KEY_FILE="/path/to/tarsnap.key" # Path to your Tarsnap key file
# --- End Configuration ---

# Set strict mode for error handling
set -euo pipefail

# Trap to clean up temporary files on exit or interruption
trap 'rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"' EXIT

# Function to extract value from wp-config.php
# $1: Path to wp-config.php
# $2: Define name (e.g., 'DB_NAME')
get_wp_config_value() {
    local wp_config_file="$1"
    local define_name="$2"
    # Use awk to find the line and extract the third field (the value) based on single quotes
    # Add ^ to grep pattern to match the start of the line, making it more robust against comments
    grep -E "^define\(['\"]${define_name}['\"]," "$wp_config_file" | awk -F "'" '{print $4}' | head -n 1
}

echo "Starting WordOps site backups to Tarsnap..."
echo "Timestamp: $(date)"
echo "--------------------------------------------------"

# Check if Tarsnap key file exists
if [ ! -f "$TARSNAP_KEY_FILE" ]; then
    echo "Error: Tarsnap key file not found at $TARSNAP_KEY_FILE."
    echo "Please ensure your key file exists and is accessible."
    exit 1
fi

# Check if SITES_ROOT exists
if [ ! -d "$SITES_ROOT" ]; then
    echo "Error: Sites root directory not found at $SITES_ROOT."
    exit 1
fi

# Check if TEMP_BACKUP_DIR exists
if [ ! -d "$TEMP_BACKUP_DIR" ]; then
    echo "Error: Temporary backup directory not found at $TEMP_BACKUP_DIR."
    exit 1
fi

# Find all potential site directories (assuming one level deep)
# Use find with maxdepth 1 to prevent recursing into subdirectories of sites
find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d | while read -r SITE_PATH; do
    SITE_DIRNAME=$(basename "$SITE_PATH")
    WP_CONFIG_PATH="${SITE_PATH}/wp-config.php"
    DATE=$(date +%Y-%m-%d-%H%M%S)
    TARSNAP_ARCHIVE_NAME="${SITE_DIRNAME}-${DATE}"
    DB_DUMP_FILE="${TEMP_BACKUP_DIR}/${SITE_DIRNAME}_db_${DATE}_$$.sql"

    echo "Processing site: $SITE_DIRNAME"

    # Check if wp-config.php exists
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        echo "  Skipping $SITE_DIRNAME: wp-config.php not found."
        continue # Move to the next directory
    fi

    echo "  Found wp-config.php. Extracting DB credentials..."

    # Extract database credentials
    DB_NAME=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_NAME')
    DB_USER=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_USER')
    DB_PASSWORD=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_PASSWORD')
    DB_HOST=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_HOST')

    # Simple check for empty credentials (improve as needed)
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "  Error: Could not extract all DB credentials for $SITE_DIRNAME from $WP_CONFIG_PATH."
        continue # Move to the next directory
    fi

    # Default DB_HOST if not specified or empty
    if [ -z "$DB_HOST" ]; then
        DB_HOST="localhost"
        echo "  Warning: DB_HOST not found or empty in wp-config.php. Assuming '$DB_HOST'."
    else
        echo "  DB_HOST: $DB_HOST"
    fi

    echo "  Dumping database '$DB_NAME'..."

    # Perform database dump using mysqldump
    # Use --defaults-extra-file for security (avoids password in command history/ps)
    # Create a temporary file descriptor with password
    MYSQL_CONN_OPTS=$(mktemp "/tmp/mysql_conn_opts_XXXXXX_$$")
    echo "[client]" > "$MYSQL_CONN_OPTS"
    echo "user=\"${DB_USER}\"" >> "$MYSQL_CONN_OPTS"
    echo "password=\"${DB_PASSWORD}\"" >> "$MYSQL_CONN_OPTS"
    echo "host=\"${DB_HOST}\"" >> "$MYSQL_CONN_OPTS"

    if ! mysqldump --defaults-extra-file="$MYSQL_CONN_OPTS" "$DB_NAME" > "$DB_DUMP_FILE" 2>> /var/log/wo_backup_errors.log; then
        echo "  Error: mysqldump failed for database '$DB_NAME' for site $SITE_DIRNAME. Check /var/log/wo_backup_errors.log for details."
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE" # Clean up temp files
        continue # Move to the next directory
    fi

    rm -f "$MYSQL_CONN_OPTS" # Clean up temporary credentials file

    echo "  Database dump created: $DB_DUMP_FILE"
    echo "  Starting Tarsnap backup..."
    echo "  Excluding wp-content/cache/ and wp-content/updraft/ directories..."

    # Perform Tarsnap backup
    # Backs up the entire site directory and the database dump file, excluding specified directories
    # The --exclude paths are relative to the paths being backed up ($SITE_PATH)
    TARSNAP_EXCLUDES=("--exclude=wp-content/cache" "--exclude=wp-content/updraft")
    if tarsnap \
        --key-file "$TARSNAP_KEY_FILE" \
        -c -f "$TARSNAP_ARCHIVE_NAME" \
        "${TARSNAP_EXCLUDES[@]}" \
        "$SITE_PATH" \
        "$DB_DUMP_FILE"; then
        echo "  Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME"
    else
        echo "  Error: Tarsnap backup failed for site $SITE_DIRNAME. Check Tarsnap logs for details."
    fi

    # Clean up the temporary database dump file
    echo "  Cleaning up temporary database dump file..."
    rm -f "$DB_DUMP_FILE"

    echo "--------------------"

done

echo "--------------------------------------------------"
echo "WordOps site backups finished."
echo "Timestamp: $(date)"
