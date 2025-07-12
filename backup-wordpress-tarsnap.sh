#!/bin/bash

# WordOps Site Backup Script (Revised for Robustness)
# This script automates the backup of WordOps sites using Tarsnap.
# It creates a backup of the site files and database, excluding cache and backup directories.
# It is designed to be run as a cron job for daily backups.
#
# --- Cron Job Setup Instructions ---
#
# To automate this script to run daily, add it to the root user's crontab.
# This is recommended because the script needs permissions to:
#
# - Read /var/www directories and files
# - Run mysqldump
# - Access the Tarsnap key file (often owned by root)
#
# 1. Open the root user's crontab for editing:
#    sudo crontab -e
#
# 2. Add the following line to the end of the file. This example runs the script daily at 3:00 AM.
#    Replace "/path/to/your/backup_wo_sites.sh" with the actual path to this script file.
#    The ">> /var/log/wo_backup.log 2>&1" part redirects all output (standard output and standard error)
#    to a single log file, which is crucial for checking for success or errors.
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
#    chmod 600 /path/to/tarsnap.key
#
# --- Restore Instructions ---
#
# To restore a backup created by this script using Tarsnap, follow these steps:
#
# 1. List all available Tarsnap archives to find the one you want to restore:
#    tarsnap --key-file /path/to/tarsnap.key --list-archives
#
# 2. Restore the desired archive. This will restore site files and the temporary DB dump:
#    tarsnap --key-file /path/to/tarsnap.key -x -f <archive-name> -C /
#    (Replace <archive-name> with the name of the archive, e.g., site-2025-05-31-030000)
#
# 3. Locate the database dump file in the temporary directory specified in the configuration below.
#
# 4. Restore the database from the dump file:
#    mysql -u <db_user> -p<db_password> <db_name> < /path/to/temp/dir/site-name_db_timestamp.sql
#
# 5. Verify the restoration by checking site files and database content.
#    Then, fix file ownership and permissions:
#    chown -R www-data:www-data /var/www/<site-name>
#
# 6. Restart WordOps services:
#    wo stack restart
#
# Note: Always test the restoration process in a staging environment first.

# --- Configuration ---
SITES_ROOT="/var/www"                  # Root directory containing your WordOps sites

# WARNING: /tmp can be a small RAM-based filesystem (tmpfs). If you have large
# databases, consider changing this to a directory on a larger disk partition, like "/var/tmp".
TEMP_BACKUP_DIR="/tmp"                 # Temporary directory for database dumps

TARSNAP_KEY_FILE="/path/to/tarsnap.key" # Path to your Tarsnap key file

# Add site directory names here to exclude them from the backup process.
# For example: EXCLUDE_SITES=("example.com.bak" "dev.example.com")
EXCLUDE_SITES=()
# --- End Configuration ---

# Set strict mode for error handling
set -euo pipefail

# Trap to clean up temporary files on exit or interruption.
# Initialize with a default value to avoid unbound variable error if script exits early.
DB_DUMP_FILE=""
MYSQL_CONN_OPTS=""
trap 'rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"' EXIT

# --- Pre-flight Checks ---
# Check for required command-line tools before starting.
REQUIRED_COMMANDS=("tarsnap" "mysqldump" "grep")
for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" &> /dev/null; then
        echo "Error: Required command '$CMD' is not installed or not in your PATH."
        exit 1
    fi
done

# Check if grep supports Perl-compatible regular expressions (-P), which is needed for robust parsing.
if ! grep -P "a" <<< "a" &> /dev/null; then
    echo "Error: This script requires a version of grep that supports PCRE (-P option)."
    exit 1
fi
# --- End Pre-flight Checks ---

# Function to robustly extract values from wp-config.php
# Handles single quotes, double quotes, and escaped characters in values.
# $1: Path to wp-config.php
# $2: Define name (e.g., 'DB_NAME')
get_wp_config_value() {
    local wp_config_file="$1"
    local define_name="$2"
    # This powerful regex looks for the define name, then captures whatever is inside
    # the next set of single or double quotes, correctly handling escaped quotes.
    grep -P "define\(\s*['\"]${define_name}['\"]\s*,\s*['\"]\K[^'\"]*(?:\\.[^'\"]*)*" "$wp_config_file" | head -n 1
}

echo "Starting WordOps site backups to Tarsnap..."
echo "Timestamp: $(date)"
echo "--------------------------------------------------"

# Check if essential paths exist
if [ ! -f "$TARSNAP_KEY_FILE" ]; then
    echo "Error: Tarsnap key file not found at $TARSNAP_KEY_FILE."
    exit 1
fi
if [ ! -d "$SITES_ROOT" ]; then
    echo "Error: Sites root directory not found at $SITES_ROOT."
    exit 1
fi
if [ ! -d "$TEMP_BACKUP_DIR" ]; then
    echo "Error: Temporary backup directory not found at $TEMP_BACKUP_DIR."
    exit 1
fi

# Find all potential site directories (one level deep)
find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d | while read -r SITE_PATH; do
    SITE_DIRNAME=$(basename "$SITE_PATH")
    WP_CONFIG_PATH="${SITE_PATH}/wp-config.php"

    # Check if the site is in the exclusion list
    EXCLUDED=false
    for EXCLUDED_SITE in "${EXCLUDE_SITES[@]}"; do
        if [[ "$SITE_DIRNAME" == "$EXCLUDED_SITE" ]]; then
            echo "Skipping excluded site: $SITE_DIRNAME"
            EXCLUDED=true
            break
        fi
    done
    [[ "$EXCLUDED" == true ]] && continue

    echo "Processing site: $SITE_DIRNAME"

    # Check if wp-config.php exists
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        echo "  Skipping: wp-config.php not found."
        continue
    fi

    echo "  Found wp-config.php. Extracting DB credentials..."

    # Extract database credentials using the robust function
    DB_NAME=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_NAME')
    DB_USER=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_USER')
    DB_PASSWORD=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_PASSWORD')
    DB_HOST=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_HOST')

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "  Error: Could not extract all required DB credentials for $SITE_DIRNAME."
        continue
    fi

    DB_HOST=${DB_HOST:-localhost} # Default DB_HOST to "localhost" if it's empty or not found

    echo "  Dumping database '$DB_NAME'..."

    # Create temporary files for the DB dump and connection options
    DATE=$(date +%Y-%m-%d-%H%M%S)
    DB_DUMP_FILE="${TEMP_BACKUP_DIR}/${SITE_DIRNAME}_db_${DATE}_$$.sql"
    MYSQL_CONN_OPTS=$(mktemp "${TEMP_BACKUP_DIR}/mysql_conn_opts_XXXXXX_$$")

    # Securely write credentials to the temporary options file
    {
        echo "[client]"
        echo "user=\"${DB_USER}\""
        echo "password=\"${DB_PASSWORD}\""
        echo "host=\"${DB_HOST}\""
    } > "$MYSQL_CONN_OPTS"

    # Perform database dump. Errors will now go to the main cron log.
    if ! mysqldump --defaults-extra-file="$MYSQL_CONN_OPTS" "$DB_NAME" > "$DB_DUMP_FILE"; then
        echo "  Error: mysqldump failed for database '$DB_NAME'. Check the log for the specific error from mysqldump."
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE" # Clean up temp files
        continue
    fi

    rm -f "$MYSQL_CONN_OPTS" # Clean up temporary credentials file immediately after use
    MYSQL_CONN_OPTS="" # Clear variable

    echo "  Database dump created: $DB_DUMP_FILE"
    echo "  Starting Tarsnap backup..."
    echo "  Excluding wp-content/cache/ and wp-content/updraft/ directories..."

    TARSNAP_ARCHIVE_NAME="${SITE_DIRNAME}-${DATE}"
    TARSNAP_EXCLUDES=("--exclude=wp-content/cache" "--exclude=wp-content/updraft")
    
    # Perform Tarsnap backup
    if tarsnap \
        --key-file "$TARSNAP_KEY_FILE" \
        -c -f "$TARSNAP_ARCHIVE_NAME" \
        "${TARSNAP_EXCLUDES[@]}" \
        "$SITE_PATH" \
        "$DB_DUMP_FILE"; then
        echo "  Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME"
    else
        echo "  Error: Tarsnap backup failed for site $SITE_DIRNAME. Check the log for details."
    fi

    echo "  Cleaning up temporary database dump file..."
    rm -f "$DB_DUMP_FILE"
    DB_DUMP_FILE="" # Clear variable

    echo "--------------------"

done

echo "--------------------------------------------------"
echo "WordOps site backups finished."
echo "Timestamp: $(date)"

# --- Backup Rotation Logic (tsar-style) ---
# Configuration: adjust as needed
TARSNAP_ROTATE_KEY="$TARSNAP_KEY_FILE"  # Use the same key as for backup
DAILY_KEEP=30   # Number of daily backups to keep
WEEKLY_KEEP=12  # Number of weekly backups to keep
MONTHLY_KEEP=48 # Number of monthly backups to keep
DOW=1           # Day of week for weekly (1=Monday)
DOM=1           # Day of month for monthly

# List all tarsnap archives
ARCHIVE_LIST=$(tarsnap --key-file "$TARSNAP_ROTATE_KEY" --list-archives 2>/dev/null)

# Parse archive names and dates (expecting format: site-YYYY-MM-DD-HHMMSS)
declare -A ARCHIVE_DATES
for ARCHIVE in $ARCHIVE_LIST; do
    # Extract date from archive name
    if [[ $ARCHIVE =~ (.+)-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})$ ]]; then
        ARCHIVE_DATES[$ARCHIVE]="${BASH_REMATCH[2]}"
    fi
    # else: skip archives not matching naming pattern
done

# Build a list of archives to keep
KEEP_ARCHIVES=()
NOW=$(date +%s)

# Helper: convert date string to unix timestamp
archive_to_unix() {
    date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s
}

# Daily: keep most recent N
for SITE in $(ls "$SITES_ROOT"); do
    SITE_ARCHIVES=()
    for ARCHIVE in "${!ARCHIVE_DATES[@]}"; do
        if [[ $ARCHIVE == $SITE-* ]]; then
            SITE_ARCHIVES+=("$ARCHIVE")
        fi
    done
    # Sort by date descending
    IFS=$'\n' SORTED=($(for A in "${SITE_ARCHIVES[@]}"; do echo "$A"; done | sort -r -t'-' -k2,2 -k3,3 -k4,4))
    for ((i=0; i<${#SORTED[@]} && i<DAILY_KEEP; i++)); do
        KEEP_ARCHIVES+=("${SORTED[$i]}")
    done

done

# Weekly: keep the most recent backup for each week (on DOW), up to limit
for SITE in $(ls "$SITES_ROOT"); do
    WEEKLY_FOUND=0
    for ARCHIVE in "${!ARCHIVE_DATES[@]}"; do
        if [[ $ARCHIVE == $SITE-* ]]; then
            DATESTR="${ARCHIVE_DATES[$ARCHIVE]}"
            ARCHIVE_DATE="${DATESTR:0:10}"
            DOW_ARCHIVE=$(date -d "$ARCHIVE_DATE" +%u)
            if [[ $DOW_ARCHIVE -eq $DOW ]]; then
                KEEP_ARCHIVES+=("$ARCHIVE")
                ((WEEKLY_FOUND++))
                if [[ $WEEKLY_FOUND -ge $WEEKLY_KEEP ]]; then break; fi
            fi
        fi
    done
done

# Monthly: keep the most recent backup for each month (on DOM), up to limit
for SITE in $(ls "$SITES_ROOT"); do
    MONTHLY_FOUND=0
    for ARCHIVE in "${!ARCHIVE_DATES[@]}"; do
        if [[ $ARCHIVE == $SITE-* ]]; then
            DATESTR="${ARCHIVE_DATES[$ARCHIVE]}"
            ARCHIVE_DATE="${DATESTR:0:10}"
            DOM_ARCHIVE=$(date -d "$ARCHIVE_DATE" +%d)
            if [[ $DOM_ARCHIVE -eq $DOM ]]; then
                KEEP_ARCHIVES+=("$ARCHIVE")
                ((MONTHLY_FOUND++))
                if [[ $MONTHLY_FOUND -ge $MONTHLY_KEEP ]]; then break; fi
            fi
        fi
    done
done

# Remove duplicates from KEEP_ARCHIVES
KEEP_ARCHIVES=($(printf "%s\n" "${KEEP_ARCHIVES[@]}" | sort -u))

# Find archives to delete
DELETE_ARCHIVES=()
for ARCHIVE in "${!ARCHIVE_DATES[@]}"; do
    SKIP=0
    for KEEP in "${KEEP_ARCHIVES[@]}"; do
        if [[ "$ARCHIVE" == "$KEEP" ]]; then SKIP=1; break; fi
    done
    if [[ $SKIP -eq 0 ]]; then
        DELETE_ARCHIVES+=("$ARCHIVE")
    fi
done

# Delete old archives
for ARCHIVE in "${DELETE_ARCHIVES[@]}"; do
    echo "Deleting old archive: $ARCHIVE"
    tarsnap --key-file "$TARSNAP_ROTATE_KEY" -d -f "$ARCHIVE"
done