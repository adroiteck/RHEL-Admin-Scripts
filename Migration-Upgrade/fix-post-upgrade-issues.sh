#!/bin/bash

################################################################################
# fix-post-upgrade-issues.sh - Fix Common Post-Upgrade Issues
################################################################################
# Description: Fixes common issues that occur after RHEL in-place upgrade.
#              Reinstalls packages, re-enables services, and fixes configuration.
# Usage: ./fix-post-upgrade-issues.sh [--pre-state-dir DIR] [--auto-fix] [--dry-run]
# Author: Migration Team
# Compatibility: RHEL 8.x, RHEL 9.x
################################################################################

set -euo pipefail

PRE_STATE_DIR=""
AUTO_FIX=0
DRY_RUN=0

################################################################################
# Color Output Functions
################################################################################

info() {
    echo -e "\033[0;36m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[0;33m[WARN]\033[0m $*"
}

error() {
    echo -e "\033[0;31m[ERROR]\033[0m $*"
}

success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $*"
}

################################################################################
# Root Privilege Check
################################################################################

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

################################################################################
# Fix Functions
################################################################################

fix_missing_packages() {
    info "Checking for missing packages..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -f "$PRE_STATE_DIR/installed-packages.txt" ]]; then
        warn "Pre-upgrade package list not available, skipping package restoration"
        return 0
    fi
    
    local pre_packages="$PRE_STATE_DIR/installed-packages.txt"
    local post_packages="/tmp/post-packages.txt"
    
    rpm -qa | sort > "$post_packages"
    
    local missing_packages
    missing_packages=$(comm -23 "$pre_packages" "$post_packages" | wc -l)
    
    if [[ $missing_packages -eq 0 ]]; then
        success "No missing packages detected"
        return 0
    fi
    
    warn "Found $missing_packages missing packages"
    
    if [[ $AUTO_FIX -eq 0 ]]; then
        info "Use --auto-fix to restore missing packages"
        return 0
    fi
    
    info "Reinstalling missing packages..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would reinstall $(comm -23 "$pre_packages" "$post_packages" | wc -l) packages"
        return 0
    fi
    
    local failed=0
    while IFS= read -r package; do
        [[ -z "$package" ]] && continue
        
        if dnf install -y "$package" &> /dev/null; then
            success "Restored package: $package"
        else
            warn "Failed to restore package: $package"
            ((failed++))
        fi
    done < <(comm -23 "$pre_packages" "$post_packages" | head -50)
    
    if [[ $failed -gt 0 ]]; then
        warn "$failed packages failed to restore"
        return 1
    fi
    
    success "Package restoration completed"
    return 0
}

fix_stopped_services() {
    info "Checking for stopped services that should be running..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -f "$PRE_STATE_DIR/systemctl-enabled-services.txt" ]]; then
        warn "Pre-upgrade service list not available"
        return 0
    fi
    
    local services_to_check
    services_to_check=$(grep "enabled" "$PRE_STATE_DIR/systemctl-list-unit-files.txt" 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | head -30)
    
    local stopped_services=0
    
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        
        if ! systemctl is-active "$service" &> /dev/null; then
            warn "Service $service is not running (expected to be)"
            stopped_services=$((stopped_services + 1))
            
            if [[ $AUTO_FIX -eq 1 && $DRY_RUN -eq 0 ]]; then
                info "Starting service: $service"
                systemctl start "$service" || warn "Failed to start $service"
            fi
        fi
    done <<< "$services_to_check"
    
    if [[ $stopped_services -gt 0 ]]; then
        warn "Found $stopped_services stopped services"
    else
        success "All critical services are running"
    fi
    
    return 0
}

fix_selinux_relabeling() {
    info "Checking SELinux configuration..."
    
    if ! command -v getenforce &> /dev/null; then
        info "SELinux not available, skipping relabeling"
        return 0
    fi
    
    local selinux_status
    selinux_status=$(getenforce)
    
    if [[ "$selinux_status" != "Enforcing" ]]; then
        info "SELinux not in Enforcing mode ($selinux_status)"
        return 0
    fi
    
    info "Running SELinux file relabeling..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would run restorecon -Rv / (this is comprehensive, may take time)"
        return 0
    fi
    
    if [[ $AUTO_FIX -eq 1 ]]; then
        # Restore SELinux contexts for critical directories
        local critical_dirs=("/root" "/etc" "/var" "/home" "/usr/local")
        
        for dir in "${critical_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                info "Restoring SELinux context for $dir..."
                restorecon -Rv "$dir" 2>/dev/null || warn "Failed to relabel $dir"
            fi
        done
        
        success "SELinux relabeling completed"
    else
        info "Use --auto-fix to run SELinux relabeling"
    fi
    
    return 0
}

fix_network_interface_names() {
    info "Checking for network interface naming changes..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -f "$PRE_STATE_DIR/network-config.txt" ]]; then
        warn "Pre-upgrade network configuration not available"
        return 0
    fi
    
    # Extract interface names from pre-upgrade config
    local pre_interfaces
    pre_interfaces=$(grep "^[0-9]:" "$PRE_STATE_DIR/network-config.txt" | awk '{print $2}' | sed 's/:$//' | sort)
    
    local current_interfaces
    current_interfaces=$(ip link show | grep "^[0-9]:" | awk '{print $2}' | sed 's/:$//' | sort)
    
    if [[ "$pre_interfaces" != "$current_interfaces" ]]; then
        warn "Network interface names have changed!"
        info "Pre-upgrade interfaces: $pre_interfaces"
        info "Current interfaces: $current_interfaces"
        
        if [[ $AUTO_FIX -eq 1 && $DRY_RUN -eq 0 ]]; then
            warn "Manual network reconfiguration may be required"
            warn "Review /etc/sysconfig/network-scripts/ or NetworkManager configuration"
        fi
    else
        success "Network interface names unchanged"
    fi
    
    return 0
}

rebuild_initramfs() {
    info "Checking if initramfs needs rebuilding..."
    
    if ! command -v dracut &> /dev/null; then
        warn "dracut not found, cannot rebuild initramfs"
        return 0
    fi
    
    info "Initramfs status:"
    uname -r
    
    if [[ $AUTO_FIX -eq 0 ]]; then
        info "Use --auto-fix to rebuild initramfs if needed"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would run dracut -f"
        return 0
    fi
    
    info "Rebuilding initramfs..."
    if dracut -f; then
        success "Initramfs rebuilt successfully"
    else
        warn "Failed to rebuild initramfs"
        return 1
    fi
    
    return 0
}

clear_package_caches() {
    info "Clearing package caches..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would clear dnf/yum caches"
        return 0
    fi
    
    if command -v dnf &> /dev/null; then
        dnf clean all &> /dev/null && success "DNF cache cleared"
    fi
    
    if command -v yum &> /dev/null; then
        yum clean all &> /dev/null && success "YUM cache cleared"
    fi
    
    return 0
}

remove_leapp_artifacts() {
    info "Removing Leapp upgrade artifacts..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would remove Leapp artifacts from /var/log/leapp and /root/tmp_leapp_py3"
        return 0
    fi
    
    if [[ ! -d /var/log/leapp ]]; then
        info "Leapp logs directory not found"
    else
        info "Removing /var/log/leapp..."
        rm -rf /var/log/leapp || warn "Failed to remove Leapp logs"
    fi
    
    if [[ ! -d /root/tmp_leapp_py3 ]]; then
        info "Leapp temp directory not found"
    else
        info "Removing /root/tmp_leapp_py3..."
        rm -rf /root/tmp_leapp_py3 || warn "Failed to remove Leapp temp files"
    fi
    
    success "Leapp artifacts removed"
    return 0
}

reregister_subscription() {
    info "Checking subscription registration..."
    
    if ! command -v subscription-manager &> /dev/null; then
        info "subscription-manager not available"
        return 0
    fi
    
    if subscription-manager identity &> /dev/null; then
        success "System is already registered"
        return 0
    fi
    
    warn "System is not registered with subscription manager"
    info "Manual registration required: subscription-manager register"
    
    return 1
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    --pre-state-dir DIR     Directory with pre-upgrade system state
    --auto-fix              Automatically fix detected issues
    --dry-run               Show what would be done without making changes
    --help                  Show this help message

EXAMPLES:
    $0
    $0 --pre-state-dir /var/log/migration/pre-upgrade-20240315 --auto-fix
    $0 --pre-state-dir /var/log/migration/pre-upgrade-20240315 --dry-run

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pre-state-dir)
                PRE_STATE_DIR="$2"
                shift 2
                ;;
            --auto-fix)
                AUTO_FIX=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

################################################################################
# Main Execution
################################################################################

main() {
    parse_arguments "$@"
    check_root
    
    info "Post-upgrade issue fix utility"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "DRY-RUN MODE: No changes will be made"
        echo ""
    fi
    
    fix_missing_packages
    fix_stopped_services
    fix_selinux_relabeling
    fix_network_interface_names
    rebuild_initramfs
    clear_package_caches
    remove_leapp_artifacts
    reregister_subscription
    
    echo ""
    success "Post-upgrade issue check completed"
}

main "$@"
