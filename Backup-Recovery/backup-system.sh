#!/bin/bash

################################################################################
# Script: backup-system.sh
# Description: Full or incremental system backup using tar
# Usage: ./backup-system.sh --dest /backup [--type full] [--retention 7]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, tar, rsync (optional for NFS)
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
BACKUP_DEST=""
BACKUP_TYPE="full"
EXCLUDE_PATHS=("/proc" "/sys" "/dev" "/tmp" "/run" "/mnt" "/media" "/var/cache")
CUSTOM_EXCLUDES=""
RETENTION_DAYS=7
RHEL_VERSION=""
MANIFEST_FILE=""
BACKUP_FILE=""
BACKUP_DATE=$(date '+%Y%m%d-%H%M%S')

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) BACKUP_DEST="$2"; shift ;;
            --type) BACKUP_TYPE="$2"; shift ;;
            --exclude) CUSTOM_EXCLUDES="$2"; shift ;;
            --retention) RETENTION_DAYS="$2"; shift ;;
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

# Check available space
check_space() {
    local root_usage=$(du -sb / 2>/dev/null | awk '{print $1}' | head -1)
    local available=$(df "$BACKUP_DEST" | tail -1 | awk '{print $4*1024}')
    local required=$((root_usage + (root_usage / 10)))

    info "Root filesystem usage: $(numfmt --to=iec-i --suffix=B $root_usage 2>/dev/null || echo $root_usage)"
    info "Available space at destination: $(numfmt --to=iec-i --suffix=B $available 2>/dev/null || echo $available)"

    if [[ $available -lt $required ]]; then
        error "Insufficient space. Required: ~$(numfmt --to=iec-i --suffix=B $required 2>/dev/null || echo $required)"
        exit 1
    fi

    success "Space check passed"
}

# Create exclude list
build_exclude_list() {
    local exclude_file="${BACKUP_DEST}/.exclude_list.txt"

    {
        for path in "${EXCLUDE_PATHS[@]}"; do
            echo "$path"
        done

        if [[ -n "$CUSTOM_EXCLUDES" ]]; then
            echo "$CUSTOM_EXCLUDES"
        fi
    } > "$exclude_file"

    info "Exclude list created: $exclude_file"
}

# Perform backup
perform_backup() {
    BACKUP_FILE="${BACKUP_DEST}/system-${BACKUP_TYPE}-${BACKUP_DATE}.tar.gz"
    MANIFEST_FILE="${BACKUP_DEST}/system-${BACKUP_TYPE}-${BACKUP_DATE}.manifest"

    info "Starting $BACKUP_TYPE backup to: $BACKUP_FILE"

    local exclude_file="${BACKUP_DEST}/.exclude_list.txt"
    local tar_opts="--gzip --verbose --one-file-system"

    if [[ "$BACKUP_TYPE" == "incremental" ]]; then
        tar_opts="$tar_opts --listed-incremental=${BACKUP_DEST}/.snar"
    fi

    # Create backup with manifset
    if tar $tar_opts --exclude-from="$exclude_file" \
        -C / -f "$BACKUP_FILE" \
        --exclude=".exclude_list.txt" \
        --exclude=".snar" \
        . 2>&1 | tee -a "$MANIFEST_FILE"; then
        success "Backup completed: $BACKUP_FILE"
    else
        error "Backup failed"
        return 1
    fi
}

# Verify backup integrity
verify_backup() {
    if [[ ! -f "$BACKUP_FILE" ]]; then
        error "Backup file not found: $BACKUP_FILE"
        return 1
    fi

    info "Verifying backup integrity..."

    if tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
        local file_count=$(tar -tzf "$BACKUP_FILE" | wc -l)
        local size=$(du -sh "$BACKUP_FILE" | awk '{print $1}')

        success "Backup verified: $file_count files, size: $size"
        echo "File count: $file_count" >> "$MANIFEST_FILE"
        echo "Size: $size" >> "$MANIFEST_FILE"
        return 0
    else
        error "Backup verification failed"
        return 1
    fi
}

# Rotate old backups
rotate_backups() {
    info "Rotating backups older than $RETENTION_DAYS days..."

    local count=0
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            local base=$(basename "$file")
            rm -f "${BACKUP_DEST}/${base%.*}.manifest"
            rm -f "${BACKUP_DEST}/${base%.*}.md5"
            count=$((count + 1))
        fi
    done < <(find "$BACKUP_DEST" -maxdepth 1 -name "system-*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        success "Removed $count old backup(s)"
    else
        info "No old backups to remove"
    fi
}

# Create backup checksum
create_checksum() {
    if [[ -f "$BACKUP_FILE" ]]; then
        info "Creating checksum..."
        md5sum "$BACKUP_FILE" > "${BACKUP_FILE}.md5"
        success "Checksum created"
    fi
}

# List backups
list_backups() {
    info "Available backups:"
    echo ""
    ls -lh "${BACKUP_DEST}"/system-*.tar.gz 2>/dev/null | awk '{print $9, "(" $5 ")"}' || warn "No backups found"
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel
    validate_destination

    {
        info "=== System Backup Manager ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Backup type: $BACKUP_TYPE"
        info "Retention: $RETENTION_DAYS days"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        check_space
        echo ""

        build_exclude_list
        echo ""

        perform_backup
        echo ""

        verify_backup
        echo ""

        create_checksum
        echo ""

        rotate_backups
        echo ""

        list_backups
    }
}

main "$@"
