#!/bin/bash

################################################################################
# pre-migration-assessment.sh - RHEL In-Place Upgrade Pre-Assessment
################################################################################
# Description: Comprehensive pre-upgrade assessment before running Leapp.
#              Verifies system readiness for RHEL version upgrade.
# Usage: ./pre-migration-assessment.sh --target 8|9 [--output FILE] [--format text|html]
# Author: Migration Team
# Compatibility: RHEL 7.x, RHEL 8.x (for RHEL 8->9)
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_VERSION=""
OUTPUT_FILE=""
OUTPUT_FORMAT="text"
REPORT_LINES=()
CHECK_RESULTS=()

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
    if [[ ! -f /etc/redhat-release ]]; then
        error "Not a RHEL system (missing /etc/redhat-release)"
        exit 1
    fi
    
    local rhel_version
    rhel_version=$(sed -rn 's/.*release ([0-9]+)\..*/\1/p' /etc/redhat-release)
    echo "$rhel_version"
}

################################################################################
# Assessment Check Functions
################################################################################

check_version_compatibility() {
    local current_version=$1
    local target_version=$2
    
    info "Checking version compatibility..."
    
    if [[ "$target_version" == "8" && "$current_version" != "7" ]]; then
        REPORT_LINES+=("FAIL|Version Compatibility|Cannot upgrade from RHEL $current_version to RHEL 8 (only RHEL 7->8 supported)")
        CHECK_RESULTS+=(1)
        return 1
    elif [[ "$target_version" == "9" && "$current_version" != "8" ]]; then
        REPORT_LINES+=("FAIL|Version Compatibility|Cannot upgrade from RHEL $current_version to RHEL 9 (only RHEL 8->9 supported)")
        CHECK_RESULTS+=(1)
        return 1
    else
        REPORT_LINES+=("PASS|Version Compatibility|RHEL $current_version -> RHEL $target_version upgrade path is valid")
        CHECK_RESULTS+=(0)
        return 0
    fi
}

check_subscription_status() {
    info "Checking subscription status..."
    
    if ! command -v subscription-manager &> /dev/null; then
        REPORT_LINES+=("FAIL|Subscription Manager|subscription-manager not installed")
        CHECK_RESULTS+=(1)
        return 1
    fi
    
    if ! subscription-manager identity &> /dev/null; then
        REPORT_LINES+=("WARN|Subscription Status|System not registered with Red Hat subscription manager")
        CHECK_RESULTS+=(2)
        return 2
    else
        REPORT_LINES+=("PASS|Subscription Status|System is registered with active subscription")
        CHECK_RESULTS+=(0)
        return 0
    fi
}

check_disk_space() {
    info "Checking disk space requirements..."
    
    local boot_space_kb=$(df /boot | awk 'NR==2 {print $4}')
    local root_space_kb=$(df / | awk 'NR==2 {print $4}')
    
    local boot_space_gb=$((boot_space_kb / 1024 / 1024))
    local root_space_gb=$((root_space_kb / 1024 / 1024))
    
    local boot_ok=0
    local root_ok=0
    
    if [[ $boot_space_gb -ge 2 ]]; then
        REPORT_LINES+=("PASS|/boot Disk Space|$boot_space_gb GB available (requires 2+ GB)")
        boot_ok=1
    else
        REPORT_LINES+=("FAIL|/boot Disk Space|Only $boot_space_gb GB available (requires 2+ GB)")
        CHECK_RESULTS+=(1)
    fi
    
    if [[ $root_space_gb -ge 5 ]]; then
        REPORT_LINES+=("PASS|/ Disk Space|$root_space_gb GB available (requires 5+ GB)")
        root_ok=1
    else
        REPORT_LINES+=("FAIL|/ Disk Space|Only $root_space_gb GB available (requires 5+ GB)")
        CHECK_RESULTS+=(1)
    fi
    
    [[ $boot_ok -eq 1 && $root_ok -eq 1 ]] && return 0 || return 1
}

check_kernel_modules() {
    info "Checking for blocking kernel modules..."
    
    local blocking_modules=("fips" "ndiswrapper" "vboxguest" "vboxsf")
    local found_blocking=0
    
    for module in "${blocking_modules[@]}"; do
        if lsmod | grep -q "^$module"; then
            REPORT_LINES+=("WARN|Kernel Module|Module '$module' loaded (may cause upgrade issues)")
            found_blocking=1
        fi
    done
    
    if [[ $found_blocking -eq 0 ]]; then
        REPORT_LINES+=("PASS|Kernel Modules|No known blocking kernel modules detected")
        CHECK_RESULTS+=(0)
        return 0
    else
        CHECK_RESULTS+=(2)
        return 2
    fi
}

check_third_party_packages() {
    info "Checking for third-party packages..."
    
    local third_party_repos=("elrepo" "epel" "remi" "postgresql" "mysql-community" "nginx-stable")
    local found_third_party=0
    
    for repo in "${third_party_repos[@]}"; do
        if rpm -qa | grep -qi "$repo"; then
            REPORT_LINES+=("WARN|Third-Party Packages|Packages from '$repo' repository detected")
            found_third_party=1
        fi
    done
    
    if [[ $found_third_party -eq 0 ]]; then
        REPORT_LINES+=("PASS|Third-Party Packages|No problematic third-party packages detected")
        CHECK_RESULTS+=(0)
        return 0
    else
        CHECK_RESULTS+=(2)
        return 2
    fi
}

check_deprecated_packages() {
    info "Checking for deprecated packages..."
    
    local target_version=$1
    local found_deprecated=0
    
    if [[ "$target_version" == "8" ]]; then
        if rpm -q python2 &> /dev/null; then
            REPORT_LINES+=("WARN|Deprecated Packages|python2 installed (deprecated in RHEL 8, plan for removal)")
            found_deprecated=1
        fi
    fi
    
    if [[ "$target_version" == "9" ]]; then
        if rpm -q python2 &> /dev/null; then
            REPORT_LINES+=("FAIL|Deprecated Packages|python2 must be removed before RHEL 8->9 upgrade")
            CHECK_RESULTS+=(1)
            found_deprecated=1
        fi
    fi
    
    if [[ $found_deprecated -eq 0 ]]; then
        REPORT_LINES+=("PASS|Deprecated Packages|No deprecated packages blocking upgrade")
        CHECK_RESULTS+=(0)
        return 0
    fi
    
    return 1
}

check_network_configuration() {
    info "Checking network configuration method..."
    
    local target_version=$1
    local using_network_scripts=0
    
    if [[ -d /etc/sysconfig/network-scripts && -n "$(ls -A /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null)" ]]; then
        using_network_scripts=1
    fi
    
    if [[ "$target_version" == "9" && $using_network_scripts -eq 1 ]]; then
        REPORT_LINES+=("WARN|Network Configuration|Using network-scripts (removed in RHEL 9 - migration to NetworkManager required)")
        CHECK_RESULTS+=(2)
        return 2
    elif [[ $using_network_scripts -eq 1 ]]; then
        REPORT_LINES+=("WARN|Network Configuration|Using network-scripts (legacy, consider migration to NetworkManager)")
        CHECK_RESULTS+=(2)
        return 2
    else
        REPORT_LINES+=("PASS|Network Configuration|Using modern network configuration method")
        CHECK_RESULTS+=(0)
        return 0
    fi
}

check_boot_mode() {
    info "Checking firmware/boot mode..."
    
    if [[ -d /sys/firmware/efi ]]; then
        REPORT_LINES+=("PASS|Boot Mode|System uses UEFI (compatible with upgrade)")
        CHECK_RESULTS+=(0)
    else
        REPORT_LINES+=("PASS|Boot Mode|System uses BIOS/MBR (compatible with upgrade)")
        CHECK_RESULTS+=(0)
    fi
    return 0
}

check_lvm_layout() {
    info "Checking LVM layout..."
    
    if ! command -v lvs &> /dev/null; then
        REPORT_LINES+=("PASS|LVM|System does not use LVM")
        CHECK_RESULTS+=(0)
        return 0
    fi
    
    local boot_device
    boot_device=$(df /boot | awk 'NR==2 {print $1}')
    
    if [[ "$boot_device" == /dev/mapper/* ]]; then
        REPORT_LINES+=("WARN|LVM Layout|/boot is on LVM (supported but requires careful snapshot management)")
        CHECK_RESULTS+=(2)
        return 2
    else
        REPORT_LINES+=("PASS|LVM Layout|Standard LVM layout detected (safe for upgrade)")
        CHECK_RESULTS+=(0)
        return 0
    fi
}

check_conflicting_services() {
    info "Checking for conflicting services..."
    
    local conflicting=("kdump" "tuned" "irqbalance")
    local found_conflict=0
    
    for service in "${conflicting[@]}"; do
        if systemctl is-enabled "$service" &> /dev/null && systemctl is-active "$service" &> /dev/null; then
            REPORT_LINES+=("WARN|Conflicting Services|Service '$service' is running (may interfere with upgrade)")
            found_conflict=1
        fi
    done
    
    if [[ $found_conflict -eq 0 ]]; then
        REPORT_LINES+=("PASS|Conflicting Services|No known conflicting services detected")
        CHECK_RESULTS+=(0)
        return 0
    else
        CHECK_RESULTS+=(2)
        return 2
    fi
}

check_selinux_policy() {
    info "Checking SELinux policy..."
    
    if ! command -v getenforce &> /dev/null; then
        REPORT_LINES+=("PASS|SELinux|SELinux not available on this system")
        CHECK_RESULTS+=(0)
        return 0
    fi
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
    
    if [[ "$selinux_status" == "Enforcing" ]]; then
        REPORT_LINES+=("WARN|SELinux Policy|SELinux in Enforcing mode (upgrade will relabel filesystem)")
        CHECK_RESULTS+=(2)
    else
        REPORT_LINES+=("PASS|SELinux Policy|SELinux status: $selinux_status")
        CHECK_RESULTS+=(0)
    fi
    return 0
}

################################################################################
# Report Generation
################################################################################

generate_text_report() {
    local output_file=$1
    
    {
        echo "================================================================================"
        echo "RHEL Pre-Migration Assessment Report"
        echo "================================================================================"
        echo "Generated: $(date)"
        echo "Current System: $(cat /etc/redhat-release)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "Target RHEL Version: $TARGET_VERSION"
        echo "================================================================================"
        echo ""
        echo "Assessment Results:"
        echo "================================================================================"
        
        for line in "${REPORT_LINES[@]}"; do
            IFS='|' read -r status check_name details <<< "$line"
            
            case "$status" in
                PASS) printf "%-8s %-30s %s\n" "[✓]" "$check_name" "$details" ;;
                WARN) printf "%-8s %-30s %s\n" "[⚠]" "$check_name" "$details" ;;
                FAIL) printf "%-8s %-30s %s\n" "[✗]" "$check_name" "$details" ;;
            esac
        done
        
        echo ""
        echo "================================================================================"
        local pass_count=0
        local warn_count=0
        local fail_count=0
        
        for result in "${CHECK_RESULTS[@]}"; do
            case $result in
                0) ((pass_count++)) ;;
                1) ((fail_count++)) ;;
                2) ((warn_count++)) ;;
            esac
        done
        
        echo "Summary: $pass_count Passed, $warn_count Warnings, $fail_count Failed"
        echo "================================================================================"
        
        if [[ $fail_count -gt 0 ]]; then
            echo "Status: NOT READY FOR UPGRADE - Fix failures before proceeding"
            return 1
        elif [[ $warn_count -gt 0 ]]; then
            echo "Status: PROCEED WITH CAUTION - Review warnings and plan mitigations"
            return 0
        else
            echo "Status: READY FOR UPGRADE - All checks passed"
            return 0
        fi
    } | tee "$output_file"
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 --target <8|9> [OPTIONS]

OPTIONS:
    --target <8|9>      Target RHEL version (required)
    --output FILE       Save report to file (default: print to stdout)
    --format FORMAT     Report format: text or html (default: text)
    --help              Show this help message

EXAMPLES:
    $0 --target 8 --format text
    $0 --target 9 --output /tmp/assessment.html --format html

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                TARGET_VERSION="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                shift 2
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
    
    if [[ "$TARGET_VERSION" != "8" && "$TARGET_VERSION" != "9" ]]; then
        error "Invalid target version: $TARGET_VERSION (must be 8 or 9)"
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
    info "Detected RHEL version: $current_version"
    
    info "Starting pre-migration assessment for RHEL $current_version -> RHEL $TARGET_VERSION"
    echo ""
    
    check_version_compatibility "$current_version" "$TARGET_VERSION"
    check_subscription_status
    check_disk_space
    check_kernel_modules
    check_third_party_packages
    check_deprecated_packages "$TARGET_VERSION"
    check_network_configuration "$TARGET_VERSION"
    check_boot_mode
    check_lvm_layout
    check_conflicting_services
    check_selinux_policy
    
    echo ""
    if [[ -n "$OUTPUT_FILE" ]]; then
        generate_text_report "$OUTPUT_FILE"
    else
        generate_text_report "/dev/stdout"
    fi
}

main "$@"
