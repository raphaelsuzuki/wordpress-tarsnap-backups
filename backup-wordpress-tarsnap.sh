#!/bin/bash

# WordPress Tarsnap Backups
# This script automates the backup of WordPress sites using Tarsnap.
# It creates a backup of the site files and database, excluding cache and backup directories.
# It is designed to be run as a cron job for daily backups.
# Initially designed for WordOps, it can be adapted for other environments with minor changes.

# --- Configuration ---
SITES_ROOT="/var/www"                  # Root directory containing your WordPress sites, adjust accordingly
TEMP_BACKUP_DIR="/tmp"                 # Temporary directory for database dumps | WARNING: /tmp can be a small RAM-based filesystem (tmpfs). If you have large databases, consider changing this to a directory on a larger disk partition, like "/var/tmp".
TARSNAP_KEY_FILE="/root/tarsnap.key"   # Path to your Tarsnap key file | This is the default path from the official documentation
LOG_DIR="/var/log/wordpress-tarsnap-backups"   # Directory for log files
RETENTION_DAYS=31          # Number of days to keep backups per site
MIN_BACKUPS_TO_KEEP=31     # Minimum number of backups to always keep per site |  Even if you stop using Tarsnap, this number of backups will be kept
NOTIFY_EMAIL=""            # Email address for notifications (leave empty to disable)

# Add site directory names here to exclude them from the backup process.
# For example: EXCLUDED_SITES=("example.com.bak" "dev.example.com")
EXCLUDED_SITES=(
    "22222"
    "html"
    # "example.com"
    # "staging.example.com"
    # "testsite.com"
)

# Set strict mode for error handling
set -euo pipefail

# Set Tarsnap key file environment variable
export TARSNAP_KEYFILE="$TARSNAP_KEY_FILE"

# Track errors for notification
ERROR_COUNT=0
ERROR_SITES=()

# --- Logging Setup ---
# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/backup.log"

# Logging function
log() {
    local level="$1"
    local site="${2:-MAIN}"
    shift 2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$timestamp] $level: $*"
    
    # Write to main log and per-site log
    echo "$msg" >> "$MAIN_LOG"
    if [[ "$site" != "MAIN" ]]; then
        echo "$msg" >> "$LOG_DIR/${site}.log"
    fi
    
    # Also output to console for cron log
    echo "$msg"
}

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
        log "ERROR" "MAIN" "Required command '$CMD' is not installed or not in your PATH"
        exit 1
    fi
done

# Check available disk space (require at least 1GB free)
if ! df "$TEMP_BACKUP_DIR" | awk 'NR==2 {exit ($4 < 1048576)}'; then
    log "WARNING" "MAIN" "Less than 1GB free space in $TEMP_BACKUP_DIR"
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

log "INFO" "MAIN" "Starting WordPress site backups to Tarsnap"
log "INFO" "MAIN" "Configuration: SITES_ROOT=$SITES_ROOT, RETENTION_DAYS=$RETENTION_DAYS"

# Check if essential paths exist
if [ ! -f "$TARSNAP_KEY_FILE" ]; then
    log "ERROR" "MAIN" "Tarsnap key file not found at $TARSNAP_KEY_FILE"
    exit 1
fi
if [ ! -d "$SITES_ROOT" ]; then
    log "ERROR" "MAIN" "Sites root directory not found at $SITES_ROOT"
    exit 1
fi
if [ ! -d "$TEMP_BACKUP_DIR" ]; then
    log "ERROR" "MAIN" "Temporary backup directory not found at $TEMP_BACKUP_DIR"
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
            log "INFO" "MAIN" "Skipping excluded site: $SITE_DIRNAME"
            EXCLUDED=true
            break
        fi
    done
    [[ "$EXCLUDED" == true ]] && continue

    log "INFO" "$SITE_DIRNAME" "Starting backup process"

    # Check if wp-config.php exists
    if [ ! -f "$WP_CONFIG_PATH" ]; then
        log "WARNING" "$SITE_DIRNAME" "wp-config.php not found, skipping site"
        continue
    fi

    log "INFO" "$SITE_DIRNAME" "Found wp-config.php, extracting database credentials"

    # Extract and validate database credentials
    DB_NAME=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_NAME')
    DB_USER=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_USER')
    DB_PASSWORD=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_PASSWORD')
    DB_HOST=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_HOST')

    # Validate extracted credentials
    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
        log "ERROR" "$SITE_DIRNAME" "Could not extract all required database credentials"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: DB credentials")
        continue
    fi
    
    # Validate credential format (basic sanity check)
    if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! "$DB_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "$SITE_DIRNAME" "Invalid database name or user format"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Invalid DB format")
        continue
    fi

    DB_HOST=${DB_HOST:-localhost}

    log "INFO" "$SITE_DIRNAME" "Starting database dump for '$DB_NAME'"

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
        log "ERROR" "$SITE_DIRNAME" "mysqldump failed for database '$DB_NAME'"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: mysqldump failed")
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi

    # Verify dump file is not empty
    if [[ ! -s "$DB_DUMP_FILE" ]]; then
        log "ERROR" "$SITE_DIRNAME" "Database dump is empty for $DB_NAME"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Empty DB dump")
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi

    rm -f "$MYSQL_CONN_OPTS"
    MYSQL_CONN_OPTS=""

    log "INFO" "$SITE_DIRNAME" "Database dump created: $(basename "$DB_DUMP_FILE")"
    log "INFO" "$SITE_DIRNAME" "Starting Tarsnap backup (excluding cache/backup directories)"

    # Create safe archive name
    TARSNAP_ARCHIVE_NAME="${SAFE_SITE_NAME}-${DATE}"
    TARSNAP_EXCLUDES=("--exclude=*/wp-content/cache" "--exclude=*/wp-content/updraft" "--exclude=*/wp-content/backup*" "--exclude=*/wp-content/uploads/backup*")
    
    # Perform Tarsnap backup
    if tarsnap \
        --quiet \
        -c -f "$TARSNAP_ARCHIVE_NAME" \
        "${TARSNAP_EXCLUDES[@]}" \
        "$SITE_PATH" \
        "$DB_DUMP_FILE"; then
        log "INFO" "$SITE_DIRNAME" "Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME"

        # --- Retention Policy: Safe per-site deletion ---
        log "INFO" "$SITE_DIRNAME" "Applying retention policy (${RETENTION_DAYS}d, min ${MIN_BACKUPS_TO_KEEP} backups)"

        # List all archives for this site, sorted newest first
        mapfile -t all_archives < <(tarsnap --list-archives | grep "^${SAFE_SITE_NAME}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)

        for i in "${!all_archives[@]}"; do
            archive="${all_archives[i]}"
            # Extract date part from archive name
            if [[ "$archive" =~ ^${SAFE_SITE_NAME}-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6})$ ]]; then
                archive_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
                if archive_epoch=$(date -d "$archive_date" +%s 2>/dev/null) && 
                   cutoff_epoch=$(date -d "-$RETENTION_DAYS days" +%s 2>/dev/null); then
                    if (( archive_epoch < cutoff_epoch )); then
                        if (( i >= MIN_BACKUPS_TO_KEEP )); then
                            log "INFO" "$SITE_DIRNAME" "Deleting old archive: $archive"
                            if ! tarsnap --quiet -d -f "$archive"; then
                                log "WARNING" "$SITE_DIRNAME" "Failed to delete archive $archive"
                            fi
                        else
                            log "INFO" "$SITE_DIRNAME" "Keeping (minimum required): $archive"
                        fi
                    else
                        log "INFO" "$SITE_DIRNAME" "Keeping (within retention): $archive"
                    fi
                else
                    log "WARNING" "$SITE_DIRNAME" "Skipping archive with invalid date: $archive"
                fi
            else
                log "WARNING" "$SITE_DIRNAME" "Skipping unparseable archive: $archive"
            fi
        done
        # --- End Retention Policy ---

    else
        log "ERROR" "$SITE_DIRNAME" "Tarsnap backup failed"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Tarsnap backup failed")
    fi

    log "INFO" "$SITE_DIRNAME" "Cleaning up temporary files"
    rm -f "$DB_DUMP_FILE"
    DB_DUMP_FILE=""

done

log "INFO" "MAIN" "WordPress backup process completed"

# Send email notification if configured
if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &> /dev/null; then
    HOSTNAME=$(hostname)
    DATE=$(date '+%Y-%m-%d %H:%M:%S')
    if (( ERROR_COUNT > 0 )); then
        {
            echo "WordPress Tarsnap backup completed on $HOSTNAME at $DATE with $ERROR_COUNT error(s):"
            echo
            printf '%s\n' "${ERROR_SITES[@]}"
        } | mail -s "WordPress Backup ERRORS - $HOSTNAME" "$NOTIFY_EMAIL"
    else
        echo "WordPress Tarsnap backup process completed successfully on $HOSTNAME at $DATE" | mail -s "WordPress Backup Complete - $HOSTNAME" "$NOTIFY_EMAIL"
    fi
fi