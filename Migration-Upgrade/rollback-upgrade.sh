#!/bin/bash

################################################################################
# rollback-upgrade.sh - RHEL Upgrade Rollback Procedures
################################################################################
# Description: Provides rollback capabilities for failed RHEL upgrades using
#              LVM snapshots or manual recovery procedures.
# Usage: ./rollback-upgrade.sh [--snapshot-name NAME] [--pre-state-dir DIR] [--instructions-only]
# Author: Migration Team
# Compatibility: RHEL 8.x, RHEL 9.x
################################################################################

set -euo pipefail

SNAPSHOT_NAME=""
PRE_STATE_DIR=""
INSTRUCTIONS_ONLY=0

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
# Snapshot Detection and Rollback
################################################################################

detect_lvm_snapshot() {
    info "Detecting LVM snapshots..."
    
    if ! command -v lvs &> /dev/null; then
        warn "LVM not available, cannot perform snapshot rollback"
        return 1
    fi
    
    local root_device
    root_device=$(df / | awk 'NR==2 {print $1}')
    
    if [[ ! "$root_device" == /dev/mapper/* ]]; then
        warn "Root is not on LVM, cannot perform snapshot rollback"
        return 1
    fi
    
    # Check for pre-upgrade snapshot
    local snapshots
    snapshots=$(lvs --no-headings 2>/dev/null | awk '{print $1}' | grep snap || true)
    
    if [[ -z "$snapshots" ]]; then
        warn "No LVM snapshots found"
        return 1
    fi
    
    echo "Available snapshots:"
    echo "$snapshots"
    return 0
}

perform_snapshot_rollback() {
    info "Performing LVM snapshot rollback..."
    
    if [[ -z "$SNAPSHOT_NAME" ]]; then
        error "Snapshot name not provided"
        error "Usage: $0 --snapshot-name <snapshot_name>"
        return 1
    fi
    
    if ! command -v lvs &> /dev/null; then
        error "LVM not available"
        return 1
    fi
    
    local snapshot_path="/dev/$(echo "$SNAPSHOT_NAME" | sed 's/-/\//' | sed 's/-/\//')"
    
    # Verify snapshot exists
    if ! lvs "$snapshot_path" &> /dev/null; then
        error "Snapshot not found: $snapshot_path"
        return 1
    fi
    
    warn "WARNING: This will overwrite the current root filesystem with the snapshot!"
    warn "All changes since the snapshot was created will be lost."
    echo ""
    read -p "Are you absolutely sure you want to rollback? (type 'yes' to confirm): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Rollback cancelled"
        return 0
    fi
    
    info "Rolling back to snapshot: $SNAPSHOT_NAME"
    
    # This operation requires careful handling
    # In practice, this would typically be done by:
    # 1. Booting into rescue mode
    # 2. Merging the snapshot
    # 3. Rebooting
    
    echo "To complete the rollback:"
    echo "1. Boot into rescue/single-user mode"
    echo "2. Run: lvconvert --merge $snapshot_path"
    echo "3. Reboot the system"
    echo ""
    
    return 0
}

################################################################################
# Manual Recovery Instructions
################################################################################

print_manual_recovery_instructions() {
    cat << 'INSTRUCTIONS'
================================================================================
MANUAL RHEL UPGRADE RECOVERY INSTRUCTIONS
================================================================================

If the RHEL upgrade has failed or the system is in an inconsistent state, 
you have several recovery options:

OPTION 1: Boot into Rescue Mode
================================================================================
1. Reboot the system
2. At GRUB menu, press 'e' to edit the boot entry
3. Add 'rd.break' to the kernel line
4. Press Ctrl+X to boot
5. The system will boot into a rescue shell
6. Mount the filesystem if needed: mount -o remount,rw /sysroot
7. Perform manual fixes as needed
8. Type 'exit' to continue boot

OPTION 2: Use Single-User Mode
================================================================================
1. Reboot the system
2. At GRUB menu, press 'e' to edit the boot entry
3. Replace the entire command line with: /sbin/init
4. Press Ctrl+X to boot
5. The system will boot into single-user mode
6. Make necessary repairs
7. Type 'exit' to reboot normally

OPTION 3: Rollback Using LVM Snapshot
================================================================================
If a pre-upgrade LVM snapshot was created:
1. Boot into rescue or single-user mode
2. Identify the snapshot: lvs
3. Merge the snapshot to the original volume:
   lvconvert --merge /dev/vg_name/snapshot_name
4. Reboot the system

OPTION 4: Boot Alternative Kernel
================================================================================
1. At GRUB menu, check if previous kernel is available
2. Select previous kernel from menu
3. Verify if system works with old kernel
4. If needed, run: grub2-mkconfig -o /boot/grub2/grub.cfg

OPTION 5: Complete Reinstallation
================================================================================
If other options fail:
1. Boot from RHEL installation media
2. Choose "Rescue Mode" from installer
3. Use this environment to diagnose or perform fresh installation
4. Consider using the captured pre-upgrade system state to restore data

TROUBLESHOOTING
================================================================================
- Check /var/log/messages for errors
- Review /var/log/leapp/leapp-report.txt for inhibitor information
- Use 'dmesg' to check kernel messages
- Verify filesystem integrity: fsck (unmounted filesystems only)
- Check grub configuration: cat /etc/default/grub

GETTING HELP
================================================================================
- Red Hat Support Portal: https://access.redhat.com
- System logs: /var/log/messages, /var/log/audit/audit.log
- Leapp data: /var/log/leapp/
- System state backups: Check pre-upgrade capture directory

INSTRUCTIONS
}

################################################################################
# Recovery Procedures from Captured State
################################################################################

restore_from_captured_state() {
    info "Restoring system configuration from pre-upgrade capture..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -d "$PRE_STATE_DIR" ]]; then
        warn "Pre-upgrade state directory not provided or not found"
        return 1
    fi
    
    echo ""
    echo "Files available for restoration:"
    echo "=================================="
    ls -lh "$PRE_STATE_DIR" | tail -n +2 | awk '{printf "  %-40s %s\n", $9, $5}'
    echo ""
    
    echo "To restore specific configuration:"
    echo "  1. Network config: Review $PRE_STATE_DIR/network-config.txt"
    echo "  2. Firewall rules: Check $PRE_STATE_DIR/firewall-rules.txt"
    echo "  3. User accounts: See $PRE_STATE_DIR/user-accounts.txt"
    echo "  4. Services: Review $PRE_STATE_DIR/systemctl-enabled-services.txt"
    echo ""
    
    return 0
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    --snapshot-name NAME    Name of LVM snapshot to rollback to
    --pre-state-dir DIR     Pre-upgrade state directory for reference
    --instructions-only     Show recovery instructions without performing rollback
    --help                  Show this help message

EXAMPLES:
    $0 --instructions-only
    $0 --snapshot-name root_pre_upgrade_snap
    $0 --pre-state-dir /var/log/migration/pre-upgrade-20240315

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --snapshot-name)
                SNAPSHOT_NAME="$2"
                shift 2
                ;;
            --pre-state-dir)
                PRE_STATE_DIR="$2"
                shift 2
                ;;
            --instructions-only)
                INSTRUCTIONS_ONLY=1
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
    
    echo ""
    echo "================================================================================"
    echo "RHEL Upgrade Rollback Tool"
    echo "================================================================================"
    echo ""
    
    if [[ $INSTRUCTIONS_ONLY -eq 1 ]]; then
        print_manual_recovery_instructions
        exit 0
    fi
    
    # Try to detect and use LVM snapshot
    if detect_lvm_snapshot; then
        perform_snapshot_rollback
    else
        info "No automatic rollback available"
        echo ""
        print_manual_recovery_instructions
    fi
    
    # Show information about captured state
    if [[ -n "$PRE_STATE_DIR" && -d "$PRE_STATE_DIR" ]]; then
        echo ""
        restore_from_captured_state
    fi
    
    echo ""
    warn "For additional support, contact Red Hat Support"
}

main "$@"
