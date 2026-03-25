#!/bin/bash

################################################################################
# Script: create-lvm-snapshot.sh
# Description: Creates LVM snapshots for backup purposes with optional
#              automatic removal after specified duration.
# Usage: create-lvm-snapshot.sh --lv /dev/vg0/data --size 5G --name backup_snap
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
SNAP_SIZE=""
SNAP_NAME=""
AUTO_REMOVE_HOURS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --lv) LV_PATH="$2"; shift 2 ;;
        --size) SNAP_SIZE="$2"; shift 2 ;;
        --name) SNAP_NAME="$2"; shift 2 ;;
        --auto-remove) AUTO_REMOVE_HOURS="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate arguments
if [[ -z "$LV_PATH" || -z "$SNAP_SIZE" || -z "$SNAP_NAME" ]]; then
    error "Missing required arguments: --lv, --size, and --name"
    echo "Usage: $0 --lv /dev/vg0/data --size 5G --name backup_snap [--auto-remove 24]"
    exit 1
fi

check_root
detect_rhel_version

info "Creating LVM snapshot for: $LV_PATH"

# Verify LV exists
if ! lvdisplay "$LV_PATH" &>/dev/null; then
    error "Logical volume not found: $LV_PATH"
    exit 1
fi

# Extract VG name from LV path
VG_NAME=$(echo "$LV_PATH" | awk -F/ '{print $(NF-1)}')
LV_NAME=$(echo "$LV_PATH" | awk -F/ '{print $NF}')

# Check if snapshot already exists
SNAP_LV="/dev/$VG_NAME/$SNAP_NAME"
if lvdisplay "$SNAP_LV" &>/dev/null; then
    error "Snapshot already exists: $SNAP_LV"
    exit 1
fi

# Get current VG free space
VG_FREE=$(vgs -o vg_free --noheadings --units M "$VG_NAME" 2>/dev/null | xargs)
VG_FREE_NUM=$(echo "$VG_FREE" | sed 's/[^0-9.]//g')

# Parse snapshot size
SNAP_SIZE_NUM=$(echo "$SNAP_SIZE" | sed 's/[^0-9]//g')
SNAP_SIZE_UNIT=$(echo "$SNAP_SIZE" | sed 's/[0-9]//g')

case "$SNAP_SIZE_UNIT" in
    G) SNAP_SIZE_NUM=$((SNAP_SIZE_NUM * 1024)) ;;
    M) ;;
    T) SNAP_SIZE_NUM=$((SNAP_SIZE_NUM * 1024 * 1024)) ;;
    *) error "Invalid size unit: $SNAP_SIZE_UNIT"; exit 1 ;;
esac

info "VG free space: $VG_FREE (need ${SNAP_SIZE_NUM}M)"

# Validate sufficient space
if (( $(echo "$SNAP_SIZE_NUM > $VG_FREE_NUM" | bc -l) )); then
    error "Insufficient free space: need ${SNAP_SIZE_NUM}M, available ${VG_FREE_NUM}M"
    exit 1
fi

# Create snapshot
info "Creating snapshot: $SNAP_NAME with size: $SNAP_SIZE"
if ! lvcreate -L "$SNAP_SIZE" -s -n "$SNAP_NAME" "$LV_PATH"; then
    error "Failed to create snapshot"
    exit 1
fi

success "Snapshot created successfully: $SNAP_LV"

# Display snapshot details
info "Snapshot Details:"
lvdisplay "$SNAP_LV" | grep -E "LV Name|LV Size|Snapshot"

# Setup automatic removal if requested
if [[ $AUTO_REMOVE_HOURS -gt 0 ]]; then
    REMOVAL_TIME=$((AUTO_REMOVE_HOURS * 3600))

    # Create a removal script
    REMOVAL_SCRIPT="/tmp/remove_snapshot_${SNAP_NAME}.sh"
    cat > "$REMOVAL_SCRIPT" << 'SCRIPT'
#!/bin/bash
LV_PATH="$1"
SNAP_NAME="$2"
VG_NAME="${LV_PATH%/*}"
VG_NAME="${VG_NAME##*/}"
SNAP_LV="/dev/$VG_NAME/$SNAP_NAME"

sleep "$3"

if lvdisplay "$SNAP_LV" &>/dev/null; then
    echo "Removing snapshot: $SNAP_LV"
    lvremove -f "$SNAP_LV" || echo "Failed to remove snapshot"
fi
SCRIPT

    chmod +x "$REMOVAL_SCRIPT"

    info "Scheduling snapshot removal in $AUTO_REMOVE_HOURS hours"
    nohup "$REMOVAL_SCRIPT" "$LV_PATH" "$SNAP_NAME" "$REMOVAL_TIME" > /dev/null 2>&1 &
    success "Auto-removal scheduled (PID: $!)"
fi

info "Snapshot ready for backup operations"
