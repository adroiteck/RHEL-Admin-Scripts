#!/bin/bash

################################################################################
# Script: backup-configs.sh
# Description: Backs up critical configuration files
# Usage: ./backup-configs.sh --dest /backup [--include-rpm-list]
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
BACKUP_DEST=""
INCLUDE_RPM_LIST=0
RHEL_VERSION=""
BACKUP_DATE=$(date '+%Y%m%d-%H%M%S')
BACKUP_FILE=""
TEMP_DIR=""

# Critical config paths to backup
CONFIG_PATHS=(
    "/etc"
    "/root/.ssh"
    "/root/.bashrc"
    "/root/.bash_profile"
)

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) BACKUP_DEST="$2"; shift ;;
            --include-rpm-list) INCLUDE_RPM_LIST=1 ;;
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

# Cleanup temp directory
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Create temporary staging directory
create_temp_dir() {
    TEMP_DIR=$(mktemp -d) || {
        error "Failed to create temporary directory"
        exit 1
    }
    success "Temp directory: $TEMP_DIR"
}

# Validate backup destination
validate_destination() {
    if [[ -z "$BACKUP_DEST" ]]; then
        error "Backup destination is required (use --dest)"
        exit 1
    fi

    if [[ ! -d "$BACKUP_DEST" ]]; then
        warn "Destination does not exist, creating: $BACKUP_DEST"
        mkdir -p "$BACKUP_DEST"
    fi

    if [[ ! -w "$BACKUP_DEST" ]]; then
        error "Destination is not writable: $BACKUP_DEST"
        exit 1
    fi

    success "Backup destination valid: $BACKUP_DEST"
}

# Collect configuration files
collect_configs() {
    info "Collecting configuration files..."

    local collected=0
    for path in "${CONFIG_PATHS[@]}"; do
        if [[ -e "$path" ]]; then
            cp -r "$path" "$TEMP_DIR/" 2>/dev/null || warn "Failed to copy: $path"
            collected=$((collected + 1))
            info "  Collected: $path"
        else
            warn "  Path not found: $path"
        fi
    done

    success "Configuration files collected: $collected"
}

# Generate RPM list
generate_rpm_list() {
    info "Generating installed packages list..."

    if command -v rpm &> /dev/null; then
        rpm -qa > "$TEMP_DIR/installed-packages.txt"
        local count=$(wc -l < "$TEMP_DIR/installed-packages.txt")
        success "Installed packages list: $count packages"
    else
        warn "rpm command not found, skipping package list"
    fi
}

# Backup firewall rules
backup_firewall() {
    info "Backing up firewall rules..."

    if command -v firewall-cmd &> /dev/null; then
        mkdir -p "$TEMP_DIR/firewall"
        firewall-cmd --list-all > "$TEMP_DIR/firewall/rules.txt" 2>/dev/null || true
        success "Firewall rules backed up"
    else
        warn "firewalld not found, skipping firewall backup"
    fi
}

# Backup network configuration
backup_network() {
    info "Backing up network configuration..."

    if [[ -d /etc/sysconfig/network-scripts ]]; then
        cp -r /etc/sysconfig/network-scripts "$TEMP_DIR/network-scripts" 2>/dev/null || true
        success "Network configuration backed up"
    elif [[ -d /etc/NetworkManager ]]; then
        cp -r /etc/NetworkManager "$TEMP_DIR/NetworkManager" 2>/dev/null || true
        success "NetworkManager configuration backed up"
    fi
}

# Backup crontabs
backup_crontabs() {
    info "Backing up crontab entries..."

    mkdir -p "$TEMP_DIR/cron"
    if [[ -d /var/spool/cron ]]; then
        cp -r /var/spool/cron/* "$TEMP_DIR/cron/" 2>/dev/null || true
    fi

    if [[ -d /etc/cron.d ]]; then
        cp -r /etc/cron.d/* "$TEMP_DIR/cron/" 2>/dev/null || true
    fi

    local cron_count=$(find "$TEMP_DIR/cron" -type f | wc -l)
    if [[ $cron_count -gt 0 ]]; then
        success "Crontab entries backed up: $cron_count"
    else
        info "No crontab entries found"
    fi
}

# Backup filesystem table
backup_fstab() {
    info "Backing up fstab and mount information..."

    if [[ -f /etc/fstab ]]; then
        cp /etc/fstab "$TEMP_DIR/fstab.backup"
        success "fstab backed up"
    fi

    mount > "$TEMP_DIR/mounts.txt" 2>/dev/null || true
}

# Backup GRUB configuration
backup_grub() {
    info "Backing up GRUB configuration..."

    mkdir -p "$TEMP_DIR/grub"
    if [[ -f /etc/default/grub ]]; then
        cp /etc/default/grub "$TEMP_DIR/grub/"
    fi

    if [[ -d /etc/grub.d ]]; then
        cp -r /etc/grub.d "$TEMP_DIR/grub/"
    fi

    success "GRUB configuration backed up"
}

# Create backup archive
create_archive() {
    BACKUP_FILE="${BACKUP_DEST}/config-backup-${BACKUP_DATE}.tar.gz"

    info "Creating archive: $BACKUP_FILE"

    if tar -czf "$BACKUP_FILE" -C "$TEMP_DIR" . 2>/dev/null; then
        local size=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
        success "Backup archive created: $size"
    else
        error "Failed to create backup archive"
        return 1
    fi
}

# Verify archive
verify_archive() {
    info "Verifying backup archive..."

    if tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
        local file_count=$(tar -tzf "$BACKUP_FILE" | wc -l)
        success "Archive verified: $file_count items"

        # Create manifest
        {
            echo "Configuration Backup Manifest"
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "RHEL Version: $RHEL_VERSION"
            echo "File count: $file_count"
            echo ""
            echo "Archive contents:"
            tar -tzf "$BACKUP_FILE" | head -20
        } > "${BACKUP_FILE}.manifest"
        success "Manifest created"
    else
        error "Archive verification failed"
        return 1
    fi
}

# Create checksum
create_checksum() {
    if [[ -f "$BACKUP_FILE" ]]; then
        md5sum "$BACKUP_FILE" > "${BACKUP_FILE}.md5"
        success "Checksum created"
    fi
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel
    validate_destination

    {
        info "=== Configuration Backup Manager ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        create_temp_dir
        echo ""

        collect_configs
        echo ""

        backup_firewall
        backup_network
        backup_crontabs
        backup_fstab
        backup_grub
        echo ""

        if [[ $INCLUDE_RPM_LIST -eq 1 ]]; then
            generate_rpm_list
            echo ""
        fi

        create_archive
        echo ""

        verify_archive
        echo ""

        create_checksum
        echo ""

        success "Configuration backup complete: $BACKUP_FILE"
    }
}

main "$@"
