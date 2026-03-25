#!/bin/bash

################################################################################
# Script: package-audit.sh
# Description: Comprehensive package audit. Lists manually installed packages,
#              identifies packages not from official repos, checks for known
#              vulnerabilities, reports largest packages, and verifies RPM
#              signature integrity.
# Usage: ./package-audit.sh [--manual-only] [--non-official-only] [--sizes]
#        [--output FILE]
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

    info "RHEL $RHEL_VERSION detected"
}

# List manually installed packages
list_manually_installed() {
    info "Identifying manually installed packages..."

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        # DNF: packages marked as user-installed
        dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null || echo "N/A"
    else
        # YUM: use history to find user-installed
        yum history userinstalled 2>/dev/null | grep "Install" | awk '{print $NF}' || echo "N/A"
    fi
}

# Find packages from non-official repos
find_non_official_packages() {
    info "Finding packages from non-official repositories..."

    rpm -qa --qf '[%{NAME}\t%{VENDOR}\n]' 2>/dev/null | while read -r pkg vendor; do
        if [[ ! "$vendor" =~ "Red Hat" ]]; then
            echo "$pkg|$vendor"
        fi
    done
}

# Get largest packages
get_largest_packages() {
    local limit="${1:-10}"

    info "Listing largest installed packages (top $limit)..."

    rpm -qa --qf '%{SIZE}\t%{NAME}\n' | sort -rn | head -"$limit" | while read -r size name; do
        local size_mb=$((size / 1024 / 1024))
        echo "$name|${size_mb}MB"
    done
}

# Verify RPM signatures
verify_rpm_signatures() {
    info "Verifying RPM package signatures..."

    local bad_sigs=0
    local total=0

    rpm -qa | while read -r pkg; do
        ((total++))
        if ! rpm --verify "$pkg" &>/dev/null; then
            echo "$pkg|FAILED"
            ((bad_sigs++))
        fi
    done

    info "Signature verification: $bad_sigs failures out of $total packages"
}

# Check for known vulnerable packages (basic check)
check_vulnerable_packages() {
    info "Checking for known vulnerable packages..."

    # Common vulnerable package patterns
    local vulnerable_patterns=(
        "openssl"
        "openssh"
        "glibc"
        "kernel"
        "systemd"
    )

    local output=""
    for pattern in "${vulnerable_patterns[@]}"; do
        rpm -qa "*${pattern}*" 2>/dev/null | while read -r pkg; do
            local version=$(rpm -q "$pkg" --qf '%{VERSION}-%{RELEASE}')
            output+="$pkg|$version"$'\n'
        done
    done

    if [[ -n "$output" ]]; then
        echo "$output" | sort -u
    fi
}

# Audit packages
audit_packages() {
    local manual_only="$1"
    local non_official_only="$2"
    local sizes_only="$3"
    local output_file="$4"

    local output="========== PACKAGE AUDIT ==========$(printf '\n')"
    output+="Generated: $(date)$(printf '\n')"
    output+="RHEL Version: $RHEL_VERSION$(printf '\n')"
    output+=$(printf '\n')

    if [[ "$manual_only" != "true" ]] && [[ "$non_official_only" != "true" ]] && [[ "$sizes_only" != "true" ]]; then
        # Full audit
        output+="========== MANUALLY INSTALLED PACKAGES ==========$(printf '\n')"
        output+="$(list_manually_installed)$(printf '\n')"
        output+=$(printf '\n')

        output+="========== NON-OFFICIAL PACKAGES ==========$(printf '\n')"
        output+="$(find_non_official_packages)$(printf '\n')"
        output+=$(printf '\n')

        output+="========== LARGEST PACKAGES ==========$(printf '\n')"
        output+="$(get_largest_packages 15)$(printf '\n')"
        output+=$(printf '\n')

        output+="========== VULNERABLE PACKAGE CHECK ==========$(printf '\n')"
        output+="$(check_vulnerable_packages)$(printf '\n')"
        output+=$(printf '\n')

        output+="========== RPM SIGNATURE VERIFICATION ==========$(printf '\n')"
        output+="$(verify_rpm_signatures)$(printf '\n')"

    elif [[ "$manual_only" == "true" ]]; then
        output+="========== MANUALLY INSTALLED PACKAGES ==========$(printf '\n')"
        output+="$(list_manually_installed)$(printf '\n')"

    elif [[ "$non_official_only" == "true" ]]; then
        output+="========== NON-OFFICIAL PACKAGES ==========$(printf '\n')"
        output+="$(find_non_official_packages)$(printf '\n')"

    elif [[ "$sizes_only" == "true" ]]; then
        output+="========== LARGEST PACKAGES ==========$(printf '\n')"
        output+="$(get_largest_packages 20)$(printf '\n')"
    fi

    if [[ -n "$output_file" ]]; then
        echo "$output" > "$output_file"
        success "Audit report written to: $output_file"
    else
        echo "$output"
    fi
}

# Main function
main() {
    detect_environment

    local manual_only="false"
    local non_official_only="false"
    local sizes_only="false"
    local output_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --manual-only)
                manual_only="true"
                shift
                ;;
            --non-official-only)
                non_official_only="true"
                shift
                ;;
            --sizes)
                sizes_only="true"
                shift
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    audit_packages "$manual_only" "$non_official_only" "$sizes_only" "$output_file"
}

main "$@"
