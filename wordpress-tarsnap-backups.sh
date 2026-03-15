#!/bin/bash

# WordPress Tarsnap Backups v1.5.1
# Automated backup and restore solution for WordPress sites using Tarsnap
#
# Features:
# - Auto-discovery of WordPress installations
# - Three retention schemes: Simple, GFS, and Manual
# - Multiple custom configuration files support
# - Error handling and email notifications
# - Restore functionality with automatic rollback and validation
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
SHOW_PROGRESS="yes"
PRINT_STATS="yes"
EXCLUDED_SITES="22222 html"
INCLUDED_SITES=""
EXCLUDED_DIRECTORIES="cache logs tmp uploads/cache wp-content/cache wp-content/updraft wp-content/backup* wp-content/uploads/backup*"

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
    # Check that file is readable, not executable, and not world-readable
    CONFIG_PERMS=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || echo "000")
    if [[ ! "$CONFIG_PERMS" =~ ^[0-7][0-7]0$ ]]; then
        echo "Error: Configuration file '$CONFIG_FILE' is world-readable (permissions: $CONFIG_PERMS)"
        echo "Fix with: chmod 640 '$CONFIG_FILE'"
        exit 1
    fi
    if [[ -r "$CONFIG_FILE" && ! -x "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo "Using configuration file: $CONFIG_FILE"
    else
        echo "Error: Configuration file '$CONFIG_FILE' has invalid permissions"
        exit 1
    fi
else
    echo "Warning: No configuration file found, using defaults"
    echo "Using default configuration (script defaults)"
fi

# Convert space-separated EXCLUDED_SITES, INCLUDED_SITES, and EXCLUDED_DIRECTORIES (directory patterns for backup exclusion) to arrays
read -ra EXCLUDED_SITES_ARRAY <<< "$EXCLUDED_SITES"
read -ra INCLUDED_SITES_ARRAY <<< "$INCLUDED_SITES"
read -ra EXCLUDED_DIRECTORIES_ARRAY <<< "$EXCLUDED_DIRECTORIES"

# Build tarsnap exclusion patterns once
TARSNAP_EXCLUDES=()
for exclude_dir in "${EXCLUDED_DIRECTORIES_ARRAY[@]}"; do
    [[ -n "$exclude_dir" ]] && TARSNAP_EXCLUDES+=("--exclude=*/$exclude_dir")
done

# --- Restore Functions ---
restore_log() {
    local logfile="$1"
    shift
    echo "[$(date '+%F %T')] $*" | tee -a "$logfile"
}
restore_mode() {
    echo "WordPress Tarsnap Restore Wizard"
    echo "================================="
    
    # List available archives (fetch fresh list for restore mode)
    printf "\nFetching available backups...\n"
    local archives_list=$(tarsnap --list-archives 2>/dev/null || echo "")
    mapfile -t archives < <(echo "$archives_list" | grep -E '^[^-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$' | sort -t- -k2,2nr -k3,3nr -k4,4nr -k5,5nr)
    
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
    printf "\nAvailable sites:\n"
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
        
        printf "\nAvailable backups for %s (page %d):\n" "$selected_site" "$((page+1))"
        
        local displayed=0
        for i in $(seq $start $((end-1))); do
            [[ $i -ge ${#all_site_archives[@]} ]] && break
            archive="${all_site_archives[i]}"
            
            # Validate archive name format for security
            if [[ ! "$archive" =~ ^[a-zA-Z0-9._-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
                log "WARNING" "RESTORE" "Skipping invalid archive name: $archive"
                continue
            fi
            
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
    printf "\n%s\n" "$(printf '=%.0s' {1..50})"
    echo "RESTORE CONFIRMATION"
    echo "="*50
    echo "Site: $selected_site"
    echo "Archive: $selected_archive"
    echo "Target: $SITES_ROOT/$selected_site"
    printf "\nWARNING: This will:\n"
    echo "• Create backup of existing site"
    echo "• OVERWRITE all files in $SITES_ROOT/$selected_site"
    echo "• OVERWRITE the database completely"
    echo "• Create restore log for audit trail"
    printf "\nSafety measures:\n"
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
    
    # Validate archive name to prevent command injection
    if [[ ! "$archive_name" =~ ^[a-zA-Z0-9._-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
        echo "ERROR: Invalid archive name format: $archive_name"
        return 1
    fi
    
    # Validate site name to prevent path traversal
    if [[ ! "$site_name" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$site_name" == "." ]] || [[ "$site_name" == ".." ]]; then
        echo "ERROR: Invalid site name format: $site_name"
        return 1
    fi
    
    local site_path="$SITES_ROOT/$site_name"
    local timestamp=$(date +%s)
    
    # Create secure temporary directory with restrictive umask
    OLD_UMASK=$(umask)
    umask 077
    local restore_dir=$(mktemp -d -p "$TEMP_BACKUP_DIR" "restore_${site_name}_${timestamp}_XXXXXX")
    umask "$OLD_UMASK"
    
    local backup_dir="${site_path}.backup.${timestamp}"
    local db_backup_file="${backup_dir}_database.sql"
    local restore_log="$LOG_DIR/restore_${site_name}_${timestamp}.log"
    
    # Use global restore_log function
    
    restore_log "$restore_log" "Starting failproof restore process for $site_name"
    
    # Pre-restore validation
    restore_log "$restore_log" "Phase 1: Pre-restore validation"
    
    # Check disk space (3x archive size)
    local archive_size=$(tarsnap --print-stats -f "$archive_name" 2>/dev/null | grep "Compressed size" | awk '{print $3}' | sed 's/[^0-9]//g' || echo "1000000000")
    local required_space=$((archive_size * 3))
    local available_space=$(df "$TEMP_BACKUP_DIR" | awk 'NR==2 {print $4*1024}')
    
    if (( available_space < required_space )); then
        restore_log "$restore_log" "ERROR: Insufficient disk space. Required: $required_space, Available: $available_space"
        return 1
    fi
    
    # Test database connectivity
    if [[ -f "$site_path/wp-config.php" ]]; then
        local db_name=$(get_wp_config_value "$site_path/wp-config.php" 'DB_NAME')
        local db_user=$(get_wp_config_value "$site_path/wp-config.php" 'DB_USER')
        local db_password=$(get_wp_config_value "$site_path/wp-config.php" 'DB_PASSWORD')
        local db_host=$(get_wp_config_value "$site_path/wp-config.php" 'DB_HOST')
        db_host=${db_host:-localhost}
        
        # Create secure temp file for MySQL credentials
        OLD_UMASK=$(umask)
        umask 077
        local mysql_test_opts=$(mktemp -p "$TEMP_BACKUP_DIR" "mysql_test_XXXXXX")
        umask "$OLD_UMASK"
        {
            printf '[client]\n'
            printf 'user=%s\n' "$db_user"
            printf 'password=%s\n' "$db_password"
            printf 'host=%s\n' "$db_host"
        } > "$mysql_test_opts"
        
        if ! mysql --defaults-extra-file="$mysql_test_opts" -e "SELECT 1" "$db_name" &>/dev/null; then
            rm -f "$mysql_test_opts"
            restore_log "$restore_log" "ERROR: Cannot connect to database $db_name"
            return 1
        fi
        rm -f "$mysql_test_opts"
        restore_log "$restore_log" "Database connectivity verified"
    fi
    
    # Dry run mode
    read -p "\nPerform dry run first? (Y/n): " dry_run
    if [[ "$dry_run" != "n" && "$dry_run" != "N" ]]; then
        restore_log "$restore_log" "Phase 2: Dry run validation"
        
        # Test archive extraction
        if ! tarsnap --dry-run -x -f "$archive_name" -C "$restore_dir" &>/dev/null; then
            restore_log "$restore_log" "ERROR: Archive extraction test failed"
            return 1
        fi
        restore_log "$restore_log" "Archive extraction test passed"
        
        printf "\nDry run completed successfully. Proceed with actual restore?\n"
        read -p "Continue? (y/N): " proceed
        if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
            restore_log "$restore_log" "Restore cancelled by user"
            return 0
        fi
    fi
    
    # Create full backup of existing site
    restore_log "$restore_log" "Phase 3: Creating safety backup"
    
    if [[ -d "$site_path" ]]; then
        restore_log "$restore_log" "Backing up existing site to $backup_dir"
        if ! cp -a "$site_path" "$backup_dir"; then
            restore_log "$restore_log" "ERROR: Failed to backup existing site"
            return 1
        fi
        
        # Backup database
        if [[ -n "$db_name" ]]; then
            restore_log "$restore_log" "Backing up existing database"
            # Create secure temp file for MySQL credentials
            OLD_UMASK=$(umask)
            umask 077
            local mysql_backup_opts=$(mktemp -p "$TEMP_BACKUP_DIR" "mysql_backup_XXXXXX")
            umask "$OLD_UMASK"
            {
                printf '[client]\n'
                printf 'user=%s\n' "$db_user"
                printf 'password=%s\n' "$db_password"
                printf 'host=%s\n' "$db_host"
            } > "$mysql_backup_opts"
            
            if ! mysqldump --defaults-extra-file="$mysql_backup_opts" "$db_name" > "$db_backup_file"; then
                rm -f "$mysql_backup_opts"
                restore_log "$restore_log" "ERROR: Failed to backup database"
                return 1
            fi
            rm -f "$mysql_backup_opts"
        fi
        restore_log "$restore_log" "Safety backup completed"
    fi
    
    # Atomic restore with rollback capability
    restore_log "$restore_log" "Phase 4: Atomic restore operation"
    
    # Extract to staging area
    restore_log "$restore_log" "Extracting archive to staging area"
    if ! tarsnap -x -f "$archive_name" -C "$restore_dir"; then
        restore_log "$restore_log" "ERROR: Archive extraction failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Validate extracted files
    local extracted_site="${restore_dir}${site_path}"
    if [[ ! -d "$extracted_site" ]]; then
        restore_log "$restore_log" "ERROR: Site directory not found in archive"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    if [[ ! -f "$extracted_site/wp-config.php" ]]; then
        restore_log "$restore_log" "ERROR: wp-config.php not found in extracted files"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Find and validate database dump
    local db_dump=$(find "$restore_dir" -name "*_db_*.sql" | head -1)
    if [[ ! -f "$db_dump" ]]; then
        restore_log "$restore_log" "ERROR: Database dump not found in archive"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Validate database dump
    if [[ ! -s "$db_dump" ]]; then
        restore_log "$restore_log" "ERROR: Database dump is empty"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Atomic file replacement
    restore_log "$restore_log" "Performing atomic file replacement"
    [[ -d "$site_path" ]] && rm -rf "$site_path"
    if ! mv "$extracted_site" "$site_path"; then
        restore_log "$restore_log" "ERROR: Failed to move files to final location"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Restore database with transaction
    restore_log "$restore_log" "Restoring database with transaction safety"
    local new_db_name=$(get_wp_config_value "$site_path/wp-config.php" 'DB_NAME')
    local new_db_user=$(get_wp_config_value "$site_path/wp-config.php" 'DB_USER')
    local new_db_password=$(get_wp_config_value "$site_path/wp-config.php" 'DB_PASSWORD')
    local new_db_host=$(get_wp_config_value "$site_path/wp-config.php" 'DB_HOST')
    new_db_host=${new_db_host:-localhost}
    
    # Create secure temp file for MySQL credentials
    OLD_UMASK=$(umask)
    umask 077
    local mysql_restore_opts=$(mktemp -p "$TEMP_BACKUP_DIR" "mysql_restore_XXXXXX")
    umask "$OLD_UMASK"
    {
        printf '[client]\n'
        printf 'user=%s\n' "$new_db_user"
        printf 'password=%s\n' "$new_db_password"
        printf 'host=%s\n' "$new_db_host"
    } > "$mysql_restore_opts"
    
    if ! mysql --defaults-extra-file="$mysql_restore_opts" "$new_db_name" < "$db_dump"; then
        rm -f "$mysql_restore_opts"
        restore_log "$restore_log" "ERROR: Database restore failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    rm -f "$mysql_restore_opts"
    
    # Fix permissions and ownership
    restore_log "$restore_log" "Phase 5: Setting permissions and ownership"
    chown -R www-data:www-data "$site_path" 2>/dev/null || {
        restore_log "$restore_log" "WARNING: Could not set www-data ownership"
    }
    find "$site_path" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$site_path" -type d -exec chmod 755 {} \; 2>/dev/null || true
    
    # WordPress validation
    restore_log "$restore_log" "Phase 6: WordPress installation validation"
    if ! validate_wordpress "$site_path" "$restore_log"; then
        restore_log "$restore_log" "ERROR: WordPress validation failed"
        rollback_restore "$site_path" "$backup_dir" "$db_backup_file" "$restore_log"
        return 1
    fi
    
    # Cleanup staging area
    rm -rf "$restore_dir"
    
    restore_log "$restore_log" "Restore completed successfully!"
    restore_log "$restore_log" "Site restored to: $site_path"
    restore_log "$restore_log" "Safety backup available at: $backup_dir"
    restore_log "$restore_log" "Database backup available at: $db_backup_file"
    restore_log "$restore_log" "Restore log: $restore_log"
    
    printf "\n✓ Restore completed successfully!\n"
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
        
        # Create secure temp file for MySQL credentials
        OLD_UMASK=$(umask)
        umask 077
        local mysql_rollback_opts=$(mktemp -p "$TEMP_BACKUP_DIR" "mysql_rollback_XXXXXX")
        umask "$OLD_UMASK"
        {
            printf '[client]\n'
            printf 'user=%s\n' "$db_user"
            printf 'password=%s\n' "$db_password"
            printf 'host=%s\n' "$db_host"
        } > "$mysql_rollback_opts"
        
        mysql --defaults-extra-file="$mysql_rollback_opts" "$db_name" < "$db_backup_file"
        rm -f "$mysql_rollback_opts"
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

# Check for restore mode
if [[ "${1:-}" == "--restore" ]]; then
    shift
    restore_mode "$@"
    exit 0
fi

# Cache tarsnap archive list for performance (single network call)
log "INFO" "MAIN" "Fetching archive list from Tarsnap..."
TARSNAP_ARCHIVES_CACHE=$(tarsnap --list-archives 2>/dev/null || echo "")
if [[ -z "$TARSNAP_ARCHIVES_CACHE" ]]; then
    log "WARNING" "MAIN" "No archives found or unable to fetch archive list"
fi

# Set Tarsnap key file environment variable
export TARSNAP_KEYFILE="$TARSNAP_KEY_FILE"

# Track errors for notification
ERROR_COUNT=0
ERROR_SITES=()
ERROR_DETAILS=()
BACKUP_STATS=()

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

# Log which configuration is being used (file or defaults)
if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    log "INFO" "MAIN" "Using configuration file: $CONFIG_FILE"
else
    log "INFO" "MAIN" "Using default configuration (script defaults)"
fi

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

# WordPress Site Discovery Function with security checks
find_wordpress_sites() {
    local sites_root="$1"
    local excluded_sites="$2"
    local included_sites="$3"
    
    local found_sites=()
    local excluded_found=()
    
    for SITE_DIR in "${sites_root}"/*/; do
        SITE_DIR="${SITE_DIR%/}"
        SITE_NAME=$(basename "${SITE_DIR}")
        
        # Skip if no sites found (glob didn't match)
        [[ -d "${SITE_DIR}" ]] || continue
        
        # Prevent symlink directory traversal attacks
        REAL_SITE_DIR=$(realpath "${SITE_DIR}" 2>/dev/null || echo "")
        REAL_SITES_ROOT=$(realpath "${sites_root}" 2>/dev/null || echo "")
        if [[ -z "${REAL_SITE_DIR}" || -z "${REAL_SITES_ROOT}" || "${REAL_SITE_DIR}" != "${REAL_SITES_ROOT}"/* ]]; then
            log "WARNING" "MAIN" "SECURITY: Skipping ${SITE_NAME}: Path traversal detected or invalid path"
            continue
        fi

        # Include/Exclude Sites Logic
        if [[ -n "${included_sites}" ]]; then
            if [[ ! " ${included_sites} " =~ " ${SITE_NAME} " ]]; then
                excluded_found+=("${SITE_NAME}")
                continue
            fi
        else
            if [[ " ${excluded_sites} " =~ " ${SITE_NAME} " ]]; then
                excluded_found+=("${SITE_NAME}")
                continue
            fi
        fi

        # Check for WordPress installation (flexible structure)
        WP_ROOT_PATH="${SITE_DIR}"
        WP_CONFIG_PATH=""
        
        # Check for wp-config.php in multiple locations
        if [[ -f "${SITE_DIR}/wp-config.php" ]]; then
            WP_CONFIG_PATH="${SITE_DIR}/wp-config.php"
        elif [[ -f "${SITE_DIR}/htdocs/wp-config.php" ]]; then
            WP_CONFIG_PATH="${SITE_DIR}/htdocs/wp-config.php"
            WP_ROOT_PATH="${SITE_DIR}/htdocs"
        else
            log "INFO" "MAIN" "SKIP: ${SITE_NAME}: No wp-config.php found"
            continue
        fi

        # Validate WordPress structure
        if [[ ! -d "${WP_ROOT_PATH}" ]]; then
            log "WARNING" "MAIN" "SKIP: ${SITE_NAME}: ${WP_ROOT_PATH} not a directory"
            continue
        fi

        # Add to found sites
        found_sites+=("${SITE_NAME}:${WP_ROOT_PATH}:${WP_CONFIG_PATH}")
    done
    
    # Log excluded sites
    if [[ ${#excluded_found[@]} -gt 0 ]]; then
        log "INFO" "MAIN" "Excluded sites: ${excluded_found[*]}"
    fi
    
    # Return found sites
    printf '%s\n' "${found_sites[@]}"
}

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
    value=$(printf '%s' "$value" | tr -d '`$(){}[]|&;<>')
    
    # Validate format based on define name
    case "$define_name" in
        DB_NAME|DB_USER)
            # Database names and users should only contain alphanumeric, underscore, hyphen
            if [[ ! "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "" # Return empty for invalid format
                return 1
            fi
            ;;
        DB_HOST)
            # Host can be hostname, IP, or localhost with optional port
            if [[ ! "$value" =~ ^[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]; then
                echo "" # Return empty for invalid format
                return 1
            fi
            ;;
        DB_PASSWORD)
            # Password can contain most characters but validate length
            if [[ ${#value} -gt 255 || ${#value} -eq 0 ]]; then
                echo "" # Return empty for invalid length
                return 1
            fi
            ;;
    esac
    
    printf '%s' "$value"
}

# GFS Retention Function
apply_gfs_retention() {
    local site_name="$1"
    local safe_site_name="$2"
    
    # Use cached archive list instead of making another network call
    mapfile -t all_archives < <(echo "$TARSNAP_ARCHIVES_CACHE" | grep "^${safe_site_name}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)
    
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

# Start overall timing
OVERALL_START=$(date +%s)

# Display configuration information
if [[ -n "$CONFIG_FILE" ]]; then
    log "INFO" "MAIN" "Using configuration file: $CONFIG_FILE"
else
    log "INFO" "MAIN" "Using built-in default configuration"
fi

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

# Discover WordPress sites with security checks
mapfile -t WORDPRESS_SITES < <(find_wordpress_sites "$SITES_ROOT" "$EXCLUDED_SITES" "$INCLUDED_SITES")

if [[ ${#WORDPRESS_SITES[@]} -eq 0 ]]; then
    log "INFO" "MAIN" "No WordPress sites found for backup"
    exit 0
fi

log "INFO" "MAIN" "Found ${#WORDPRESS_SITES[@]} WordPress site(s) for backup"

# Process each discovered WordPress site
for SITE_INFO in "${WORDPRESS_SITES[@]}"; do
    # Parse site information: SITE_NAME:WP_ROOT_PATH:WP_CONFIG_PATH
    IFS=':' read -r SITE_DIRNAME SITE_PATH WP_CONFIG_PATH <<< "$SITE_INFO"
    
    # Start site backup timing
    SITE_START=$(date +%s)
    
    log "INFO" "$SITE_DIRNAME" "Starting backup process"
    log "INFO" "$SITE_DIRNAME" "WordPress root: $SITE_PATH"
    log "INFO" "$SITE_DIRNAME" "Config file: $WP_CONFIG_PATH"

    # Extract and validate database credentials
    DB_NAME=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_NAME')
    DB_USER=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_USER')
    DB_PASSWORD=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_PASSWORD')
    DB_HOST=$(get_wp_config_value "$WP_CONFIG_PATH" 'DB_HOST')

    # Validate extracted credentials (validation now done in get_wp_config_value)
    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
        log "ERROR" "$SITE_DIRNAME" "Could not extract or validate database credentials"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: DB credentials")
        ERROR_DETAILS+=("$(date '+%Y-%m-%d %H:%M:%S') - $SITE_DIRNAME: Could not extract or validate database credentials from wp-config.php")
        continue
    fi

    DB_HOST=${DB_HOST:-localhost}
    
    # Additional validation for DB_HOST after default assignment
    if [[ ! "$DB_HOST" =~ ^[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]; then
        log "ERROR" "$SITE_DIRNAME" "Invalid database host format: $DB_HOST"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Invalid DB host")
        ERROR_DETAILS+=("$(date '+%Y-%m-%d %H:%M:%S') - $SITE_DIRNAME: Invalid database host format")
        continuentinue
    fi

    DB_HOST=${DB_HOST:-localhost}

    log "INFO" "$SITE_DIRNAME" "Starting database dump for '$DB_NAME'"

    # Create secure temporary files with restrictive umask
    DATE=$(date +%Y-%m-%d-%H%M%S)
    # Sanitize site dirname for filename
    SAFE_SITE_NAME=$(printf '%s' "$SITE_DIRNAME" | tr -cd '[:alnum:]._-')
    
    # Set restrictive umask before creating temp files to prevent race condition
    OLD_UMASK=$(umask)
    umask 077
    
    DB_DUMP_FILE=$(mktemp -p "$TEMP_BACKUP_DIR" "${SAFE_SITE_NAME}_db_${DATE}_XXXXXX.sql")
    MYSQL_CONN_OPTS=$(mktemp -p "$TEMP_BACKUP_DIR" "mysql_conn_XXXXXX")
    
    # Restore original umask
    umask "$OLD_UMASK"
    
    TEMP_FILES+=("$DB_DUMP_FILE" "$MYSQL_CONN_OPTS")
    
    # Verify secure permissions were set (defense in depth)
    chmod 600 "$DB_DUMP_FILE" "$MYSQL_CONN_OPTS"

    # Securely write credentials to the temporary options file
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$DB_PASSWORD"
        printf 'host=%s\n' "$DB_HOST"
    } > "$MYSQL_CONN_OPTS"

    # Perform database dump with timeout protection and progress indication
    DB_START=$(date +%s)
    log "INFO" "$SITE_DIRNAME" "Database dump in progress... (timeout: 1 hour)"
    
    # Start background progress indicator for database dump (if enabled)
    db_progress_pid=""
    if [[ "${SHOW_PROGRESS:-yes}" == "yes" ]]; then
        {
            while kill -0 $$ 2>/dev/null; do
                sleep 30
                if [[ -f "$DB_DUMP_FILE" ]]; then
                    size=$(stat -c%s "$DB_DUMP_FILE" 2>/dev/null || echo "0")
                    if (( size > 0 )); then
                        log "INFO" "$SITE_DIRNAME" "Database dump progress: $(numfmt --to=iec $size) written..."
                    fi
                fi
            done
        } &
        db_progress_pid=$!
    fi
    
    if ! timeout 3600 mysqldump --defaults-extra-file="$MYSQL_CONN_OPTS" --single-transaction --routines --triggers "$DB_NAME" > "$DB_DUMP_FILE"; then
        [[ -n "$db_progress_pid" ]] && kill "$db_progress_pid" 2>/dev/null || true
        log "ERROR" "$SITE_DIRNAME" "mysqldump failed for database '$DB_NAME'"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: mysqldump failed")
        ERROR_DETAILS+=("$(date '+%Y-%m-%d %H:%M:%S') - $SITE_DIRNAME: mysqldump failed for database '$DB_NAME' (timeout or connection error)")
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi
    [[ -n "$db_progress_pid" ]] && kill "$db_progress_pid" 2>/dev/null || true
    DB_END=$(date +%s)
    DB_DURATION=$((DB_END - DB_START))

    # Verify dump file is not empty
    if [[ ! -s "$DB_DUMP_FILE" ]]; then
        log "ERROR" "$SITE_DIRNAME" "Database dump is empty for $DB_NAME"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Empty DB dump")
        ERROR_DETAILS+=("$(date '+%Y-%m-%d %H:%M:%S') - $SITE_DIRNAME: Database dump file is empty for '$DB_NAME' (possible permission or disk space issue)")
        rm -f "$MYSQL_CONN_OPTS" "$DB_DUMP_FILE"
        MYSQL_CONN_OPTS=""
        DB_DUMP_FILE=""
        continue
    fi
    
    DB_SIZE=$(stat -c%s "$DB_DUMP_FILE" 2>/dev/null || echo "0")
    log "INFO" "$SITE_DIRNAME" "Database dump completed in ${DB_DURATION}s ($(numfmt --to=iec $DB_SIZE))"

    rm -f "$MYSQL_CONN_OPTS"
    MYSQL_CONN_OPTS=""

    log "INFO" "$SITE_DIRNAME" "Database dump created: $(basename "$DB_DUMP_FILE")"
    log "INFO" "$SITE_DIRNAME" "Starting Tarsnap backup (excluding cache/backup directories)"

    # Create safe archive name
    TARSNAP_ARCHIVE_NAME="${SAFE_SITE_NAME}-${DATE}"
    
    # Start background progress indicator for Tarsnap backup (if enabled)
    TARSNAP_START=$(date +%s)
    log "INFO" "$SITE_DIRNAME" "Tarsnap backup in progress..."
    tarsnap_progress_pid=""
    if [[ "${SHOW_PROGRESS:-yes}" == "yes" ]]; then
        {
            while kill -0 $$ 2>/dev/null; do
                sleep 60
                elapsed=$(( $(date +%s) - TARSNAP_START ))
                log "INFO" "$SITE_DIRNAME" "Tarsnap backup running... (${elapsed}s elapsed)"
            done
        } &
        tarsnap_progress_pid=$!
    fi
    
    # Perform Tarsnap backup
    if tarsnap \
        --quiet \
        -c -f "$TARSNAP_ARCHIVE_NAME" \
        "${TARSNAP_EXCLUDES[@]}" \
        "$SITE_PATH" \
        "$DB_DUMP_FILE"; then
        [[ -n "$tarsnap_progress_pid" ]] && kill "$tarsnap_progress_pid" 2>/dev/null || true
        TARSNAP_END=$(date +%s)
        TARSNAP_DURATION=$((TARSNAP_END - TARSNAP_START))
        
        # Get archive size information (if enabled)
        ARCHIVE_SIZE="unknown"
        COMPRESSED_SIZE="unknown"
        if [[ "${PRINT_STATS:-yes}" == "yes" ]]; then
            ARCHIVE_STATS=$(tarsnap --print-stats -f "$TARSNAP_ARCHIVE_NAME" 2>/dev/null || echo "")
            if [[ -n "$ARCHIVE_STATS" ]]; then
                # Use bash parameter expansion instead of external commands
                TOTAL_SIZE_LINE=$(echo "$ARCHIVE_STATS" | grep "Total size")
                COMPRESSED_SIZE_LINE=$(echo "$ARCHIVE_STATS" | grep "Compressed size")
                TOTAL_SIZE_BYTES="${TOTAL_SIZE_LINE##* }"
                TOTAL_SIZE_BYTES="${TOTAL_SIZE_BYTES//[^0-9]/}"
                COMPRESSED_SIZE_BYTES="${COMPRESSED_SIZE_LINE##* }"
                COMPRESSED_SIZE_BYTES="${COMPRESSED_SIZE_BYTES//[^0-9]/}"
                ARCHIVE_SIZE=$(numfmt --to=iec "${TOTAL_SIZE_BYTES:-0}" 2>/dev/null || echo "unknown")
                COMPRESSED_SIZE=$(numfmt --to=iec "${COMPRESSED_SIZE_BYTES:-0}" 2>/dev/null || echo "unknown")
                log "INFO" "$SITE_DIRNAME" "Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME (${TARSNAP_DURATION}s, $ARCHIVE_SIZE → $COMPRESSED_SIZE)"
            else
                log "INFO" "$SITE_DIRNAME" "Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME (${TARSNAP_DURATION}s)"
            fi
        else
            log "INFO" "$SITE_DIRNAME" "Tarsnap backup successful: $TARSNAP_ARCHIVE_NAME (${TARSNAP_DURATION}s)"
        fi
        
        # Calculate total site backup time
        SITE_END=$(date +%s)
        SITE_DURATION=$((SITE_END - SITE_START))
        BACKUP_STATS+=("$SITE_DIRNAME: ${SITE_DURATION}s total (DB: ${DB_DURATION}s, Archive: ${TARSNAP_DURATION}s, Size: ${ARCHIVE_SIZE})")

        # --- Retention Policy ---
        if [[ "$RETENTION_SCHEME" == "gfs" ]]; then
            log "INFO" "$SITE_DIRNAME" "Applying GFS retention policy"
            apply_gfs_retention "$SITE_DIRNAME" "$SAFE_SITE_NAME"
        elif [[ "$RETENTION_SCHEME" == "simple" ]]; then
            log "INFO" "$SITE_DIRNAME" "Applying simple retention policy (${RETENTION_DAYS}d, min ${MIN_BACKUPS_TO_KEEP} backups)"
            # Use cached archive list instead of making another network call
            mapfile -t all_archives < <(echo "$TARSNAP_ARCHIVES_CACHE" | grep "^${SAFE_SITE_NAME}-[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}$" | sort -r)
            
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
        [[ -n "$tarsnap_progress_pid" ]] && kill "$tarsnap_progress_pid" 2>/dev/null || true
        TARSNAP_END=$(date +%s)
        TARSNAP_DURATION=$((TARSNAP_END - TARSNAP_START))
        log "ERROR" "$SITE_DIRNAME" "Tarsnap backup failed after ${TARSNAP_DURATION}s"
        ((ERROR_COUNT++))
        ERROR_SITES+=("$SITE_DIRNAME: Tarsnap backup failed")
        ERROR_DETAILS+=("$(date '+%Y-%m-%d %H:%M:%S') - $SITE_DIRNAME: Tarsnap backup failed after ${TARSNAP_DURATION}s (check network, key file, or disk space)")
        
        # Set failed backup stats
        SITE_END=$(date +%s)
        SITE_DURATION=$((SITE_END - SITE_START))
        BACKUP_STATS+=("$SITE_DIRNAME: ${SITE_DURATION}s total (DB: ${DB_DURATION}s, Archive: FAILED after ${TARSNAP_DURATION}s)")
    fi

    log "INFO" "$SITE_DIRNAME" "Cleaning up temporary files"
    rm -f "$DB_DUMP_FILE"
    DB_DUMP_FILE=""

done

# Calculate overall duration
OVERALL_END=$(date +%s)
OVERALL_DURATION=$((OVERALL_END - OVERALL_START))

log "INFO" "MAIN" "WordPress backup process completed in ${OVERALL_DURATION}s"

# Log backup statistics
if [[ ${#BACKUP_STATS[@]} -gt 0 ]]; then
    log "INFO" "MAIN" "Backup Statistics:"
    for stat in "${BACKUP_STATS[@]}"; do
        log "INFO" "MAIN" "  $stat"
    done
fi

# Send email notification if configured
if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &> /dev/null; then
    HOSTNAME=$(hostname)
    DATE=$(date '+%Y-%m-%d %H:%M:%S')
    if (( ERROR_COUNT > 0 )); then
        {
            echo "WordPress Tarsnap backup completed on $HOSTNAME at $DATE with $ERROR_COUNT error(s):"
            echo "Total duration: ${OVERALL_DURATION}s"
            echo
            echo "Error Details:"
            printf '%s\n' "${ERROR_DETAILS[@]}"
            echo
            echo "Summary:"
            printf '%s\n' "${ERROR_SITES[@]}"
            if [[ ${#BACKUP_STATS[@]} -gt 0 ]]; then
                echo
                echo "Successful Backups:"
                printf '%s\n' "${BACKUP_STATS[@]}"
            fi
        } | mail -s "WordPress Backup ERRORS - $HOSTNAME" "$NOTIFY_EMAIL"
    else
        {
            echo "WordPress Tarsnap backup process completed successfully on $HOSTNAME at $DATE"
            echo "Total duration: ${OVERALL_DURATION}s"
            if [[ ${#BACKUP_STATS[@]} -gt 0 ]]; then
                echo
                echo "Backup Statistics:"
                printf '%s\n' "${BACKUP_STATS[@]}"
            fi
        } | mail -s "WordPress Backup Complete - $HOSTNAME" "$NOTIFY_EMAIL"
    fi
fi