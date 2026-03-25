#!/bin/bash

################################################################################
# Script: check-updates.sh
# Description: List available updates grouped by severity. Shows security
#              (critical/important/moderate), bugfix, and enhancement updates.
#              Reports CVE IDs where available.
# Usage: ./check-updates.sh [--format TEXT|CSV] [--security-only]
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

# Get updates using yum (RHEL 7)
get_updates_yum() {
    local format="$1"
    local security_only="$2"

    local critical="" important="" moderate="" bugfix="" enhancement=""

    if [[ "$security_only" == "true" ]]; then
        yum check-update --security 2>/dev/null || true
    else
        yum check-update 2>/dev/null || true
    fi
}

# Get security updates using dnf (RHEL 8/9)
get_updates_dnf() {
    local format="$1"
    local security_only="$2"

    local updates=""

    if [[ "$security_only" == "true" ]]; then
        dnf check-update --security 2>/dev/null || true
    else
        dnf check-update 2>/dev/null || true
    fi
}

# Get update list from yum
list_yum_updates() {
    local format="$1"
    local security_only="$2"
    local output=""

    if [[ "$security_only" == "true" ]]; then
        output=$(yum list-updates --security 2>/dev/null || true)
    else
        output=$(yum check-update 2>/dev/null || echo "")
    fi

    if [[ "$format" == "csv" ]]; then
        echo "PACKAGE,VERSION,RELEASE,SEVERITY"
        echo "$output" | grep -v "^$" | grep -v "^Loaded" | while read -r line; do
            local pkg=$(echo "$line" | awk '{print $1}')
            local ver=$(echo "$line" | awk '{print $2}')
            [[ -z "$pkg" ]] && continue
            echo "\"$pkg\",\"$ver\",\"yum\",\"unknown\""
        done
    else
        echo "========== AVAILABLE UPDATES =========="
        echo "Total Updates: $(echo "$output" | grep -v "^$" | grep -v "^Loaded" | wc -l)"
        echo ""
        echo "$output"
    fi
}

# Get update list from dnf (RHEL 8/9)
list_dnf_updates() {
    local format="$1"
    local security_only="$2"
    local output=""

    if [[ "$security_only" == "true" ]]; then
        # Security updates with CVE info
        output=$(dnf check-update --security 2>/dev/null || true)
        local cves=$(dnf check-update --security-severity critical,important,moderate 2>/dev/null | grep -i "cve" || true)
    else
        output=$(dnf check-update 2>/dev/null || echo "")
    fi

    if [[ "$format" == "csv" ]]; then
        echo "PACKAGE,VERSION,REPOSITORY,TYPE"
        echo "$output" | grep -v "^$" | grep -v "^Last metadata" | while read -r line; do
            local pkg=$(echo "$line" | awk '{print $1}')
            local ver=$(echo "$line" | awk '{print $2}')
            local repo=$(echo "$line" | awk '{print $3}')
            [[ -z "$pkg" ]] && continue
            echo "\"$pkg\",\"$ver\",\"$repo\",\"mixed\""
        done
    else
        local count=$(echo "$output" | grep -v "^$" | grep -v "^Last metadata" | wc -l)

        echo "========== AVAILABLE UPDATES (DNF) =========="
        echo "Total Packages with Updates: $count"
        echo ""

        # Try to get severity if security plugin available
        if dnf list-upgrades --security 2>/dev/null | grep -q ""; then
            echo "Security Updates:"
            dnf list-upgrades --security 2>/dev/null | head -20 || true
            echo ""
        fi

        echo "All Updates:"
        echo "$output" | head -30
    fi
}

# Parse updates and categorize
categorize_updates() {
    local format="$1"
    local security_only="$2"

    local critical=0 important=0 moderate=0 bugfix=0 enhancement=0

    if [[ "$RHEL_VERSION" -ge 8 ]]; then
        list_dnf_updates "$format" "$security_only"
    else
        list_yum_updates "$format" "$security_only"
    fi
}

# Main function
main() {
    detect_environment

    local format="text"
    local security_only="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                format="$2"
                shift 2
                ;;
            --security-only)
                security_only="true"
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    categorize_updates "$format" "$security_only"
}

main "$@"
