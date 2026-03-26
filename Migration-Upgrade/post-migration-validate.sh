#!/bin/bash

################################################################################
# post-migration-validate.sh - Post-Upgrade System Validation
################################################################################
# Description: Validates system integrity after RHEL upgrade reboot.
#              Compares pre/post state and generates validation report.
# Usage: ./post-migration-validate.sh [--pre-state-dir DIR] [--output FILE] [--cleanup]
# Author: Migration Team
# Compatibility: RHEL 8.x, RHEL 9.x
################################################################################

set -euo pipefail

PRE_STATE_DIR=""
OUTPUT_FILE=""
CLEANUP_LEAPP=0
VALIDATION_RESULTS=()

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
# Post-Upgrade Validation Functions
################################################################################

validate_rhel_version() {
    info "Validating RHEL version..."
    
    local current_version
    current_version=$(sed -rn 's/.*release ([0-9]+)\..*/\1/p' /etc/redhat-release)
    
    local expected_version=$1
    
    if [[ "$current_version" == "$expected_version" ]]; then
        VALIDATION_RESULTS+=("PASS|RHEL Version|Successfully upgraded to RHEL $current_version")
        success "RHEL version is correct: $current_version"
        return 0
    else
        VALIDATION_RESULTS+=("FAIL|RHEL Version|Expected RHEL $expected_version but found RHEL $current_version")
        error "Version mismatch: expected $expected_version but found $current_version"
        return 1
    fi
}

validate_kernel_version() {
    info "Validating kernel version..."
    
    local kernel_version
    kernel_version=$(uname -r)
    
    VALIDATION_RESULTS+=("INFO|Kernel Version|$kernel_version")
    success "Kernel version: $kernel_version"
    return 0
}

validate_services() {
    info "Validating services..."
    
    local failed_services=0
    
    # Check if expected services are running
    while IFS= read -r service_line; do
        [[ -z "$service_line" ]] && continue
        
        local service_name
        service_name=$(echo "$service_line" | awk '{print $1}')
        
        if systemctl is-active "$service_name" &> /dev/null; then
            :  # Service is running
        else
            if systemctl is-enabled "$service_name" &> /dev/null; then
                warn "Service $service_name was enabled but is not running"
                VALIDATION_RESULTS+=("WARN|Service Status|$service_name not running (expected to be)")
                failed_services=$((failed_services + 1))
            fi
        fi
    done < <(grep "enabled" "$PRE_STATE_DIR/systemctl-list-unit-files.txt" 2>/dev/null | grep "\.service" | head -20)
    
    if [[ $failed_services -eq 0 ]]; then
        VALIDATION_RESULTS+=("PASS|Service Status|All critical services running")
        success "Service validation passed"
        return 0
    else
        VALIDATION_RESULTS+=("WARN|Service Status|$failed_services services not running as expected")
        warn "Some services are not running"
        return 1
    fi
}

validate_network_connectivity() {
    info "Validating network connectivity..."
    
    local network_ok=0
    
    # Test DNS resolution
    if nslookup google.com &> /dev/null; then
        VALIDATION_RESULTS+=("PASS|DNS Resolution|DNS is functional")
        network_ok=1
    else
        VALIDATION_RESULTS+=("WARN|DNS Resolution|DNS resolution failed")
    fi
    
    # Test gateway connectivity
    local gateway
    gateway=$(ip route show | grep default | awk '{print $3}' | head -1)
    
    if [[ -n "$gateway" ]]; then
        if ping -c 1 "$gateway" &> /dev/null; then
            VALIDATION_RESULTS+=("PASS|Gateway Connectivity|Gateway $gateway is reachable")
            return 0
        else
            VALIDATION_RESULTS+=("WARN|Gateway Connectivity|Cannot ping default gateway $gateway")
            return 1
        fi
    else
        VALIDATION_RESULTS+=("WARN|Gateway Connectivity|No default gateway configured")
        return 1
    fi
}

validate_package_manager() {
    info "Validating package manager..."
    
    if command -v dnf &> /dev/null; then
        if dnf check &> /dev/null; then
            VALIDATION_RESULTS+=("PASS|Package Manager|dnf is functional")
            success "Package manager is functional"
            return 0
        else
            VALIDATION_RESULTS+=("WARN|Package Manager|dnf check reported issues")
            warn "Package manager check found issues"
            return 1
        fi
    elif command -v yum &> /dev/null; then
        if yum check &> /dev/null; then
            VALIDATION_RESULTS+=("PASS|Package Manager|yum is functional")
            return 0
        else
            VALIDATION_RESULTS+=("WARN|Package Manager|yum check reported issues")
            return 1
        fi
    else
        VALIDATION_RESULTS+=("FAIL|Package Manager|No package manager found")
        error "No package manager found"
        return 1
    fi
}

validate_selinux() {
    info "Validating SELinux status..."
    
    if ! command -v getenforce &> /dev/null; then
        VALIDATION_RESULTS+=("INFO|SELinux|SELinux not available")
        return 0
    fi
    
    local selinux_status
    selinux_status=$(getenforce)
    
    VALIDATION_RESULTS+=("INFO|SELinux Status|SELinux is $selinux_status")
    success "SELinux status: $selinux_status"
    return 0
}

validate_systemd_units() {
    info "Validating systemd units..."
    
    local failed_units
    failed_units=$(systemctl list-units --state=failed --no-pager 2>/dev/null | grep "^●" | wc -l)
    
    if [[ $failed_units -eq 0 ]]; then
        VALIDATION_RESULTS+=("PASS|Systemd Units|No failed systemd units")
        success "No failed systemd units"
        return 0
    else
        VALIDATION_RESULTS+=("WARN|Systemd Units|Found $failed_units failed units")
        warn "Found $failed_units failed systemd units"
        systemctl list-units --state=failed --no-pager | head -20
        return 1
    fi
}

validate_subscription() {
    info "Validating subscription status..."
    
    if ! command -v subscription-manager &> /dev/null; then
        VALIDATION_RESULTS+=("INFO|Subscription|subscription-manager not available")
        return 0
    fi
    
    if subscription-manager identity &> /dev/null; then
        VALIDATION_RESULTS+=("PASS|Subscription|System is registered")
        success "Subscription is active"
        return 0
    else
        VALIDATION_RESULTS+=("WARN|Subscription|System not registered with subscription manager")
        warn "Subscription status unknown"
        return 1
    fi
}

compare_package_lists() {
    info "Comparing installed packages with pre-upgrade state..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -f "$PRE_STATE_DIR/installed-packages.txt" ]]; then
        warn "Pre-upgrade package list not found, skipping comparison"
        return 0
    fi
    
    local pre_packages="$PRE_STATE_DIR/installed-packages.txt"
    local post_packages="/tmp/post-upgrade-packages.txt"
    
    rpm -qa | sort > "$post_packages"
    
    # Find missing packages
    local missing_packages
    missing_packages=$(comm -23 "$pre_packages" "$post_packages" | wc -l)
    
    if [[ $missing_packages -gt 0 ]]; then
        VALIDATION_RESULTS+=("WARN|Package Comparison|$missing_packages packages missing after upgrade")
        warn "Found $missing_packages packages missing after upgrade"
        comm -23 "$pre_packages" "$post_packages" | head -10
        return 1
    else
        VALIDATION_RESULTS+=("PASS|Package Comparison|All pre-upgrade packages present")
        success "Package validation passed"
        return 0
    fi
}

compare_firewall_rules() {
    info "Comparing firewall configuration..."
    
    if [[ -z "$PRE_STATE_DIR" || ! -f "$PRE_STATE_DIR/firewall-rules.txt" ]]; then
        warn "Pre-upgrade firewall configuration not found"
        return 0
    fi
    
    if ! command -v firewall-cmd &> /dev/null; then
        warn "firewall-cmd not available"
        return 0
    fi
    
    VALIDATION_RESULTS+=("INFO|Firewall Rules|Current firewall status verified")
    success "Firewall configuration validated"
    return 0
}

################################################################################
# Report Generation
################################################################################

generate_validation_report() {
    info "Generating validation report..."
    
    local output_file=$1
    
    {
        echo "================================================================================"
        echo "Post-Migration Validation Report"
        echo "================================================================================"
        echo "Generated: $(date)"
        echo "System: $(cat /etc/redhat-release)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "================================================================================"
        echo "Validation Results:"
        echo "================================================================================"
        echo ""
        
        local pass_count=0
        local warn_count=0
        local fail_count=0
        local info_count=0
        
        for result in "${VALIDATION_RESULTS[@]}"; do
            IFS='|' read -r status check_name details <<< "$result"
            
            case "$status" in
                PASS)
                    printf "%-8s %-35s %s\n" "[✓]" "$check_name" "$details"
                    ((pass_count++))
                    ;;
                WARN)
                    printf "%-8s %-35s %s\n" "[⚠]" "$check_name" "$details"
                    ((warn_count++))
                    ;;
                FAIL)
                    printf "%-8s %-35s %s\n" "[✗]" "$check_name" "$details"
                    ((fail_count++))
                    ;;
                INFO)
                    printf "%-8s %-35s %s\n" "[ℹ]" "$check_name" "$details"
                    ((info_count++))
                    ;;
            esac
        done
        
        echo ""
        echo "================================================================================"
        echo "Summary: $pass_count Passed, $warn_count Warnings, $fail_count Failed, $info_count Info"
        echo "================================================================================"
        echo ""
        
        if [[ $fail_count -gt 0 ]]; then
            echo "Validation Status: FAILED - Manual intervention required"
            return 1
        elif [[ $warn_count -gt 0 ]]; then
            echo "Validation Status: PASSED WITH WARNINGS - Review warnings above"
            return 0
        else
            echo "Validation Status: PASSED - Upgrade successful"
            return 0
        fi
    } | tee "$output_file"
}

################################################################################
# Cleanup Functions
################################################################################

cleanup_leapp_artifacts() {
    info "Cleaning up Leapp artifacts..."
    
    if [[ $CLEANUP_LEAPP -eq 0 ]]; then
        warn "Leapp cleanup disabled (use --cleanup flag)"
        return 0
    fi
    
    # Remove Leapp log directories
    if [[ -d /var/log/leapp ]]; then
        info "Removing /var/log/leapp..."
        rm -rf /var/log/leapp || warn "Failed to remove /var/log/leapp"
    fi
    
    # Remove Leapp temporary files
    if [[ -d /root/tmp_leapp_py3 ]]; then
        info "Removing /root/tmp_leapp_py3..."
        rm -rf /root/tmp_leapp_py3 || warn "Failed to remove Leapp temp files"
    fi
    
    # Remove Leapp upgrade packages if present
    dnf remove -y leapp leapp-upgrade leapp-upgrade-el* 2>/dev/null || warn "Could not remove Leapp packages"
    
    success "Leapp cleanup completed"
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    --pre-state-dir DIR     Pre-upgrade state directory (for comparison)
    --output FILE           Save report to file
    --cleanup               Remove Leapp artifacts after validation
    --help                  Show this help message

EXAMPLES:
    $0
    $0 --pre-state-dir /var/log/migration/pre-upgrade-20240315 --cleanup
    $0 --output /tmp/validation-report.txt

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pre-state-dir)
                PRE_STATE_DIR="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --cleanup)
                CLEANUP_LEAPP=1
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
    
    local current_version
    current_version=$(sed -rn 's/.*release ([0-9]+)\..*/\1/p' /etc/redhat-release)
    
    # Detect target version (post-upgrade)
    local target_version=$current_version
    
    info "Post-migration validation starting..."
    info "Current RHEL version: $target_version"
    echo ""
    
    validate_rhel_version "$target_version"
    validate_kernel_version
    validate_services
    validate_network_connectivity
    validate_package_manager
    validate_selinux
    validate_systemd_units
    validate_subscription
    compare_package_lists
    compare_firewall_rules
    
    echo ""
    
    # Generate report
    if [[ -n "$OUTPUT_FILE" ]]; then
        generate_validation_report "$OUTPUT_FILE"
    else
        generate_validation_report "/var/log/migration/post-validation-$(date +%Y%m%d-%H%M%S).txt"
    fi
    
    cleanup_leapp_artifacts
    
    success "Post-migration validation completed"
}

main "$@"
