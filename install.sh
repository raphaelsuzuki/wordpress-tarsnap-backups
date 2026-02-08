#!/bin/bash

# WordPress Tarsnap Backups - Installation Script
# Installs the backup script and configuration to system locations
# Can be run directly from GitHub or locally
#
# Usage:
#   sudo ./install.sh           # Install normally
#   ./install.sh --dry-run      # Test without installing

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Installation paths
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc"
SCRIPT_NAME="wordpress-tarsnap-backups.sh"
CONFIG_NAME="wordpress-tarsnap-backups.conf"

# GitHub repository
GITHUB_REPO="https://raw.githubusercontent.com/raphaelsuzuki/wordpress-tarsnap-backups/main"

# Dry run mode
DRY_RUN=false

print_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

print_dry_run() {
    echo -e "${BLUE}[DRY-RUN]${NC} $*"
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would run: $*"
    else
        "$@"
    fi
}

check_root() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Dry run mode - skipping root check"
        return 0
    fi
    
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    
    for cmd in tarsnap mysqldump; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_warn "Missing dependencies (ignored in dry-run): ${missing[*]}"
        else
            print_error "Missing required dependencies: ${missing[*]}"
            echo ""
            echo "Please install:"
            for cmd in "${missing[@]}"; do
                case "$cmd" in
                    tarsnap)
                        echo "  - Tarsnap: https://www.tarsnap.com/download.html"
                        ;;
                    mysqldump)
                        echo "  - MySQL client: apt-get install mysql-client (Debian/Ubuntu)"
                        echo "                  yum install mysql (RHEL/CentOS)"
                        ;;
                esac
            done
            exit 1
        fi
    else
        print_info "All dependencies found"
    fi
}

detect_source() {
    # Check if running from local directory
    if [[ -f "./$SCRIPT_NAME" && -f "./$CONFIG_NAME" ]]; then
        echo "local"
    else
        echo "github"
    fi
}

install_from_local() {
    print_info "Installing from local directory..."
    
    # Install script
    if [[ ! -f "./$SCRIPT_NAME" ]]; then
        print_error "Script file not found: ./$SCRIPT_NAME"
        exit 1
    fi
    
    run_cmd cp "./$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME"
    run_cmd chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"
    print_info "Installed script to $INSTALL_DIR/$SCRIPT_NAME"
    
    # Install config (only if doesn't exist)
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        print_warn "Config file already exists at $CONFIG_DIR/$CONFIG_NAME"
        if [[ "$DRY_RUN" == false ]]; then
            read -p "Overwrite? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                run_cmd cp "$CONFIG_DIR/$CONFIG_NAME" "$CONFIG_DIR/${CONFIG_NAME}.backup.$(date +%s)"
                print_info "Backed up existing config"
                run_cmd cp "./$CONFIG_NAME" "$CONFIG_DIR/$CONFIG_NAME"
                run_cmd chmod 640 "$CONFIG_DIR/$CONFIG_NAME"
                print_info "Installed new config to $CONFIG_DIR/$CONFIG_NAME"
            fi
        else
            print_dry_run "Would prompt to overwrite config"
        fi
    else
        run_cmd cp "./$CONFIG_NAME" "$CONFIG_DIR/$CONFIG_NAME"
        run_cmd chmod 640 "$CONFIG_DIR/$CONFIG_NAME"
        print_info "Installed config to $CONFIG_DIR/$CONFIG_NAME"
    fi
}

install_from_github() {
    print_info "Installing from GitHub..."
    
    # Check if curl or wget is available
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl -fsSL"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget -qO-"
    else
        print_error "Neither curl nor wget found. Please install one of them."
        exit 1
    fi
    
    # Download and install script
    print_info "Downloading script..."
    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would download: $GITHUB_REPO/$SCRIPT_NAME"
        print_dry_run "Would save to: $INSTALL_DIR/$SCRIPT_NAME"
        print_dry_run "Would chmod 755: $INSTALL_DIR/$SCRIPT_NAME"
    else
        if $DOWNLOAD_CMD "$GITHUB_REPO/$SCRIPT_NAME" > "$INSTALL_DIR/$SCRIPT_NAME"; then
            chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"
            print_info "Installed script to $INSTALL_DIR/$SCRIPT_NAME"
        else
            print_error "Failed to download script from GitHub"
            exit 1
        fi
    fi
    
    # Download and install config (only if doesn't exist)
    if [[ -f "$CONFIG_DIR/$CONFIG_NAME" ]]; then
        print_warn "Config file already exists at $CONFIG_DIR/$CONFIG_NAME"
        print_info "Skipping config installation (use existing config)"
    else
        print_info "Downloading config..."
        if [[ "$DRY_RUN" == true ]]; then
            print_dry_run "Would download: $GITHUB_REPO/$CONFIG_NAME"
            print_dry_run "Would save to: $CONFIG_DIR/$CONFIG_NAME"
            print_dry_run "Would chmod 640: $CONFIG_DIR/$CONFIG_NAME"
        else
            if $DOWNLOAD_CMD "$GITHUB_REPO/$CONFIG_NAME" > "$CONFIG_DIR/$CONFIG_NAME"; then
                chmod 640 "$CONFIG_DIR/$CONFIG_NAME"
                print_info "Installed config to $CONFIG_DIR/$CONFIG_NAME"
            else
                print_error "Failed to download config from GitHub"
                exit 1
            fi
        fi
    fi
}

setup_log_directory() {
    local log_dir="/var/log/wordpress-tarsnap-backups"
    
    if [[ ! -d "$log_dir" ]]; then
        run_cmd mkdir -p "$log_dir"
        run_cmd chmod 750 "$log_dir"
        print_info "Created log directory: $log_dir"
    else
        print_info "Log directory already exists: $log_dir"
    fi
}

verify_tarsnap_key() {
    local key_file="/root/tarsnap.key"
    
    if [[ ! -f "$key_file" ]]; then
        print_warn "Tarsnap key file not found at $key_file"
        echo ""
        echo "You need to:"
        echo "  1. Register at https://www.tarsnap.com/"
        echo "  2. Generate a key: tarsnap-keygen --keyfile $key_file --user your@email.com --machine \$(hostname)"
        echo "  3. Set secure permissions: chmod 600 $key_file"
        echo ""
        return 1
    fi
    
    # Check permissions
    local perms=$(stat -c %a "$key_file" 2>/dev/null || echo "000")
    if [[ "$perms" != "600" ]]; then
        print_warn "Tarsnap key file has insecure permissions: $perms"
        if [[ "$DRY_RUN" == true ]]; then
            print_dry_run "Would fix permissions: chmod 600 $key_file"
        else
            echo "Fixing permissions..."
            chmod 600 "$key_file"
            print_info "Set secure permissions on $key_file"
        fi
    else
        print_info "Tarsnap key file found with correct permissions"
    fi
    
    return 0
}

configure_script() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Configuration file would be at: $CONFIG_DIR/$CONFIG_NAME"
        return 0
    fi
    
    print_info "Configuration file: $CONFIG_DIR/$CONFIG_NAME"
    echo ""
    echo "Please edit the configuration file to set:"
    echo "  - SITES_ROOT: Directory containing WordPress sites"
    echo "  - RETENTION_SCHEME: Backup retention policy (simple/gfs/manual)"
    echo "  - NOTIFY_EMAIL: Email for notifications (optional)"
    echo "  - EXCLUDED_SITES: Sites to skip (optional)"
    echo ""
    read -p "Open config file now? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        ${EDITOR:-nano} "$CONFIG_DIR/$CONFIG_NAME"
    fi
}

setup_cron() {
    echo ""
    print_info "Cron job setup"
    echo ""
    echo "For daily backups at 2:30 AM, add to root's crontab:"
    echo "  30 2 * * * $INSTALL_DIR/$SCRIPT_NAME >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1"
    echo ""
    echo "For hourly backups (GFS retention):"
    echo "  30 * * * * $INSTALL_DIR/$SCRIPT_NAME >> /var/log/wordpress-tarsnap-backups/cron.log 2>&1"
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        print_dry_run "Would prompt to open crontab"
        return 0
    fi
    
    read -p "Open root's crontab now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        crontab -e
    fi
}

print_summary() {
    echo ""
    echo "=========================================="
    print_info "Installation complete!"
    echo "=========================================="
    echo ""
    echo "Installed files:"
    echo "  Script: $INSTALL_DIR/$SCRIPT_NAME"
    echo "  Config: $CONFIG_DIR/$CONFIG_NAME"
    echo "  Logs:   /var/log/wordpress-tarsnap-backups/"
    echo ""
    echo "Next steps:"
    echo "  1. Edit config: $CONFIG_DIR/$CONFIG_NAME"
    echo "  2. Ensure Tarsnap key exists: /root/tarsnap.key"
    echo "  3. Test backup: $INSTALL_DIR/$SCRIPT_NAME"
    echo "  4. Setup cron job for automated backups"
    echo ""
    echo "Documentation:"
    echo "  README: https://github.com/raphaelsuzuki/wordpress-tarsnap-backups"
    echo "  Restore: $INSTALL_DIR/$SCRIPT_NAME --restore"
    echo ""
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                echo "WordPress Tarsnap Backups - Installer"
                echo ""
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --dry-run    Test installation without making changes"
                echo "  -h, --help   Show this help message"
                echo ""
                echo "Examples:"
                echo "  sudo $0              # Install normally"
                echo "  $0 --dry-run         # Test without installing"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    echo "WordPress Tarsnap Backups - Installer"
    echo "======================================"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}DRY RUN MODE - No changes will be made${NC}"
    fi
    echo ""
    
    check_root
    check_dependencies
    
    local source=$(detect_source)
    
    if [[ "$source" == "local" ]]; then
        install_from_local
    else
        install_from_github
    fi
    
    setup_log_directory
    verify_tarsnap_key
    configure_script
    setup_cron
    print_summary
}

main "$@"
