#!/bin/bash

################################################################################
# prepare-leapp-upgrade.sh - Prepare System for Leapp In-Place Upgrade
################################################################################
# Description: Installs Leapp packages, runs preupgrade, and handles inhibitors.
#              Prepares the system for RHEL in-place upgrade using Leapp.
# Usage: ./prepare-leapp-upgrade.sh --target 8|9 [--auto-fix] [--dry-run]
# Author: Migration Team
# Compatibility: RHEL 7.x, RHEL 8.x
################################################################################

set -euo pipefail

TARGET_VERSION=""
AUTO_FIX=0
DRY_RUN=0
LEAPP_REPORT="/var/log/leapp/leapp-report.txt"

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
    local rhel_version
    rhel_version=$(sed -rn 's/.*release ([0-9]+)\..*/\1/p' /etc/redhat-release)
    echo "$rhel_version"
}

################################################################################
# Package Management Functions
################################################################################

install_leapp_packages() {
    local target_version=$1
    
    info "Installing Leapp packages..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would run: dnf install -y leapp leapp-upgrade"
        return 0
    fi
    
    if ! dnf install -y leapp leapp-upgrade &> /dev/null; then
        error "Failed to install leapp packages"
        return 1
    fi
    
    if [[ "$target_version" == "8" ]]; then
        info "Installing leapp-upgrade-el7toel8..."
        if ! dnf install -y leapp-upgrade-el7toel8 &> /dev/null; then
            error "Failed to install leapp-upgrade-el7toel8"
            return 1
        fi
    elif [[ "$target_version" == "9" ]]; then
        info "Installing leapp-upgrade-el8toel9..."
        if ! dnf install -y leapp-upgrade-el8toel9 &> /dev/null; then
            error "Failed to install leapp-upgrade-el8toel9"
            return 1
        fi
    fi
    
    success "Leapp packages installed successfully"
    return 0
}

configure_subscription_repos() {
    local target_version=$1
    
    info "Configuring subscription repositories for target version..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would configure repos for RHEL $target_version"
        return 0
    fi
    
    if ! subscription-manager identity &> /dev/null; then
        warn "System not registered with subscription manager"
        return 1
    fi
    
    if [[ "$target_version" == "8" ]]; then
        subscription-manager repos --disable='*' &> /dev/null || true
        subscription-manager repos \
            --enable=rhel-7-server-rpms \
            --enable=rhel-7-server-extras-rpms \
            --enable=rhel-7-server-optional-rpms &> /dev/null || true
    elif [[ "$target_version" == "9" ]]; then
        subscription-manager repos --disable='*' &> /dev/null || true
        subscription-manager repos \
            --enable=rhel-8-for-x86_64-baseos-rpms \
            --enable=rhel-8-for-x86_64-appstream-rpms \
            --enable=rhel-8-for-x86_64-extras-rpms &> /dev/null || true
    fi
    
    success "Repository configuration updated"
    return 0
}

################################################################################
# Leapp Preupgrade Functions
################################################################################

run_leapp_preupgrade() {
    info "Running leapp preupgrade analysis..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would run: leapp preupgrade"
        return 0
    fi
    
    mkdir -p /var/log/leapp
    
    if leapp preupgrade 2>&1 | tee /tmp/leapp-preupgrade.log; then
        success "Leapp preupgrade completed"
        return 0
    else
        warn "Leapp preupgrade reported warnings or errors (check /var/log/leapp/leapp-report.txt)"
        return 0
    fi
}

parse_leapp_inhibitors() {
    info "Parsing leapp inhibitors..."
    
    if [[ ! -f "$LEAPP_REPORT" ]]; then
        warn "Leapp report not found at $LEAPP_REPORT"
        return 1
    fi
    
    echo ""
    echo "================================================================================"
    echo "Leapp Inhibitors and Issues:"
    echo "================================================================================"
    
    # Extract inhibitors from the report
    grep -A 5 "^INHIBITOR:" "$LEAPP_REPORT" 2>/dev/null | head -50 || {
        info "No explicit INHIBITOR section found, checking report content..."
    }
    
    # Check for common blocking issues
    if grep -q "pam_pkcs11" "$LEAPP_REPORT" 2>/dev/null; then
        echo "- WARNING: pam_pkcs11 module detected (may block upgrade)"
        echo "  FIX: dnf remove pam_pkcs11"
    fi
    
    if grep -q "network-scripts" "$LEAPP_REPORT" 2>/dev/null; then
        echo "- INFO: network-scripts detected (legacy network configuration)"
        echo "  FIX: Plan migration to NetworkManager"
    fi
    
    if grep -q "custom-kernel" "$LEAPP_REPORT" 2>/dev/null; then
        echo "- WARNING: Custom kernel detected (may need special handling)"
    fi
    
    echo "================================================================================"
    echo ""
}

################################################################################
# Auto-Fix Functions
################################################################################

auto_fix_inhibitors() {
    info "Attempting to auto-fix common inhibitors..."
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would attempt auto-fixes"
        return 0
    fi
    
    # Fix pam_pkcs11
    if rpm -q pam_pkcs11 &> /dev/null; then
        warn "Removing pam_pkcs11..."
        dnf remove -y pam_pkcs11 &> /dev/null && success "pam_pkcs11 removed" || warn "Failed to remove pam_pkcs11"
    fi
    
    # Create answers file for common Leapp questions
    create_leapp_answers_file
    
    success "Auto-fix attempts completed"
}

create_leapp_answers_file() {
    info "Creating Leapp answers file..."
    
    local answers_dir="/var/log/leapp/answers"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY-RUN: Would create answers file at $answers_dir"
        return 0
    fi
    
    mkdir -p "$answers_dir"
    
    # Create answers for common Leapp prompts
    cat > "$answers_dir/leapp-upgrade.txt" << 'ANSWERS'
confirm = "yes"
ANSWERS
    
    success "Leapp answers file created"
}

################################################################################
# Validation Functions
################################################################################

validate_leapp_installation() {
    info "Validating Leapp installation..."
    
    if ! command -v leapp &> /dev/null; then
        error "Leapp command not found after installation"
        return 1
    fi
    
    leapp --version || true
    success "Leapp installation validated"
    return 0
}

################################################################################
# Usage and Argument Parsing
################################################################################

usage() {
    cat << EOF
Usage: $0 --target <8|9> [OPTIONS]

OPTIONS:
    --target <8|9>      Target RHEL version (required)
    --auto-fix          Automatically fix common inhibitors
    --dry-run           Show what would be done without making changes
    --help              Show this help message

EXAMPLES:
    $0 --target 8
    $0 --target 9 --auto-fix
    $0 --target 8 --dry-run

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                TARGET_VERSION="$2"
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
    
    info "Preparing system for RHEL $current_version -> RHEL $TARGET_VERSION upgrade"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        warn "DRY-RUN MODE: No actual changes will be made"
        echo ""
    fi
    
    install_leapp_packages "$TARGET_VERSION" || exit 1
    validate_leapp_installation || exit 1
    configure_subscription_repos "$TARGET_VERSION" || true
    run_leapp_preupgrade || true
    parse_leapp_inhibitors
    
    if [[ $AUTO_FIX -eq 1 ]]; then
        auto_fix_inhibitors
    fi
    
    echo ""
    success "Leapp preparation completed"
    info "Next steps:"
    echo "  1. Review any remaining inhibitors in /var/log/leapp/leapp-report.txt"
    echo "  2. Run: ./execute-upgrade.sh --target $TARGET_VERSION"
    echo ""
}

main "$@"
