#!/bin/bash

################################################################################
# Script: patch-system.sh
# Description: Full system patching with pre-flight checks, LVM snapshots,
#              package updates via yum/dnf, change logging, and optional reboot.
# Usage: ./patch-system.sh [--security-only] [--exclude PKGS] [--reboot]
#        [--dry-run] [--snapshot]
# Author: System Administration Team
# Compatibility: RHEL 7, RHEL 8, RHEL 9
# License: GPL v2
################################################################################

set -euo pipefail

# Color output functions
info() {
    echo -e "\033[36m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[33m[WARN]\033[0m $*" >&2
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $*" >&2
}

success() {
    echo -e "\033[32m[SUCCESS]\033[0m $*"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version and package manager
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        error "Cannot determine RHEL version"
        exit 1
    fi

    if [[ "$RHEL_VERSION" -ge 8 ]]; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi

    info "RHEL $RHEL_VERSION detected, using: $PKG_MANAGER"
}

# Check disk space
check_disk_space() {
    local min_free_mb=500
    local available_mb=$(df /var/cache | awk 'NR==2 {print $4}')

    if [[ $available_mb -lt $min_free_mb ]]; then
        error "Insufficient disk space: ${available_mb}MB available (need ${min_free_mb}MB)"
        return 1
    fi

    info "Disk space check passed: ${available_mb}MB available"
    return 0
}

# Create LVM snapshot
create_lvm_snapshot() {
    local snapshot_size="${1:-1G}"
    local root_mount="/"
    local device=$(df "$root_mount" | awk 'NR==2 {print $1}')

    if [[ ! "$device" =~ /dev/mapper/ ]]; then
        warn "Root filesystem not using LVM, skipping snapshot"
        return 0
    fi

    info "Creating LVM snapshot of size $snapshot_size..."

    local vg_name=$(lvs "$device" -o vg_name --noheadings | xargs)
    local lv_name=$(lvs "$device" -o lv_name --noheadings | xargs)
    local snapshot_name="${lv_name}_patch_snapshot_$(date +%s)"

    if lvcreate -L "$snapshot_size" -s -n "$snapshot_name" "/dev/$vg_name/$lv_name" &>/dev/null; then
        success "Snapshot created: /dev/$vg_name/$snapshot_name"
        echo "/dev/$vg_name/$snapshot_name"
    else
        error "Failed to create LVM snapshot"
        return 1
    fi
}

# Remove LVM snapshot
remove_lvm_snapshot() {
    local snapshot_path="$1"

    if [[ -z "$snapshot_path" ]]; then
        return 0
    fi

    info "Removing snapshot: $snapshot_path"
    lvremove -f "$snapshot_path" &>/dev/null || true
}

# Pre-patch checks
pre_patch_checks() {
    info "Running pre-patch checks..."

    check_disk_space || return 1

    # Check network connectivity
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        warn "Network connectivity check failed (may not be critical)"
    fi

    info "Pre-patch checks completed"
    return 0
}

# Run updates
run_updates() {
    local security_only="$1"
    local exclude="$2"
    local dry_run="$3"
    local update_cmd="$PKG_MANAGER update"

    if [[ "$security_only" == "true" ]]; then
        update_cmd="$PKG_MANAGER update-security"
        info "Running security updates only..."
    else
        info "Running full system updates..."
    fi

    if [[ -n "$exclude" ]]; then
        update_cmd="$update_cmd --exclude=$exclude"
    fi

    if [[ "$dry_run" == "true" ]]; then
        update_cmd="$update_cmd --assumeno"
        info "[DRY-RUN] Would execute: $update_cmd"
        $update_cmd || true
    else
        info "Executing: $update_cmd"
        if $update_cmd -y; then
            success "Updates completed successfully"
        else
            error "Update command failed"
            return 1
        fi
    fi
}

# Check if kernel was updated
kernel_updated() {
    local running_kernel=$(uname -r)
    local latest_kernel=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}\n' 2>/dev/null | head -1 || echo "")

    if [[ -n "$latest_kernel" ]] && [[ "$running_kernel" != "$latest_kernel" ]]; then
        return 0
    fi
    return 1
}

# Log changes
log_changes() {
    local log_file="/var/log/patching-audit.log"

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] PATCH RUN"
        echo "RHEL Version: $RHEL_VERSION"
        echo "Executor: $(whoami)"
        echo "Security Only: $1"
        echo "Kernel Updated: $(kernel_updated && echo 'YES' || echo 'NO')"
        echo "---"
    } >> "$log_file"

    info "Changes logged to: $log_file"
}

# Reboot system
reboot_system() {
    warn "Rebooting system in 60 seconds... (Press Ctrl+C to cancel)"
    sleep 60
    shutdown -r now
}

# Main function
main() {
    check_root
    detect_environment

    local security_only="false"
    local exclude=""
    local reboot="false"
    local dry_run="false"
    local create_snapshot="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --security-only)
                security_only="true"
                shift
                ;;
            --exclude)
                exclude="$2"
                shift 2
                ;;
            --reboot)
                reboot="true"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --snapshot)
                create_snapshot="true"
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    local snapshot_path=""
    if [[ "$create_snapshot" == "true" ]]; then
        snapshot_path=$(create_lvm_snapshot "2G")
    fi

    if ! pre_patch_checks; then
        remove_lvm_snapshot "$snapshot_path"
        exit 1
    fi

    if ! run_updates "$security_only" "$exclude" "$dry_run"; then
        remove_lvm_snapshot "$snapshot_path"
        exit 1
    fi

    log_changes "$security_only"

    if [[ "$reboot" == "true" ]] && kernel_updated; then
        success "Kernel update detected"
        remove_lvm_snapshot "$snapshot_path"
        reboot_system
    else
        remove_lvm_snapshot "$snapshot_path"
        [[ "$kernel_updated" == "true" ]] && warn "Reboot recommended for kernel update"
        success "Patching completed"
    fi
}

main "$@"
