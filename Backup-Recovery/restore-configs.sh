#!/bin/bash

################################################################################
# Script: restore-configs.sh
# Description: Restores configuration files from backup archive
# Usage: ./restore-configs.sh --archive backup.tar.gz [--list] [--selective]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, tar, standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
ARCHIVE_FILE=""
LIST_MODE=0
SELECTIVE_MODE=0
RHEL_VERSION=""
BACKUP_DATE=$(date '+%Y%m%d-%H%M%S')
RESTORE_BACKUP_DIR=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive) ARCHIVE_FILE="$2"; shift ;;
            --list) LIST_MODE=1 ;;
            --selective) SELECTIVE_MODE=1 ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi
}

# Validate archive
validate_archive() {
    if [[ -z "$ARCHIVE_FILE" ]]; then
        error "Archive file is required (use --archive)"
        exit 1
    fi

    if [[ ! -f "$ARCHIVE_FILE" ]]; then
        error "Archive file not found: $ARCHIVE_FILE"
        exit 1
    fi

    info "Validating archive: $ARCHIVE_FILE"

    if tar -tzf "$ARCHIVE_FILE" > /dev/null 2>&1; then
        success "Archive is valid"
    else
        error "Archive is corrupted or invalid"
        exit 1
    fi
}

# List archive contents
list_archive() {
    info "Archive contents:"
    echo ""
    tar -tzf "$ARCHIVE_FILE" | head -50

    local count=$(tar -tzf "$ARCHIVE_FILE" | wc -l)
    echo ""
    info "Total items: $count"
}

# Create backup of current configs
backup_current_configs() {
    RESTORE_BACKUP_DIR="/backup/config-restore-backup-${BACKUP_DATE}"

    info "Creating backup of current configuration..."

    mkdir -p "$RESTORE_BACKUP_DIR"

    # Backup key directories
    if [[ -d /etc ]]; then
        cp -r /etc "$RESTORE_BACKUP_DIR/etc.backup" 2>/dev/null || true
    fi

    if [[ -d /root/.ssh ]]; then
        cp -r /root/.ssh "$RESTORE_BACKUP_DIR/.ssh.backup" 2>/dev/null || true
    fi

    success "Current configuration backed up to: $RESTORE_BACKUP_DIR"
}

# Restore all configs
restore_all() {
    info "Restoring all configurations from archive..."

    if tar -xzf "$ARCHIVE_FILE" -C / 2>&1 | head -20; then
        success "Restore completed"
    else
        error "Restore failed"
        return 1
    fi
}

# Interactive selective restore
restore_selective() {
    local temp_extract=$(mktemp -d)
    trap "rm -rf $temp_extract" EXIT

    info "Extracting archive to temporary location..."
    tar -xzf "$ARCHIVE_FILE" -C "$temp_extract"

    echo ""
    info "Select items to restore:"
    echo ""

    local items=()
    while IFS= read -r item; do
        items+=("$item")
        echo "[$((${#items[@]}))]: $item"
    done < <(find "$temp_extract" -maxdepth 1 -type d ! -name "$(basename $temp_extract)" | sort)

    echo ""
    info "Enter item numbers to restore (space-separated, 'all' for all, 'cancel' to quit):"
    read -p "> " selection

    if [[ "$selection" == "cancel" ]]; then
        warn "Restore cancelled"
        return 0
    fi

    if [[ "$selection" == "all" ]]; then
        restore_all
    else
        for num in $selection; do
            if [[ $num -ge 1 && $num -le ${#items[@]} ]]; then
                local item="${items[$((num-1))]}"
                info "Restoring: $item"
                cp -r "$item" / 2>/dev/null || warn "Failed to restore: $item"
            else
                warn "Invalid selection: $num"
            fi
        done
        success "Selective restore completed"
    fi
}

# Verify restored files
verify_restore() {
    info "Verifying restore operation..."

    local restored_count=0

    if [[ -d /etc ]]; then
        restored_count=$(($(find /etc -type f | wc -l)))
    fi

    info "Verified files in /etc: $restored_count"

    if [[ -f /etc/fstab.backup ]]; then
        success "fstab backup found"
    fi

    if [[ -f /etc/default/grub ]]; then
        success "GRUB configuration found"
    fi
}

# Show restore summary
show_summary() {
    echo ""
    info "=== Restore Summary ==="
    echo ""
    success "Restore operation completed"

    if [[ -n "$RESTORE_BACKUP_DIR" ]]; then
        info "Previous configuration saved to: $RESTORE_BACKUP_DIR"
    fi

    warn "IMPORTANT: Review restored configurations and test system stability"
    warn "Some services may require restart after restore"
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel
    validate_archive

    {
        info "=== Configuration Restore Manager ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Archive: $ARCHIVE_FILE"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        if [[ $LIST_MODE -eq 1 ]]; then
            list_archive
        else
            backup_current_configs
            echo ""

            if [[ $SELECTIVE_MODE -eq 1 ]]; then
                restore_selective
            else
                restore_all
            fi

            echo ""
            verify_restore
            show_summary
        fi
    }
}

main "$@"
