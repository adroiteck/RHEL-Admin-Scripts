#!/bin/bash

################################################################################
# capture-system-state.sh - Capture Complete Pre-Upgrade System State
################################################################################
# Description: Captures comprehensive system state before migration for 
#              comparison and potential rollback.
# Usage: ./capture-system-state.sh [--output-dir DIR] [--include-rpm-verify]
# Author: Migration Team
# Compatibility: RHEL 7.x, RHEL 8.x
################################################################################

set -euo pipefail

OUTPUT_DIR=""
INCLUDE_RPM_VERIFY=0
STATE_DIR=""

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
# State Capture Functions
################################################################################

capture_system_info() {
    info "Capturing system information..."
    
    {
        echo "=== System Release ==="
        cat /etc/redhat-release
        echo ""
        
        echo "=== Hostname ==="
        hostname
        echo ""
        
        echo "=== Kernel Version ==="
        uname -r
        echo ""
        
        echo "=== Uptime ==="
        uptime
        echo ""
    } > "$STATE_DIR/system-info.txt"
}

capture_installed_packages() {
    info "Capturing installed RPM packages..."
    
    rpm -qa | sort > "$STATE_DIR/installed-packages.txt"
    
    # Also save package information
    rpm -qa --qf='[%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}|%{SIZE}\n]' | sort > "$STATE_DIR/packages-detailed.txt"
}

capture_enabled_services() {
    info "Capturing enabled services..."
    
    systemctl list-unit-files --no-pager --type=service > "$STATE_DIR/systemctl-list-unit-files.txt"
    systemctl list-units --no-pager --type=service --state=running > "$STATE_DIR/systemctl-running-services.txt"
    systemctl list-units --no-pager --type=service --state=enabled > "$STATE_DIR/systemctl-enabled-services.txt"
}

capture_firewall_rules() {
    info "Capturing firewall rules..."
    
    if command -v firewall-cmd &> /dev/null; then
        {
            echo "=== Firewall Status ==="
            systemctl is-active firewalld || echo "firewalld not active"
            echo ""
            
            echo "=== Firewall Zones ==="
            firewall-cmd --list-all-zones 2>/dev/null || echo "Could not list firewall zones"
            echo ""
        } > "$STATE_DIR/firewall-rules.txt"
    else
        echo "firewall-cmd not available" > "$STATE_DIR/firewall-rules.txt"
    fi
    
    # Also capture iptables if available
    if command -v iptables &> /dev/null; then
        {
            echo "=== iptables Rules ==="
            iptables -L -n -v 2>/dev/null || echo "Could not list iptables rules"
        } > "$STATE_DIR/iptables-rules.txt"
    fi
}

capture_network_configuration() {
    info "Capturing network configuration..."
    
    {
        echo "=== IP Addresses ==="
        ip addr show
        echo ""
        
        echo "=== Routing Table ==="
        ip route show
        echo ""
        
        echo "=== DNS Configuration ==="
        cat /etc/resolv.conf
        echo ""
        
        echo "=== Network Interfaces ==="
        ip link show
        echo ""
        
        echo "=== Network Statistics ==="
        ss -i
        echo ""
    } > "$STATE_DIR/network-config.txt"
}

capture_kernel_parameters() {
    info "Capturing kernel parameters..."
    
    sysctl -a > "$STATE_DIR/sysctl-parameters.txt"
}

capture_selinux_status() {
    info "Capturing SELinux configuration..."
    
    if command -v getenforce &> /dev/null; then
        {
            echo "=== SELinux Status ==="
            getenforce
            echo ""
            
            echo "=== SELinux Config ==="
            cat /etc/selinux/config 2>/dev/null || echo "Could not read SELinux config"
            echo ""
            
            echo "=== SELinux Booleans ==="
            getsebool -a 2>/dev/null || echo "Could not list SELinux booleans"
            echo ""
        } > "$STATE_DIR/selinux-status.txt"
    else
        echo "SELinux not available" > "$STATE_DIR/selinux-status.txt"
    fi
}

capture_mount_points() {
    info "Capturing mount points and filesystem layout..."
    
    {
        echo "=== Mount Points ==="
        mount | column -t
        echo ""
        
        echo "=== /etc/fstab ==="
        cat /etc/fstab
        echo ""
        
        echo "=== Disk Usage ==="
        df -h
        echo ""
        
        echo "=== Inode Usage ==="
        df -i
        echo ""
    } > "$STATE_DIR/mount-points.txt"
}

capture_crontabs() {
    info "Capturing crontab entries..."
    
    {
        echo "=== System Crontab ==="
        cat /etc/crontab 2>/dev/null || echo "Could not read /etc/crontab"
        echo ""
        
        echo "=== Cron.d Entries ==="
        ls -la /etc/cron.d/ 2>/dev/null || echo "No /etc/cron.d entries"
        echo ""
        
        echo "=== User Crontabs ==="
        for user in $(cut -f1 -d: /etc/passwd); do
            if crontab -u "$user" -l 2>/dev/null; then
                echo "--- Crontab for $user ---"
                crontab -u "$user" -l 2>/dev/null || true
                echo ""
            fi
        done
    } > "$STATE_DIR/crontabs.txt" 2>&1
}

capture_custom_repositories() {
    info "Capturing custom repositories..."
    
    {
        echo "=== Repository Configuration ==="
        find /etc/yum.repos.d -name "*.repo" -exec echo "--- {} ---" \; -exec cat {} \; 2>/dev/null
        echo ""
        
        if command -v dnf &> /dev/null; then
            echo "=== DNF Repository List ==="
            dnf repolist all 2>/dev/null || true
        fi
    } > "$STATE_DIR/repositories.txt"
}

capture_user_accounts() {
    info "Capturing user accounts and groups..."
    
    {
        echo "=== /etc/passwd ==="
        cat /etc/passwd
        echo ""
        
        echo "=== /etc/shadow (summary) ==="
        wc -l /etc/shadow
        echo ""
        
        echo "=== /etc/group ==="
        cat /etc/group
        echo ""
        
        echo "=== /etc/sudoers ==="
        visudo -c 2>&1 || true
        echo ""
    } > "$STATE_DIR/user-accounts.txt"
}

capture_open_ports() {
    info "Capturing open ports and listening services..."
    
    {
        echo "=== Listening Ports (netstat-style) ==="
        ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "Could not list open ports"
        echo ""
        
        echo "=== UDP Listening Ports ==="
        ss -ulnp 2>/dev/null || netstat -ulnp 2>/dev/null || echo "Could not list UDP ports"
        echo ""
    } > "$STATE_DIR/open-ports.txt"
}

capture_running_processes() {
    info "Capturing running processes..."
    
    {
        echo "=== Process List ==="
        ps auxww
        echo ""
        
        echo "=== Process Tree ==="
        pstree -p 2>/dev/null || ps auxww --forest || echo "Could not generate process tree"
        echo ""
    } > "$STATE_DIR/running-processes.txt"
}

capture_rpm_verification() {
    if [[ $INCLUDE_RPM_VERIFY -eq 0 ]]; then
        return 0
    fi
    
    info "Running RPM verification (this may take several minutes)..."
    
    rpm -Va > "$STATE_DIR/rpm-verify.txt" 2>&1 || {
        warn "RPM verification reported some issues (see rpm-verify.txt)"
    }
}

capture_kernel_modules() {
    info "Capturing loaded kernel modules..."
    
    {
        echo "=== Loaded Modules ==="
        lsmod
        echo ""
        
        echo "=== Module Parameters ==="
        find /sys/module -name parameters -type d -exec bash -c 'echo "Module: $(basename $(dirname {}))"; cat {}/* 2>/dev/null | tr "\n" " "; echo' \; 2>/dev/null
        echo ""
    } > "$STATE_DIR/kernel-modules.txt"
}

capture_boot_configuration() {
    info "Capturing boot configuration..."
    
    {
        echo "=== GRUB Configuration ==="
        cat /etc/default/grub 2>/dev/null || echo "Could not read GRUB config"
        echo ""
        
        if [[ -f /boot/grub2/grub.cfg ]]; then
            echo "=== GRUB Menu Entries ==="
            grep -E "^menuentry" /boot/grub2/grub.cfg | head -10
        fi
        echo ""
    } > "$STATE_DIR/boot-configuration.txt"
}

################################################################################
# Summary Report
################################################################################

generate_capture_summary() {
    info "Generating capture summary..."
    
    {
        echo "================================================================================"
        echo "System State Capture Summary"
        echo "================================================================================"
        echo "Capture Date: $(date)"
        echo "Capture Location: $STATE_DIR"
        echo ""
        
        echo "Captured Items:"
        ls -lh "$STATE_DIR" | tail -n +2 | awk '{printf "  %-40s %8s\n", $9, $5}'
        echo ""
        
        echo "Total Packages: $(wc -l < "$STATE_DIR/installed-packages.txt")"
        echo "Total Services: $(grep -c '\.service' "$STATE_DIR/systemctl-list-unit-files.txt" || echo 0)"
        echo ""
        
        echo "This capture can be compared with post-upgrade state to identify:"
        echo "  - Missing or upgraded packages"
        echo "  - Services that were running but are now stopped"
        echo "  - Network configuration changes"
        echo "  - Firewall rule modifications"
        echo "================================================================================"
    } | tee "$STATE_DIR/CAPTURE_SUMMARY.txt"
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    --output-dir DIR        Directory to store captured state (default: /var/log/migration/pre-upgrade-YYYYMMDD/)
    --include-rpm-verify    Include full RPM verification (time-consuming)
    --help                  Show this help message

EXAMPLES:
    $0
    $0 --output-dir /backup/pre-upgrade-state
    $0 --include-rpm-verify

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --include-rpm-verify)
                INCLUDE_RPM_VERIFY=1
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
    
    # Create output directory
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="/var/log/migration/pre-upgrade-$(date +%Y%m%d)"
    fi
    
    STATE_DIR="$OUTPUT_DIR"
    
    if ! mkdir -p "$STATE_DIR"; then
        error "Failed to create output directory: $STATE_DIR"
        exit 1
    fi
    
    info "Capturing system state to: $STATE_DIR"
    echo ""
    
    # Perform all captures
    capture_system_info
    capture_installed_packages
    capture_enabled_services
    capture_firewall_rules
    capture_network_configuration
    capture_kernel_parameters
    capture_selinux_status
    capture_mount_points
    capture_crontabs
    capture_custom_repositories
    capture_user_accounts
    capture_open_ports
    capture_running_processes
    capture_kernel_modules
    capture_boot_configuration
    capture_rpm_verification
    
    echo ""
    generate_capture_summary
    
    echo ""
    success "System state capture completed successfully"
    echo "Captured state directory: $STATE_DIR"
    echo "Use this directory with post-migration-validate.sh for comparison"
    echo ""
}

main "$@"
