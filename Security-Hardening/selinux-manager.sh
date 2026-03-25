#!/bin/bash

################################################################################
# Script: selinux-manager.sh
# Description: Manages SELinux configuration including mode changes, boolean
#              management, and AVC denial troubleshooting. RHEL 7/8/9 compatible.
# Usage: selinux-manager.sh --action status
#        selinux-manager.sh --action set-mode --mode enforcing
#        selinux-manager.sh --action troubleshoot [--count 10]
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

# Check if SELinux is installed
check_selinux_installed() {
    if ! command -v getenforce &> /dev/null; then
        error "SELinux tools not installed"
        exit 1
    fi
}

# Show SELinux status
show_status() {
    echo ""
    echo "================================ SELINUX STATUS ================================"

    info "Current mode: $(getenforce)"
    info "Default mode: $(grep '^SELINUX=' /etc/selinux/config | cut -d'=' -f2)"
    info "Policy type: $(grep '^SELINUXTYPE=' /etc/selinux/config | cut -d'=' -f2)"

    echo ""
    info "SELinux file contexts:"
    ls -Z / | head -5

    echo ""
    success "SELinux status retrieved"
}

# Set SELinux mode
set_mode() {
    local mode=$1

    if [[ ! "$mode" =~ ^(enforcing|permissive|disabled)$ ]]; then
        error "Invalid mode: $mode (must be enforcing, permissive, or disabled)"
        exit 1
    fi

    info "Setting SELinux mode to: $mode"

    # Set current mode (requires selinux to be active)
    current=$(getenforce)
    if [[ "$current" != "disabled" ]]; then
        if ! setenforce "$mode"; then
            error "Failed to set current mode to $mode"
            exit 1
        fi
        success "Current mode set to: $mode"
    fi

    # Set default mode in config
    if grep -q "^SELINUX=" /etc/selinux/config; then
        sed -i "s/^SELINUX=.*/SELINUX=$mode/" /etc/selinux/config
    else
        echo "SELINUX=$mode" >> /etc/selinux/config
    fi

    info "Default mode set to: $mode (requires reboot to take effect if disabled)"
    show_status
}

# Manage SELinux booleans
manage_booleans() {
    local action=$1
    local boolean=$2
    local value=$3

    if [[ "$action" == "list" ]]; then
        echo ""
        echo "================================ SELINUX BOOLEANS ================================"
        getsebool -a
    elif [[ "$action" == "set" ]]; then
        if [[ -z "$boolean" || -z "$value" ]]; then
            error "Boolean and value required for set action"
            exit 1
        fi

        if [[ ! "$value" =~ ^(on|off)$ ]]; then
            error "Invalid value: $value (must be on or off)"
            exit 1
        fi

        info "Setting SELinux boolean: $boolean=$value"

        if ! setsebool -P "$boolean" "$value"; then
            error "Failed to set boolean: $boolean"
            exit 1
        fi

        success "Boolean $boolean set to: $value"
    fi
}

# Troubleshoot AVC denials
troubleshoot_avc() {
    local count=$1

    if [[ ! -f /var/log/audit/audit.log ]]; then
        error "Audit log not found: /var/log/audit/audit.log"
        return 1
    fi

    echo ""
    echo "================================ SELINUX AVC DENIALS ================================"

    # Check for recent AVC denials
    recent_denials=$(ausearch -m avc -ts recent 2>/dev/null | wc -l)
    info "Recent AVC denials found: $recent_denials"

    if [[ $recent_denials -gt 0 ]]; then
        echo ""
        echo "Last $count AVC denials:"
        ausearch -m avc -ts recent 2>/dev/null | tail -n "$count"

        echo ""
        echo "Suggested fixes using audit2allow:"
        ausearch -m avc -ts recent 2>/dev/null | audit2allow -a -M selinux_custom 2>/dev/null || \
            warn "audit2allow not available or no denials to process"

        if [[ -f selinux_custom.pp ]]; then
            info "Module generated: selinux_custom.pp"
            info "To apply: semodule -i selinux_custom.pp"
        fi
    else
        success "No recent AVC denials found"
    fi
}

# Parse arguments
ACTION=""
MODE=""
BOOL_ACTION=""
BOOLEAN=""
BOOL_VALUE=""
AVC_COUNT=10

while [[ $# -gt 0 ]]; do
    case $1 in
        --action) ACTION="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --bool-action) BOOL_ACTION="$2"; shift 2 ;;
        --boolean) BOOLEAN="$2"; shift 2 ;;
        --value) BOOL_VALUE="$2"; shift 2 ;;
        --count) AVC_COUNT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    error "Missing required argument: --action"
    echo "Usage: $0 --action [status|set-mode|booleans|troubleshoot]"
    exit 1
fi

check_root
detect_rhel_version
check_selinux_installed

case "$ACTION" in
    status)
        show_status
        ;;
    set-mode)
        if [[ -z "$MODE" ]]; then
            error "Missing argument: --mode"
            exit 1
        fi
        set_mode "$MODE"
        ;;
    booleans)
        if [[ -z "$BOOL_ACTION" ]]; then
            BOOL_ACTION="list"
        fi
        manage_booleans "$BOOL_ACTION" "$BOOLEAN" "$BOOL_VALUE"
        ;;
    troubleshoot)
        troubleshoot_avc "$AVC_COUNT"
        ;;
    *)
        error "Unknown action: $ACTION"
        exit 1
        ;;
esac
