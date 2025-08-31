#!/bin/bash

# WordPress Tarsnap Backups v1.1.0
# Automated backup solution for WordPress sites using Tarsnap
#
# Features:
# - Auto-discovery of WordPress installations
# - Three retention schemes: Simple, GFS, and Manual
# - External configuration file support
# - Comprehensive error handling and email notifications
#
# Requirements: tarsnap, mysqldump, mail (optional)
# License: MIT

# --- Configuration ---
# Default configuration values | Check the explanation of each parameter on the config file
SITES_ROOT="/var/www"
TEMP_BACKUP_DIR="/tmp"
TARSNAP_KEY_FILE="/root/tarsnap.key"
LOG_DIR="/var/log/wordpress-tarsnap-backups"
RETENTION_SCHEME="simple"
RETENTION_DAYS=31
MIN_BACKUPS_TO_KEEP=31
GFS_HOURLY_KEEP=24
GFS_DAILY_KEEP=7
GFS_WEEKLY_KEEP=4
GFS_MONTHLY_KEEP=12
GFS_YEARLY_KEEP=3
NOTIFY_EMAIL=""
EXCLUDED_SITES="22222 html"

# Load configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
    # No arguments: try /etc/ first, then same directory
    if [[ -f "/etc/wordpress-tarsnap-backups.conf" ]]; then
        CONFIG_FILE="/etc/wordpress-tarsnap-backups.conf"
    elif [[ -f "$SCRIPT_DIR/wordpress-tarsnap-backups.conf" ]]; then
        CONFIG_FILE="$SCRIPT_DIR/wordpress-tarsnap-backups.conf"
    else
        CONFIG_FILE=""
    fi
else
    # Argument provided: use it
    CONFIG_FILE="$1"
fi

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    # Validate config file permissions for security
    if [[ -r "$CONFIG_FILE" && ! -x "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        echo "Error: Configuration file '$CONFIG_FILE' has invalid permissions"
        exit 1
    fi
else
    echo "Warning: No configuration file found, using defaults"
fi

# Convert space-separated EXCLUDED_SITES to array
read -ra EXCLUDED_SITES_ARRAY <<< "$EXCLUDED_SITES"

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

# Validate retention configuration
if [[ "$RETENTION_SCHEME" == "gfs" ]]; then
    if (( GFS_HOURLY_KEEP < 1 || GFS_DAILY_KEEP < 1 || GFS_WEEKLY_KEEP < 1 || GFS_MONTHLY_KEEP < 1 || GFS_YEARLY_KEEP < 1 )); then
        log "ERROR" "MAIN" "Invalid GFS retention configuration: all values must be >= 1"
        exit 1
    fi
elif [[ "$RETENTION_SCHEME" == "simple" ]]; then
    if (( RETENTION_DAYS < 1 || MIN_BACKUPS_TO_KEEP < 1 )); then
        log "ERROR" "MAIN" "Invalid simple retention configuration: all values must be >= 1"
        exit 1
    fi
elif [[ "$RETENTION_SCHEME" == "manual" ]]; then
    log "WARNING" "MAIN" "Manual retention mode: No automatic cleanup will be performed"
else
    log "ERROR" "MAIN" "Invalid RETENTION_SCHEME: must be 'simple', 'gfs', or 'manual'"
    exit 1
fi

# Test Tarsnap connectivity
if ! tarsnap --list-archives &>/dev/null; then
    log "ERROR" "MAIN" "Cannot connect to Tarsnap - check key file and network connectivity"
    exit 1
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

# GFS Retention Function
apply_gfs_retention() {
    local site_name="$1"
    local safe_site_name="$2"
    
    mapfile -t all_archives < <(tarsnap --list-archives | grep "^${safe_site_name}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)
    
    local now_epoch=$(date +%s)
    local hourly_cutoff=$((now_epoch - GFS_HOURLY_KEEP * 3600))
    local daily_cutoff=$((now_epoch - GFS_DAILY_KEEP * 86400))
    local weekly_cutoff=$((now_epoch - GFS_WEEKLY_KEEP * 7 * 86400))
    local monthly_cutoff=$((now_epoch - GFS_MONTHLY_KEEP * 30 * 86400))
    local yearly_cutoff=$((now_epoch - GFS_YEARLY_KEEP * 365 * 86400))
    
    declare -A keep_archives
    
    for archive in "${all_archives[@]}"; do
        if [[ "$archive" =~ ^${safe_site_name}-([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6})$ ]]; then
            local archive_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            local archive_epoch=$(date -d "$archive_date" +%s 2>/dev/null) || continue
            local day_of_week=$(date -d "$archive_date" +%u)
            local day_of_month=$(date -d "$archive_date" +%d)
            local day_of_year=$(date -d "$archive_date" +%j)
            
            # Keep if within hourly retention
            if (( archive_epoch >= hourly_cutoff )); then
                keep_archives["$archive"]="hourly"
            # Keep if within daily retention
            elif (( archive_epoch >= daily_cutoff )); then
                keep_archives["$archive"]="daily"
            # Keep if weekly (Sunday) and within weekly retention
            elif (( day_of_week == 7 && archive_epoch >= weekly_cutoff )); then
                keep_archives["$archive"]="weekly"
            # Keep if monthly (1st of month) and within monthly retention
            elif (( day_of_month == 1 && archive_epoch >= monthly_cutoff )); then
                keep_archives["$archive"]="monthly"
            # Keep if yearly (1st of year) and within yearly retention
            elif (( day_of_year == 1 && archive_epoch >= yearly_cutoff )); then
                keep_archives["$archive"]="yearly"
            fi
        fi
    done
    
    # Delete archives not in keep list
    for archive in "${all_archives[@]}"; do
        if [[ -z "${keep_archives[$archive]:-}" ]]; then
            log "INFO" "$site_name" "Deleting archive (GFS): $archive"
            if ! tarsnap --quiet -d -f "$archive"; then
                log "WARNING" "$site_name" "Failed to delete archive $archive"
            fi
        else
            log "INFO" "$site_name" "Keeping (${keep_archives[$archive]}): $archive"
        fi
    done
}

log "INFO" "MAIN" "Starting WordPress site backups to Tarsnap"
log "INFO" "MAIN" "Configuration: SITES_ROOT=$SITES_ROOT, RETENTION_SCHEME=$RETENTION_SCHEME"

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
    for EXCLUDED_SITE in "${EXCLUDED_SITES_ARRAY[@]}"; do
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

        # --- Retention Policy ---
        if [[ "$RETENTION_SCHEME" == "gfs" ]]; then
            log "INFO" "$SITE_DIRNAME" "Applying GFS retention policy"
            apply_gfs_retention "$SITE_DIRNAME" "$SAFE_SITE_NAME"
        elif [[ "$RETENTION_SCHEME" == "simple" ]]; then
            log "INFO" "$SITE_DIRNAME" "Applying simple retention policy (${RETENTION_DAYS}d, min ${MIN_BACKUPS_TO_KEEP} backups)"
            mapfile -t all_archives < <(tarsnap --list-archives | grep "^${SAFE_SITE_NAME}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)
            
            for i in "${!all_archives[@]}"; do
                archive="${all_archives[i]}"
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
        else
            log "INFO" "$SITE_DIRNAME" "Manual retention mode: No automatic cleanup performed"
        fi
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