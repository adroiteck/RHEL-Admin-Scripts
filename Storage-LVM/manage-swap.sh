#!/bin/bash

################################################################################
# Script: manage-swap.sh
# Description: Manages system swap configuration including creation, removal,
#              and swappiness settings with persistence to /etc/fstab.
# Usage: manage-swap.sh --action show
#        manage-swap.sh --action add --size 4G
#        manage-swap.sh --action swappiness --value 30
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8
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

# Show current swap configuration
show_swap() {
    echo ""
    echo "================================ SWAP STATUS ================================"
    swapon -s
    echo ""
    info "Total swap space:"
    free -h | grep -i swap
    echo ""
    info "Current swappiness: $(cat /proc/sys/vm/swappiness)"
}

# Add swap file
add_swap() {
    local size=$1
    local swap_file="/swapfile"

    if [[ -f "$swap_file" ]]; then
        error "Swap file already exists: $swap_file"
        exit 1
    fi

    info "Creating swap file: $swap_file with size: $size"

    # Create swap file
    if ! fallocate -l "$size" "$swap_file"; then
        error "Failed to allocate swap file space"
        exit 1
    fi

    # Set permissions
    chmod 600 "$swap_file"
    chown root:root "$swap_file"

    # Format as swap
    if ! mkswap "$swap_file"; then
        error "Failed to format swap file"
        rm -f "$swap_file"
        exit 1
    fi

    # Enable swap
    if ! swapon "$swap_file"; then
        error "Failed to enable swap"
        rm -f "$swap_file"
        exit 1
    fi

    # Add to fstab if not already present
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
        info "Added swap file to /etc/fstab"
    fi

    success "Swap file created and enabled"
    show_swap
}

# Remove swap file
remove_swap() {
    local swap_file="/swapfile"

    if [[ ! -f "$swap_file" ]]; then
        error "Swap file not found: $swap_file"
        exit 1
    fi

    info "Disabling swap: $swap_file"

    # Disable swap
    if ! swapoff "$swap_file"; then
        error "Failed to disable swap"
        exit 1
    fi

    # Remove from fstab
    if grep -q "$swap_file" /etc/fstab; then
        sed -i "\|$swap_file|d" /etc/fstab
        info "Removed swap file from /etc/fstab"
    fi

    # Delete file
    if ! rm -f "$swap_file"; then
        error "Failed to delete swap file"
        exit 1
    fi

    success "Swap file removed"
    show_swap
}

# Set swappiness
set_swappiness() {
    local value=$1

    # Validate value
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ $value -lt 0 ]] || [[ $value -gt 100 ]]; then
        error "Invalid swappiness value: $value (must be 0-100)"
        exit 1
    fi

    info "Setting swappiness to: $value"

    # Set current value
    echo "$value" > /proc/sys/vm/swappiness

    # Persist in sysctl.conf
    if grep -q "^vm.swappiness" /etc/sysctl.conf; then
        sed -i "s/^vm.swappiness.*/vm.swappiness = $value/" /etc/sysctl.conf
    else
        echo "vm.swappiness = $value" >> /etc/sysctl.conf
    fi

    # Apply sysctl settings
    sysctl -p /etc/sysctl.conf > /dev/null

    success "Swappiness set to: $value (persisted to /etc/sysctl.conf)"
    info "Current swappiness: $(cat /proc/sys/vm/swappiness)"
}

# Parse arguments
ACTION=""
SWAP_SIZE=""
SWAPPINESS_VALUE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --action) ACTION="$2"; shift 2 ;;
        --size) SWAP_SIZE="$2"; shift 2 ;;
        --value) SWAPPINESS_VALUE="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    error "Missing required argument: --action"
    echo "Usage: $0 --action [show|add|remove|swappiness]"
    exit 1
fi

check_root
detect_rhel_version

case "$ACTION" in
    show)
        show_swap
        ;;
    add)
        if [[ -z "$SWAP_SIZE" ]]; then
            error "Missing required argument: --size"
            exit 1
        fi
        add_swap "$SWAP_SIZE"
        ;;
    remove)
        remove_swap
        ;;
    swappiness)
        if [[ -z "$SWAPPINESS_VALUE" ]]; then
            error "Missing required argument: --value"
            exit 1
        fi
        set_swappiness "$SWAPPINESS_VALUE"
        ;;
    *)
        error "Unknown action: $ACTION"
        exit 1
        ;;
esac

success "Swap management completed"
