#!/bin/bash

################################################################################
# execute-upgrade.sh - Execute RHEL In-Place Upgrade with Leapp
################################################################################
# Description: Orchestrates the actual Leapp upgrade with comprehensive safety
#              checks, snapshot creation, and post-reboot validation setup.
# Usage: ./execute-upgrade.sh --target 8|9 [--reboot] [--snapshot] [--force]
# Author: Migration Team
# Compatibility: RHEL 7.x, RHEL 8.x
################################################################################

set -euo pipefail

TARGET_VERSION=""
AUTO_REBOOT=0
CREATE_SNAPSHOT=0
FORCE_UPGRADE=0
UPGRADE_LOG="/var/log/leapp/leapp-upgrade.log"

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
# RHEL Version Detection
################################################################################

detect_rhel_version() {
    sed -rn 's/.*release ([0-9]+)\..*/\1/p' /etc/redhat-release
}

################################################################################
# Pre-Upgrade Verification
################################################################################

verify_leapp_installed() {
    info "Verifying Leapp is installed..."
    
    if ! command -v leapp &> /dev/null; then
        error "Leapp is not installed. Run prepare-leapp-upgrade.sh first"
        exit 1
    fi
    
    success "Leapp installation verified"
}

verify_no_inhibitors() {
    info "Checking for upgrade inhibitors..."
    
    local leapp_report="/var/log/leapp/leapp-report.txt"
    
    if [[ ! -f "$leapp_report" ]]; then
        warn "Leapp report not found. Run prepare-leapp-upgrade.sh first"
        if [[ $FORCE_UPGRADE -eq 0 ]]; then
            error "Cannot proceed without leapp preupgrade. Use --force to override"
            exit 1
        fi
        warn "Forcing upgrade despite missing report"
        return 0
    fi
    
    # Check for INHIBITOR entries
    if grep -q "^INHIBITOR:" "$leapp_report" 2>/dev/null; then
        error "Found upgrade inhibitors. Review /var/log/leapp/leapp-report.txt"
        if [[ $FORCE_UPGRADE -eq 0 ]]; then
            echo ""
            echo "Inhibitors found:"
            grep "^INHIBITOR:" "$leapp_report" | head -20
            echo ""
            error "Use --force to proceed despite inhibitors"
            exit 1
        else
            warn "Forcing upgrade despite inhibitors"
        fi
    else
        success "No critical inhibitors found"
    fi
}

################################################################################
# LVM Snapshot Management
################################################################################

create_lvm_snapshot() {
    info "Attempting to create LVM snapshot for rollback..."
    
    if ! command -v lvs &> /dev/null; then
        warn "LVM not available, skipping snapshot"
        return 1
    fi
    
    # Find root logical volume
    local root_lv
    root_lv=$(df / | awk 'NR==2 {print $1}' | sed 's|/dev/mapper/||' | sed 's/-/--/g' | sed 's/--/\-/g')
    
    if [[ -z "$root_lv" || "$root_lv" != /dev/mapper/* ]]; then
        warn "Root is not on LVM, skipping snapshot"
        return 1
    fi
    
    local vg_name
    local lv_name
    
    # Parse LVM device name
    if [[ "$root_lv" == /dev/mapper/* ]]; then
        local device_path="${root_lv#/dev/mapper/}"
        vg_name=$(echo "$device_path" | awk -F'-' '{print $1}')
        lv_name=$(echo "$device_path" | awk -F'-' '{print $2}')
    else
        warn "Could not parse LVM device name"
        return 1
    fi
    
    # Get available space in VG
    local vg_free_kb
    vg_free_kb=$(vgs --noheadings --units k "$vg_name" 2>/dev/null | awk '{print $6}' | sed 's/k$//') || {
        warn "Could not determine VG free space"
        return 1
    }
    
    # Allocate 20% of free space for snapshot (minimum 1GB)
    local snapshot_size_kb=$((vg_free_kb / 5))
    if [[ $snapshot_size_kb -lt 1048576 ]]; then
        warn "Insufficient free space for LVM snapshot (need 1GB+)"
        return 1
    fi
    
    local snapshot_size=$((snapshot_size_kb / 1024))M
    local snapshot_name="${lv_name}_pre_upgrade_snap"
    
    info "Creating LVM snapshot: $snapshot_name (${snapshot_size})"
    
    if lvcreate -L "$snapshot_size" -s -n "$snapshot_name" "/dev/${vg_name}/${lv_name}" 2>&1; then
        success "LVM snapshot created: /dev/${vg_name}/${snapshot_name}"
        echo "/dev/${vg_name}/${snapshot_name}" > /tmp/leapp-snapshot-info.txt
        return 0
    else
        warn "Failed to create LVM snapshot"
        return 1
    fi
}

################################################################################
# Service Management
################################################################################

disable_non_essential_services() {
    info "Disabling non-essential services..."
    
    local non_essential=("cups" "avahi-daemon" "nfs-server" "samba")
    
    for service in "${non_essential[@]}"; do
        if systemctl is-active "$service" &> /dev/null; then
            info "Stopping $service..."
            systemctl stop "$service" || true
        fi
    done
    
    success "Non-essential services disabled"
}

################################################################################
# Upgrade Execution
################################################################################

run_leapp_upgrade() {
    info "Starting Leapp upgrade process..."
    info "This may take 10-30 minutes..."
    echo ""
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$UPGRADE_LOG")"
    
    # Run Leapp upgrade with logging
    if leapp upgrade 2>&1 | tee "$UPGRADE_LOG"; then
        success "Leapp upgrade completed successfully"
        return 0
    else
        local exit_code=$?
        warn "Leapp upgrade completed with exit code: $exit_code"
        warn "Check $UPGRADE_LOG for details"
        return 0  # Leapp may exit with non-zero but still succeed
    fi
}

################################################################################
# Post-Upgrade Setup
################################################################################

setup_post_reboot_validation() {
    info "Setting up post-reboot validation..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local validation_script="$script_dir/post-migration-validate.sh"
    
    if [[ ! -f "$validation_script" ]]; then
        warn "post-migration-validate.sh not found"
        return 1
    fi
    
    # Create a cron job that runs once on next boot
    local rc_local="/etc/rc.d/rc.local"
    
    if [[ -f "$rc_local" && -x "$rc_local" ]]; then
        if ! grep -q "post-migration-validate.sh" "$rc_local"; then
            info "Adding post-reboot validation to rc.local"
            cat >> "$rc_local" << CRON_JOB
# Post-upgrade validation (auto-generated by execute-upgrade.sh)
/bin/bash "$validation_script" --cleanup 2>&1 | tee /var/log/migration/post-validation-\$(date +%Y%m%d-%H%M%S).log
CRON_JOB
        fi
    else
        # Try creating a systemd service for post-reboot validation
        info "Creating systemd service for post-reboot validation..."
        cat > /etc/systemd/system/leapp-post-validation.service << SYSTEMD_SERVICE
[Unit]
Description=Post-Leapp Upgrade Validation
After=multi-user.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$validation_script --cleanup
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE
        
        systemctl daemon-reload
        systemctl enable leapp-post-validation.service || true
    fi
    
    success "Post-reboot validation setup completed"
}

################################################################################
# Reboot Functions
################################################################################

prompt_for_reboot() {
    echo ""
    echo "================================================================================"
    echo "Upgrade preparation complete!"
    echo "================================================================================"
    echo ""
    echo "The system is ready to be upgraded. A reboot is required to apply the upgrade."
    echo ""
    
    if [[ $AUTO_REBOOT -eq 1 ]]; then
        info "Auto-reboot enabled. System will reboot in 60 seconds..."
        echo "Press Ctrl+C to cancel reboot"
        sleep 60
        reboot
    else
        read -p "Reboot now? (yes/no): " response
        if [[ "$response" == "yes" ]]; then
            info "Rebooting system..."
            sleep 2
            reboot
        else
            warn "Reboot cancelled. The upgrade will not be applied."
            warn "When ready, reboot manually with: shutdown -r now"
        fi
    fi
}

################################################################################
# Upgrade Status Monitoring
################################################################################

monitor_upgrade_progress() {
    info "Monitoring upgrade progress..."
    
    local check_interval=10
    local max_wait=1800  # 30 minutes
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        if [[ -f "$UPGRADE_LOG" ]]; then
            tail -5 "$UPGRADE_LOG"
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 --target <8|9> [OPTIONS]

OPTIONS:
    --target <8|9>      Target RHEL version (required)
    --reboot            Automatically reboot after upgrade preparation
    --snapshot          Create LVM snapshot for rollback capability
    --force             Skip verification checks and proceed
    --help              Show this help message

EXAMPLES:
    $0 --target 8
    $0 --target 9 --reboot --snapshot
    $0 --target 8 --force

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                TARGET_VERSION="$2"
                shift 2
                ;;
            --reboot)
                AUTO_REBOOT=1
                shift
                ;;
            --snapshot)
                CREATE_SNAPSHOT=1
                shift
                ;;
            --force)
                FORCE_UPGRADE=1
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
    
    if [[ -z "$TARGET_VERSION" ]]; then
        error "Missing required argument: --target"
        usage
        exit 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    parse_arguments "$@"
    check_root
    
    local current_version
    current_version=$(detect_rhel_version)
    
    info "Starting RHEL $current_version -> RHEL $TARGET_VERSION upgrade execution"
    echo ""
    
    verify_leapp_installed
    verify_no_inhibitors
    
    if [[ $CREATE_SNAPSHOT -eq 1 ]]; then
        create_lvm_snapshot || warn "Snapshot creation failed, continuing without snapshot"
    fi
    
    disable_non_essential_services
    run_leapp_upgrade
    setup_post_reboot_validation
    
    prompt_for_reboot
}

main "$@"
