#!/bin/bash

# WordPress Tarsnap Backups
# This script automates the backup of WordPress sites using Tarsnap.
# It creates a backup of the site files and database, excluding cache and backup directories.
# It is designed to be run as a cron job for daily backups.
# Initially desiged for WordOps, it can be adapted for other environments with minor changes.

# --- Configuration ---
SITES_ROOT="/var/www"                  # Root directory containing your WordPress sites, adjust accordingly

# WARNING: /tmp can be a small RAM-based filesystem (tmpfs). If you have large
# databases, consider changing this to a directory on a larger disk partition, like "/var/tmp".
TEMP_BACKUP_DIR="/tmp"                 # Temporary directory for database dumps

TARSNAP_KEY_FILE="/path/to/tarsnap.key" # Path to your Tarsnap key file

# Add site directory names here to exclude them from the backup process.
# For example: EXCLUDED_SITES=("example.com.bak" "dev.example.com")
EXCLUDED_SITES=(
    "22222"
    "html"
    # "example.com"
    # "staging.example.com"
    # "testsite.com"
)
RETENTION_DAYS=31          # Number of days to keep backups
MIN_BACKUPS_TO_KEEP=31     # Minimum number of backups to always keep per site
# --- End Configuration ---

# Set strict mode for error handling
set -euo pipefail

# Trap to clean up temporary files on exit or interruption
DB_DUMP_FILE=""
MYSQL_CONN_OPTS=""
TEMP_FILES=()
cleanup() {
    local file
    for file in "${TEMP_FILES[@]}" "$DB_DUMP_FILE" "$MYSQL_CONN_OPTS"; do
        [[ -n "$file" && -f "$file" ]] && rm -f "$file"
    done
}
trap cleanup EXIT INT TERM

# --- Pre-flight Checks ---
# Check for required command-line tools before starting
REQUIRED_COMMANDS=("tarsnap" "mysqldump" "grep" "sed" "tr" "mktemp" "date")
for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" &> /dev/null; then
        echo "Error: Required command '$CMD' is not installed or not in your PATH."
        exit 1
    fi
done

# Check available disk space (require at least 1GB free)
if ! df "$TEMP_BACKUP_DIR" | awk 'NR==2 {exit ($4 < 1048576)}'; then
    echo "Warning: Less than 1GB free space in $TEMP_BACKUP_DIR"
fi
# --- End Pre-flight Checks ---

# Function to safely extract values from wp-config.php
# $1: Path to wp-config.php
# $2: Define name (e.g., 'DB_NAME')
get_wp_config_value() {
    local wp_config_file="$1"
    local define_name="$2"
    # Use safer regex without catastrophic backtracking
    local value
    value=$(grep -E "define\([[:space:]]*['\"]${define_name}['\"][[:space:]]*,[[:space:]]*['\"]" "$wp_config_file" | 
           sed -n "s/.*define([[:space:]]*['\"]${define_name}['\"][[:space:]]*,[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" | 
           head -n 1)
    # Sanitize output - remove any shell metacharacters
    printf '%s' "$value" | tr -d '`$(){}[]|&;<>'
}

echo "Starting WordPress site backups to Tarsnap..."
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
for SITE_PATH in "$SITES_ROOT"/*/; do
    [[ -d "$SITE_PATH" ]] || continue
    SITE_DIRNAME=$(basename "$SITE_PATH")
    WP_CONFIG_PATH="${SITE_PATH}/wp-config.php"

    # Check if the site is in the exclusion list
    EXCLUDED=false
    for EXCLUDED_SITE in "${EXCLUDED_SITES[@]}"; do
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

    # Extract and validate database credentials
    DB_NAME=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_NAME')
    DB_USER=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_USER')
    DB_PASSWORD=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_PASSWORD')
    DB_HOST=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_HOST')

    # Validate extracted credentials
    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
        echo "  Error: Could not extract all required DB credentials for $SITE_DIRNAME."
        continue
    fi
    
    # Validate credential format (basic sanity check)
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$DB_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "  Error: Invalid database name or user format for $SITE_DIRNAME."
        continue
    fi

    DB_HOST=${DB_HOST:-localhost}

    echo "  Dumping database '$DB_NAME'..."

    # Create secure temporary files
    DATE=$(date +%Y-%m-%d-%H%M%S)
    # Sanitize site dirname for filename
    SAFE_SITE_NAME=$(printf '%s' "$SITE_DIRNAME" | tr -cd '[:alnum:]._-')
    DB_DUMP_FILE=$(mktemp "${TEMP_BACKUP_DIR}/${SAFE_SITE_NAME}_db_${DATE}_XXXXXX.sql")
    MYSQL_CONN_OPTS=$(mktemp "${TEMP_BACKUP_DIR}/mysql_conn_XXXXXX")
    TEMP_FILES+=("$DB_DUMP_FILE" "$MYSQL_CONN_OPTS")
    
    # Set secure permissions on temp files
    chmod 600 "$DB_DUMP_FILE" "$MYSQL_CONN_OPTS"

    # Securely write credentials to the temporary options file
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$DB_PASSWORD"
        printf 'host=%s\n' "$DB_HOST"
    } > "$MYSQL_CONN_OPTS"

    # Perform database dump with timeout protection
    if ! timeout 3600 mysqldump --defaults-extra-file="$MYSQL_CONN_OPTS" --single-transaction --routines --triggers "$DB_NAME" > "$DB_DUMP_FILE"; then
        echo "  Error: mysqldump failed for database '$DB_NAME'. Check the log for details."
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi

    # Verify dump file is not empty
    if [[ ! -s "$DB_DUMP_FILE" ]]; then
        echo "  Error: Database dump is empty for $DB_NAME"
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi

    rm -f "$MYSQL_CONN_OPTS"
    MYSQL_CONN_OPTS=""

    echo "  Database dump created: $DB_DUMP_FILE"
    echo "  Starting Tarsnap backup..."
    echo "  Excluding wp-content/cache/ and wp-content/updraft/ directories..."

    # Create safe archive name
    TARSNAP_ARCHIVE_NAME="${SAFE_SITE_NAME}-${DATE}"
    TARSNAP_EXCLUDES=("--exclude=wp-content/cache" "--exclude=wp-content/updraft" "--exclude=wp-content/backup*")
    
    # Perform Tarsnap backup
    if tarsnap \
        --key-file "$TARSNAP_KEY_FILE" \
        -c -f "$TARSNAP_ARCHIVE_NAME" \
        "${TARSNAP_EXCLUDES[@]}" \
        "$SITE_PATH" \
        "$DB_DUMP_FILE"; then
        echo "  Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME"

        # --- Retention Policy: Safe per-site deletion ---
        echo "  Applying retention policy: keeping last $RETENTION_DAYS days and at least $MIN_BACKUPS_TO_KEEP backups..."

        # List all archives for this site, sorted newest first
        mapfile -t all_archives < <(tarsnap --key-file "$TARSNAP_KEY_FILE" --list-archives | grep "^${SAFE_SITE_NAME}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)

        for i in "${!all_archives[@]}"; do
            archive="${all_archives[i]}"
            # Extract date part from archive name
            if [[ "$archive" =~ ^${SAFE_SITE_NAME}-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6})$ ]]; then
                archive_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
                if archive_epoch=$(date -d "$archive_date" +%s 2>/dev/null) && 
                   cutoff_epoch=$(date -d "-$RETENTION_DAYS days" +%s 2>/dev/null); then
                    if (( archive_epoch < cutoff_epoch )); then
                        if (( i >= MIN_BACKUPS_TO_KEEP )); then
                            echo "    Deleting old archive: $archive"
                            if ! tarsnap --key-file "$TARSNAP_KEY_FILE" -d -f "$archive"; then
                                echo "    Warning: Failed to delete archive $archive"
                            fi
                        else
                            echo "    Keeping (minimum required): $archive"
                        fi
                    else
                        echo "    Keeping (within retention): $archive"
                    fi
                else
                    echo "    Skipping archive with invalid date: $archive"
                fi
            else
                echo "    Skipping unparseable archive: $archive"
            fi
        done
        # --- End Retention Policy ---

    else
        echo "  Error: Tarsnap backup failed for site $SITE_DIRNAME. Check the log for details."
    fi

    echo "  Cleaning up temporary database dump file..."
    rm -f "$DB_DUMP_FILE"
    DB_DUMP_FILE="" # Clear variable

    echo "--------------------"

done

echo "--------------------------------------------------"
echo "WordPress sites backup completed at $(date)"