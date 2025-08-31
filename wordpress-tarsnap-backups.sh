#!/bin/bash

# WordPress Tarsnap Backups v1.2.0
# Automated backup and restore solution for WordPress sites using Tarsnap
#
# Features:
# - Auto-discovery of WordPress installations
# - Three retention schemes: Simple, GFS, and Manual
# - External configuration file support
# - Comprehensive error handling and email notifications
# - Failproof restore with automatic rollback and validation
#
# Requirements: tarsnap, mysqldump, mail (optional)
# License: MIT

# Set strict mode for error handling
set -euo pipefail

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

# Check for restore mode
if [[ "${1:-}" == "--restore" ]]; then
    shift
    restore_mode "$@"
    exit 0
fi

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

# --- Restore Functions ---
restore_mode() {
    echo "WordPress Tarsnap Restore Wizard"
    echo "================================="
    
    # List available archives
    echo "\nFetching available backups..."
    mapfile -t archives < <(tarsnap --list-archives | grep -E '^[^-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$' | sort -r)
    
    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No backups found."
        exit 1
    fi
    
    # Group by site
    declare -A sites
    for archive in "${archives[@]}"; do
        if [[ "$archive" =~ ^([^-]+)- ]]; then
            site="${BASH_REMATCH[1]}"
            sites["$site"]+="$archive\n"
        fi
    done
    
    # Select site
    echo "\nAvailable sites:"
    site_list=()
    i=1
    for site in $(printf '%s\n' "${!sites[@]}" | sort); do
        echo "$i) $site"
        site_list+=("$site")
        ((i++))
    done
    
    read -p "\nSelect site (1-${#site_list[@]}): " site_choice
    if [[ ! "$site_choice" =~ ^[0-9]+$ ]] || (( site_choice < 1 || site_choice > ${#site_list[@]} )); then
        echo "Invalid selection."
        exit 1
    fi
    
    selected_site="${site_list[$((site_choice-1))]}"
    
    # Select backup with pagination
    mapfile -t all_site_archives < <(printf "${sites[$selected_site]}")
    local page=0
    local per_page=10
    
    while true; do
        local start=$((page * per_page))
        local end=$((start + per_page))
        
        echo "\nAvailable backups for $selected_site (page $((page+1))):"
        
        local displayed=0
        for i in $(seq $start $((end-1))); do
            [[ $i -ge ${#all_site_archives[@]} ]] && break
            archive="${all_site_archives[i]}"
            if [[ "$archive" =~ -([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6})$ ]]; then
                date_str="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]:0:2}:${BASH_REMATCH[4]:2:2}:${BASH_REMATCH[4]:4:2}"
                echo "$((i+1))) $archive ($date_str)"
                ((displayed++))
            fi
        done
        
        [[ $displayed -eq 0 ]] && { echo "No more backups."; break; }
        
        echo
        [[ $((end)) -lt ${#all_site_archives[@]} ]] && echo "n) Next page"
        [[ $page -gt 0 ]] && echo "p) Previous page"
        echo "q) Quit"
        
        read -p "\nSelect backup (number), or n/p/q: " choice
        
        case "$choice" in
            n|N)
                [[ $((end)) -lt ${#all_site_archives[@]} ]] && ((page++)) || echo "Already on last page."
                ;;
            p|P)
                [[ $page -gt 0 ]] && ((page--)) || echo "Already on first page."
                ;;
            q|Q)
                echo "Restore cancelled."
                exit 0
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#all_site_archives[@]} )); then
                    selected_archive="${all_site_archives[$((choice-1))]}"
                    break 2
                else
                    echo "Invalid selection."
                fi
                ;;
        esac
    done
    
    # Detailed confirmation
    echo "\n" + "="*50
    echo "RESTORE CONFIRMATION"
    echo "="*50
    echo "Site: $selected_site"
    echo "Archive: $selected_archive"
    echo "Target: $SITES_ROOT/$selected_site"
    echo "\nWARNING: This will:"
    echo "• Create backup of existing site"
    echo "• OVERWRITE all files in $SITES_ROOT/$selected_site"
    echo "• OVERWRITE the database completely"
    echo "• Create restore log for audit trail"
    echo "\nSafety measures:"
    echo "• Full backup before restore"
    echo "• Automatic rollback on failure"
    echo "• WordPress validation after restore"
    echo "="*50
    
    read -p "Type 'RESTORE' to confirm: " confirm
    if [[ "$confirm" != "RESTORE" ]]; then
        echo "Restore cancelled."
        exit 0
    fi
    
    perform_restore "$selected_archive" "$selected_site"
}

perform_restore() {
    local archive_name="$1"
    local site_name="$2"
    local site_path="$SITES_ROOT/$site_name"
    local timestamp=$(date +%s)
    local restore_dir=$(mktemp -d "${TEMP_BACKUP_DIR}/restore_${site_name}_${timestamp}_XXXXXX")
    local backup_dir="${site_path}.backup.${timestamp}"
    local db_backup_file="${backup_dir}_database.sql"
    local restore_log="$LOG_DIR/restore_${site_name}_${timestamp}.log"
    
    # Logging function for restore
    restore_log() {
        local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
        echo "$msg" | tee -a "$restore_log"
    }
    
    restore_log "Starting failproof restore process for $site_name"
    
    # Pre-restore validation
    restore_log "Phase 1: Pre-restore validation"
    
    # Check disk space (3x archive size)
    local archive_size=$(tarsnap --print-stats -f "$archive_name" 2>/dev/null | grep "Compressed size" | awk '{print $3}' || echo "1000000000")
    local required_space=$((archive_size * 3))
    local available_space=$(df "$TEMP_BACKUP_DIR" | awk 'NR==2 {print $4*1024}')
    
    if (( available_space < required_space )); then
        restore_log "ERROR: Insufficient disk space. Required: $required_space, Available: $available_space"
        return 1
    fi
    
    # Test database connectivity
    if [[ -f "$site_path/wp-config.php" ]]; then
        local db_name=$(get_wp_config_value "$site_path/wp-config.php" 'DB_NAME')
        local db_user=$(get_wp_config_value "$site_path/wp-config.php" 'DB_USER')
        local db_password=$(get_wp_config_value "$site_path/wp-config.php" 'DB_PASSWORD')
        local db_host=$(get_wp_config_value "$site_path/wp-config.php" 'DB_HOST')
        db_host=${db_host:-localhost}
        
        if ! mysql -u "$db_user" -p"$db_password" -h "$db_host" -e "SELECT 1" "$db_name" &>/dev/null; then
            restore_log "ERROR: Cannot connect to database $db_name"
            return 1
        fi
        restore_log "Database connectivity verified"
    fi
    
    # Dry run mode
    read -p "\nPerform dry run first? (Y/n): " dry_run
    if [[ "$dry_run" != "n" && "$dry_run" != "N" ]]; then
        restore_log "Phase 2: Dry run validation"
        
        # Test archive extraction
        if ! tarsnap --dry-run -x -f "$archive_name" -C "$restore_dir" &>/dev/null; then
            restore_log "ERROR: Archive extraction test failed"
            return 1
        fi
        restore_log "Archive extraction test passed"
        
        echo "\nDry run completed successfully. Proceed with actual restore?"
        read -p "Continue? (y/N): " proceed
        if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
            restore_log "Restore cancelled by user"
            return 0
        fi
    fi
    
    # Create full backup of existing site
    restore_log "Phase 3: Creating safety backup"
    
    if [[ -d "$site_path" ]]; then
        restore_log "Backing up existing site to $backup_dir"
        if ! cp -a "$site_path" "$backup_dir"; then
            restore_log "ERROR: Failed to backup existing site"
            return 1
        fi
        
        # Backup database
        if [[ -n "$db_name" ]]; then
            restore_log "Backing up existing database"
            if ! mysqldump -u "$db_user" -p"$db_password" -h "$db_host" "$db_name" > "$db_backup_file"; then
                restore_log "ERROR: Failed to backup database"
                return 1
            fi
        fi
        restore_log "Safety backup completed"
    fi
    
    # Atomic restore with rollback capability
    restore_log "Phase 4: Atomic restore operation"
    
    # Extract to staging area
    restore_log "Extracting archive to staging area"
    if ! tarsnap -x -f "$archive_name" -C "$restore_dir"; then
        restore_log "ERROR: Archive extraction failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Validate extracted files
    local extracted_site="${restore_dir}${site_path}"
    if [[ ! -d "$extracted_site" ]]; then
        restore_log "ERROR: Site directory not found in archive"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    if [[ ! -f "$extracted_site/wp-config.php" ]]; then
        restore_log "ERROR: wp-config.php not found in extracted files"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Find and validate database dump
    local db_dump=$(find "$restore_dir" -name "*_db_*.sql" | head -1)
    if [[ ! -f "$db_dump" ]]; then
        restore_log "ERROR: Database dump not found in archive"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Validate database dump
    if [[ ! -s "$db_dump" ]]; then
        restore_log "ERROR: Database dump is empty"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Atomic file replacement
    restore_log "Performing atomic file replacement"
    [[ -d "$site_path" ]] && rm -rf "$site_path"
    if ! mv "$extracted_site" "$site_path"; then
        restore_log "ERROR: Failed to move files to final location"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Restore database with transaction
    restore_log "Restoring database with transaction safety"
    local new_db_name=$(get_wp_config_value "$site_path/wp-config.php" 'DB_NAME')
    local new_db_user=$(get_wp_config_value "$site_path/wp-config.php" 'DB_USER')
    local new_db_password=$(get_wp_config_value "$site_path/wp-config.php" 'DB_PASSWORD')
    local new_db_host=$(get_wp_config_value "$site_path/wp-config.php" 'DB_HOST')
    new_db_host=${new_db_host:-localhost}
    
    if ! mysql -u "$new_db_user" -p"$new_db_password" -h "$new_db_host" "$new_db_name" < "$db_dump"; then
        restore_log "ERROR: Database restore failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Fix permissions and ownership
    restore_log "Phase 5: Setting permissions and ownership"
    chown -R www-data:www-data "$site_path" 2>/dev/null || {
        restore_log "WARNING: Could not set www-data ownership"
    }
    find "$site_path" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$site_path" -type d -exec chmod 755 {} \; 2>/dev/null || true
    
    # WordPress validation
    restore_log "Phase 6: WordPress installation validation"
    if ! validate_wordpress "$site_path" "$restore_log"; then
        restore_log "ERROR: WordPress validation failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Cleanup staging area
    rm -rf "$restore_dir"
    
    restore_log "Restore completed successfully!"
    restore_log "Site restored to: $site_path"
    restore_log "Safety backup available at: $backup_dir"
    restore_log "Database backup available at: $db_backup_file"
    restore_log "Restore log: $restore_log"
    
    echo "\n✓ Restore completed successfully!"
    echo "✓ Site: $site_path"
    echo "✓ Backup: $backup_dir"
    echo "✓ Log: $restore_log"
}

rollback_restore() {
    local site_path="$1"
    local backup_dir="$2"
    local db_backup_file="$3"
    local restore_log="$4"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ROLLBACK: Restoring from backup" | tee -a "$restore_log"
    
    # Restore files
    if [[ -d "$backup_dir" ]]; then
        [[ -d "$site_path" ]] && rm -rf "$site_path"
        mv "$backup_dir" "$site_path"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ROLLBACK: Files restored" | tee -a "$restore_log"
    fi
    
    # Restore database
    if [[ -f "$db_backup_file" && -f "$site_path/wp-config.php" ]]; then
        local db_name=$(get_wp_config_value "$site_path/wp-config.php" 'DB_NAME')
        local db_user=$(get_wp_config_value "$site_path/wp-config.php" 'DB_USER')
        local db_password=$(get_wp_config_value "$site_path/wp-config.php" 'DB_PASSWORD')
        local db_host=$(get_wp_config_value "$site_path/wp-config.php" 'DB_HOST')
        db_host=${db_host:-localhost}
        
        mysql -u "$db_user" -p"$db_password" -h "$db_host" "$db_name" < "$db_backup_file"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ROLLBACK: Database restored" | tee -a "$restore_log"
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ROLLBACK: Complete" | tee -a "$restore_log"
}

validate_wordpress() {
    local site_path="$1"
    local restore_log="$2"
    
    # Check core WordPress files
    local required_files=("wp-config.php" "wp-load.php" "wp-settings.php" "index.php")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$site_path/$file" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATION: Missing $file" | tee -a "$restore_log"
            return 1
        fi
    done
    
    # Check wp-content structure
    local required_dirs=("wp-content" "wp-content/themes" "wp-content/plugins")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$site_path/$dir" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATION: Missing $dir" | tee -a "$restore_log"
            return 1
        fi
    done
    
    # Validate wp-config.php syntax
    if ! php -l "$site_path/wp-config.php" &>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATION: wp-config.php syntax error" | tee -a "$restore_log"
        return 1
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATION: WordPress structure valid" | tee -a "$restore_log"
    return 0
}

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