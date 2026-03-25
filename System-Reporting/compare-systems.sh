#!/bin/bash

################################################################################
# Script: compare-systems.sh
# Description: Generates system profiles for comparison between systems
# Usage: ./compare-systems.sh --action capture [--profile FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
ACTION=""
PROFILE_FILE=""
RHEL_VERSION=""
SYSTEM_NAME=$(hostname)

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action) ACTION="$2"; shift ;;
            --profile) PROFILE_FILE="$2"; shift ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Detect RHEL version
detect_rhel() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi
}

# Validate action
validate_action() {
    if [[ -z "$ACTION" ]]; then
        error "Action is required (use --action capture|compare)"
        exit 1
    fi

    case "$ACTION" in
        capture|compare) return 0 ;;
        *) error "Unknown action: $ACTION"; exit 1 ;;
    esac
}

# Capture system profile
capture_profile() {
    if [[ -z "$PROFILE_FILE" ]]; then
        PROFILE_FILE="system-profile-${SYSTEM_NAME}-$(date '+%Y%m%d-%H%M%S').txt"
    fi

    info "Capturing system profile to: $PROFILE_FILE"

    {
        echo "=== System Profile ==="
        echo "System: $SYSTEM_NAME"
        echo "RHEL Version: $RHEL_VERSION"
        echo "Capture Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo "=== Installed Packages ==="
        if command -v rpm &> /dev/null; then
            rpm -qa --queryformat='%{NAME}-%{VERSION}-%{RELEASE}\n' | sort
        fi
        echo ""

        echo "=== Enabled Services ==="
        if command -v systemctl &> /dev/null; then
            systemctl list-unit-files --type=service --state=enabled --no-pager | grep "^[a-z]" | awk '{print $1}' | sort
        fi
        echo ""

        echo "=== Running Services ==="
        if command -v systemctl &> /dev/null; then
            systemctl list-units --type=service --state=running --no-pager | grep "^[a-z]" | awk '{print $1}' | sort
        fi
        echo ""

        echo "=== Firewall Rules ==="
        if command -v firewall-cmd &> /dev/null; then
            firewall-cmd --list-all 2>/dev/null | head -30
        else
            echo "Firewall not configured"
        fi
        echo ""

        echo "=== Kernel Parameters ==="
        sysctl -a 2>/dev/null | grep -v "^#" | sort
        echo ""

        echo "=== User Accounts (non-system) ==="
        awk -F: '$3 >= 1000 {print $1}' /etc/passwd | sort
        echo ""

        echo "=== Network Interfaces ==="
        ip addr show | grep -E "^[0-9]+:|inet " | head -30
        echo ""

        echo "=== Mount Points ==="
        mount | grep -v "^proc\|^sys\|^dev\|^run" | sort
        echo ""

        echo "=== Open Ports ==="
        if command -v ss &> /dev/null; then
            ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | sort
        fi
        echo ""

    } > "$PROFILE_FILE"

    success "Profile captured: $PROFILE_FILE"
    info "Size: $(du -sh "$PROFILE_FILE" | awk '{print $1}')"
}

# Compare two profiles
compare_profiles() {
    if [[ -z "$PROFILE_FILE" ]]; then
        error "Profile files required (use --profile FILE1 for first, then again for FILE2)"
        exit 1
    fi

    # Need two profile files
    read -p "Enter second profile file to compare with: " profile2

    if [[ ! -f "$PROFILE_FILE" ]]; then
        error "First profile not found: $PROFILE_FILE"
        exit 1
    fi

    if [[ ! -f "$profile2" ]]; then
        error "Second profile not found: $profile2"
        exit 1
    fi

    info "Comparing profiles..."
    echo ""

    # Extract sections from both profiles
    local pkg1=$(awk '/^=== Installed Packages ===/,/^===/' "$PROFILE_FILE" | grep "^[a-z]" | sort)
    local pkg2=$(awk '/^=== Installed Packages ===/,/^===/' "$profile2" | grep "^[a-z]" | sort)

    success "=== Package Differences ==="
    diff <(echo "$pkg1") <(echo "$pkg2") | head -20 || true
    echo ""

    # Compare services
    local svc1=$(awk '/^=== Enabled Services ===/,/^===/' "$PROFILE_FILE" | grep "^[a-z]" | sort)
    local svc2=$(awk '/^=== Enabled Services ===/,/^===/' "$profile2" | grep "^[a-z]" | sort)

    success "=== Service Differences ==="
    diff <(echo "$svc1") <(echo "$svc2") | head -20 || true
    echo ""

    # Compare users
    local usr1=$(awk '/^=== User Accounts/,/^===/' "$PROFILE_FILE" | grep "^[a-z]" | sort)
    local usr2=$(awk '/^=== User Accounts/,/^===/' "$profile2" | grep "^[a-z]" | sort)

    success "=== User Account Differences ==="
    diff <(echo "$usr1") <(echo "$usr2") | head -20 || true
    echo ""

    success "Comparison complete"
}

# List available profiles
list_profiles() {
    echo ""
    info "Available system profiles:"
    echo ""

    if ls system-profile-* 2>/dev/null; then
        true
    else
        warn "No profiles found"
    fi

    echo ""
}

# Validate profile
validate_profile() {
    if [[ ! -f "$PROFILE_FILE" ]]; then
        error "Profile file not found: $PROFILE_FILE"
        exit 1
    fi

    info "Profile details:"
    echo ""
    head -10 "$PROFILE_FILE"
    echo ""
    success "Profile is valid"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel
    validate_action

    {
        info "=== System Profile Comparison Tool ==="
        info "RHEL Version: $RHEL_VERSION"
        info "System: $SYSTEM_NAME"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        case "$ACTION" in
            capture)
                capture_profile
                echo ""
                list_profiles
                ;;
            compare)
                if [[ -n "$PROFILE_FILE" ]]; then
                    validate_profile
                    echo ""
                fi
                compare_profiles
                ;;
        esac
    }
}

main "$@"
