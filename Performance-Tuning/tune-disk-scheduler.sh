#!/bin/bash

################################################################################
# Script: tune-disk-scheduler.sh
# Description: Sets I/O scheduler per device, auto-tunes based on type
# Usage: ./tune-disk-scheduler.sh [--device sda] [--scheduler bfq] [--auto]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, lsblk or fdisk
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
DEVICE=""
SCHEDULER=""
AUTO_MODE=0
RHEL_VERSION=""
SYSFS_PATH="/sys/block"
PERSIST_DIR="/etc/udev/rules.d"

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device) DEVICE="$2"; shift ;;
            --scheduler) SCHEDULER="$2"; shift ;;
            --auto) AUTO_MODE=1 ;;
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

# List available block devices
list_devices() {
    info "Available block devices:"
    echo ""

    if command -v lsblk &> /dev/null; then
        lsblk -d -n -o NAME,SIZE,TYPE | grep -E "^sd|^vd|^nvme|^mmc" | awk '{print "  " $0}'
    else
        ls -la /sys/block | grep -E "^d" | awk '{print "  " $9}' | grep -E "^sd|^vd|^nvme|^mmc"
    fi

    echo ""
}

# Check device existence
check_device_exists() {
    if [[ -z "$DEVICE" ]]; then
        error "Device is required (use --device)"
        list_devices
        exit 1
    fi

    # Normalize device name (remove /dev/ prefix if present)
    DEVICE=$(basename "$DEVICE")

    if [[ ! -b "/dev/$DEVICE" ]]; then
        error "Block device not found: /dev/$DEVICE"
        list_devices
        exit 1
    fi

    success "Device found: /dev/$DEVICE"
}

# Detect device type (SSD vs HDD)
detect_device_type() {
    local device_path="$SYSFS_PATH/$DEVICE"

    if [[ -f "$device_path/queue/rotational" ]]; then
        local rotational=$(cat "$device_path/queue/rotational")
        if [[ $rotational -eq 0 ]]; then
            echo "SSD"
        else
            echo "HDD"
        fi
    else
        echo "UNKNOWN"
    fi
}

# Get recommended scheduler
get_recommended_scheduler() {
    local device_type="$1"

    case "$device_type" in
        SSD)
            echo "none"
            ;;
        HDD)
            # Check available schedulers
            if scheduler_available "bfq"; then
                echo "bfq"
            elif scheduler_available "deadline"; then
                echo "deadline"
            else
                echo "cfq"
            fi
            ;;
        *)
            echo "mq-deadline"
            ;;
    esac
}

# Check if scheduler is available
scheduler_available() {
    local sched="$1"
    local device_path="$SYSFS_PATH/$DEVICE"

    if [[ -f "$device_path/queue/scheduler" ]]; then
        grep -q "$sched" "$device_path/queue/scheduler"
    fi
}

# Get current scheduler
get_current_scheduler() {
    local device_path="$SYSFS_PATH/$DEVICE"

    if [[ -f "$device_path/queue/scheduler" ]]; then
        grep -oP '\[\K[^\]]+' "$device_path/queue/scheduler" || echo "unknown"
    else
        echo "unknown"
    fi
}

# List available schedulers
list_available_schedulers() {
    local device_path="$SYSFS_PATH/$DEVICE"

    if [[ -f "$device_path/queue/scheduler" ]]; then
        echo "Available schedulers:"
        cat "$device_path/queue/scheduler" | sed 's/\[//g; s/\]//g' | awk '{for (i=1; i<=NF; i++) print "  " $i}'
    else
        warn "Cannot determine available schedulers"
    fi
}

# Set scheduler for device
set_scheduler() {
    local device_path="$SYSFS_PATH/$DEVICE"
    local scheduler_file="$device_path/queue/scheduler"

    if [[ ! -f "$scheduler_file" ]]; then
        error "Scheduler file not found: $scheduler_file"
        return 1
    fi

    if ! scheduler_available "$SCHEDULER"; then
        error "Scheduler not available: $SCHEDULER"
        list_available_schedulers
        return 1
    fi

    info "Setting scheduler to: $SCHEDULER"

    if echo "$SCHEDULER" > "$scheduler_file"; then
        success "Scheduler changed to: $SCHEDULER"
        return 0
    else
        error "Failed to set scheduler"
        return 1
    fi
}

# Persist scheduler setting via udev
persist_scheduler() {
    mkdir -p "$PERSIST_DIR"

    local rule_file="${PERSIST_DIR}/60-disk-scheduler.rules"

    info "Persisting scheduler setting..."

    if [[ ! -f "$rule_file" ]]; then
        cat > "$rule_file" << 'EOF'
# Disk I/O scheduler rules
# Generated by tune-disk-scheduler.sh

ACTION=="add|change", KERNEL=="sd*|vd*|nvme*", \
  ATTR{queue/scheduler}="bfq"
EOF
    fi

    # Check if device rule already exists
    if ! grep -q "KERNEL==\".*$DEVICE" "$rule_file"; then
        cat >> "$rule_file" << EOF

# Specific rule for $DEVICE
ACTION=="add|change", KERNEL=="$DEVICE", \
  ATTR{queue/scheduler}="$SCHEDULER"
EOF
    fi

    success "Rule added to: $rule_file"
}

# Get scheduler statistics
show_scheduler_stats() {
    echo ""
    info "Scheduler Statistics:"
    echo ""

    local device_path="$SYSFS_PATH/$DEVICE"

    if [[ -d "$device_path/queue" ]]; then
        local read_ahead=$(cat "$device_path/queue/read_ahead_kb" 2>/dev/null || echo "N/A")
        local nr_requests=$(cat "$device_path/queue/nr_requests" 2>/dev/null || echo "N/A")
        local max_sectors=$(cat "$device_path/queue/max_sectors_kb" 2>/dev/null || echo "N/A")

        info "  Read-ahead: ${read_ahead}KB"
        info "  Nr Requests: $nr_requests"
        info "  Max Sectors: ${max_sectors}KB"
    fi
}

# Show device recommendations
show_recommendations() {
    echo ""
    info "Device Recommendations:"
    echo ""

    local device_type=$(detect_device_type)
    local recommended=$(get_recommended_scheduler "$device_type")

    info "  Device Type: $device_type"
    success "  Recommended Scheduler: $recommended"

    if [[ "$device_type" == "SSD" ]]; then
        info "  Reason: SSDs have no seek penalty, 'none' scheduler minimizes overhead"
    elif [[ "$device_type" == "HDD" ]]; then
        info "  Reason: HDDs benefit from I/O scheduling to reduce seeks"
    fi
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel

    {
        info "=== Disk I/O Scheduler Tuning ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        if [[ -z "$DEVICE" && $AUTO_MODE -eq 0 ]]; then
            list_devices
            show_recommendations
            exit 0
        fi

        check_device_exists
        echo ""

        # Get current settings
        local current_scheduler=$(get_current_scheduler)
        success "Current scheduler: $current_scheduler"

        list_available_schedulers
        echo ""

        if [[ $AUTO_MODE -eq 1 ]]; then
            local device_type=$(detect_device_type)
            SCHEDULER=$(get_recommended_scheduler "$device_type")
            info "Auto-tuning for device type: $device_type"
            echo ""
        fi

        if [[ -n "$SCHEDULER" ]]; then
            set_scheduler
            echo ""
            persist_scheduler
            echo ""
            show_scheduler_stats
        fi

        show_recommendations
    }
}

main "$@"
