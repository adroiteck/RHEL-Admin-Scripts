#!/bin/bash

################################################################################
# Script: extend-lvm.sh
# Description: Extends a logical volume and resizes the filesystem.
#              Supports ext4 and xfs filesystems with validation of free space.
# Usage: extend-lvm.sh --lv /dev/vg0/data --size +10G
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8 with lvm2 installed
# Version: 1.0
################################################################################

set -euo pipefail

# Color output functions
info() {
    echo -e "\033[0;36m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

error() {
    echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $*"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Parse arguments
LV_PATH=""
SIZE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --lv) LV_PATH="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate arguments
if [[ -z "$LV_PATH" || -z "$SIZE" ]]; then
    error "Missing required arguments: --lv and --size"
    echo "Usage: $0 --lv /dev/vg0/data --size +10G"
    exit 1
fi

check_root
detect_rhel_version

info "Extending LV: $LV_PATH with size: $SIZE"

# Verify LV exists
if ! lvdisplay "$LV_PATH" &>/dev/null; then
    error "Logical volume not found: $LV_PATH"
    exit 1
fi

# Extract VG name from LV path
VG_NAME=$(echo "$LV_PATH" | awk -F/ '{print $(NF-1)}')
LV_NAME=$(echo "$LV_PATH" | awk -F/ '{print $NF}')

# Get current VG free space
VG_FREE=$(vgs -o vg_free --noheadings --units M "$VG_NAME" 2>/dev/null | xargs)
info "Current free space in VG $VG_NAME: $VG_FREE"

# Find mount point
MOUNT_POINT=$(lsblk -no MOUNTPOINT "$LV_PATH" 2>/dev/null | head -1)
if [[ -z "$MOUNT_POINT" ]]; then
    error "Logical volume is not mounted: $LV_PATH"
    exit 1
fi

info "LV is mounted at: $MOUNT_POINT"

# Detect filesystem type
FS_TYPE=$(df -T "$MOUNT_POINT" | tail -1 | awk '{print $2}')
info "Filesystem type: $FS_TYPE"

if [[ ! "$FS_TYPE" =~ ^(ext4|xfs)$ ]]; then
    error "Unsupported filesystem: $FS_TYPE (only ext4 and xfs are supported)"
    exit 1
fi

# Verify requested size is available
if [[ "$SIZE" == +* ]]; then
    SIZE_NUM=$(echo "$SIZE" | sed 's/[^0-9]//g')
    SIZE_UNIT=$(echo "$SIZE" | sed 's/[0-9]//g')
    case "$SIZE_UNIT" in
        G) SIZE_NUM=$((SIZE_NUM * 1024)) ;;
        M) ;;
        T) SIZE_NUM=$((SIZE_NUM * 1024 * 1024)) ;;
        *) error "Invalid size unit: $SIZE_UNIT"; exit 1 ;;
    esac

    VG_FREE_NUM=$(echo "$VG_FREE" | sed 's/[^0-9.]//g')
    if (( $(echo "$SIZE_NUM > $VG_FREE_NUM" | bc -l) )); then
        error "Insufficient free space: need ${SIZE_NUM}M, available ${VG_FREE_NUM}M"
        exit 1
    fi
fi

info "Extending logical volume..."
if ! lvextend -L "$SIZE" "$LV_PATH"; then
    error "Failed to extend logical volume"
    exit 1
fi

success "Logical volume extended successfully"

# Resize filesystem
info "Resizing filesystem ($FS_TYPE)..."

case "$FS_TYPE" in
    ext4)
        if ! resize2fs "$LV_PATH"; then
            error "Failed to resize ext4 filesystem"
            exit 1
        fi
        ;;
    xfs)
        if ! xfs_growfs "$MOUNT_POINT"; then
            error "Failed to grow xfs filesystem"
            exit 1
        fi
        ;;
esac

success "Filesystem resized successfully"

# Verify the changes
NEW_SIZE=$(lsblk -no SIZE "$LV_PATH" | head -1)
FS_SIZE=$(df -h "$MOUNT_POINT" | tail -1 | awk '{print $2}')

info "LV new size: $NEW_SIZE"
info "Mounted filesystem size: $FS_SIZE"

success "LV extension completed successfully"
