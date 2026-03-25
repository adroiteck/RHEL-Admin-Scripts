#!/bin/bash

################################################################################
# Script: change-tracker.sh
# Description: Tracks configuration changes using RPM database
# Usage: ./change-tracker.sh --check [--baseline] [--compare]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, rpm, standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
CHECK_MODE=0
BASELINE_MODE=0
COMPARE_MODE=0
RHEL_VERSION=""
BASELINE_FILE="/var/lib/change-tracker/baseline.txt"
BASELINE_DIR="/var/lib/change-tracker"

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) CHECK_MODE=1 ;;
            --baseline) BASELINE_MODE=1 ;;
            --compare) COMPARE_MODE=1 ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi
}

# Verify system files with RPM
verify_rpm_files() {
    info "Verifying system files with RPM database..."
    echo ""

    if ! command -v rpm &> /dev/null; then
        error "rpm command not found"
        exit 1
    fi

    local changed_count=0
    local verify_output=$(rpm -V -a 2>/dev/null || echo "")

    if [[ -z "$verify_output" ]]; then
        success "No configuration file changes detected"
        return 0
    fi

    # Parse rpm -V output
    echo "$verify_output" | while read -r line; do
        local status=$(echo "$line" | awk '{print $1}')
        local file=$(echo "$line" | awk '{print $NF}')

        # Decode status flags
        if [[ "$status" =~ ^M ]]; then
            warn "  Modified: $file"
            changed_count=$((changed_count + 1))
        fi
        if [[ "$status" =~ ^S ]]; then
            info "  Size changed: $file"
        fi
        if [[ "$status" =~ ^T ]]; then
            info "  Time changed: $file"
        fi
        if [[ "$status" =~ ^5 ]]; then
            warn "  Checksum changed: $file"
        fi
    done

    echo ""
    if [[ $changed_count -gt 0 ]]; then
        warn "Total modified files: $changed_count"
    else
        success "Configuration files intact"
    fi
}

# Find files not owned by any package
find_unowned_files() {
    info "Scanning for files not owned by any package..."
    echo ""

    if ! command -v rpm &> /dev/null; then
        warn "rpm not available"
        return
    fi

    local unowned=0
    local checked=0

    # Sample critical directories
    for dir in /etc /opt /usr/local; do
        [[ ! -d "$dir" ]] && continue

        while IFS= read -r file; do
            [[ -L "$file" ]] && continue  # Skip symlinks
            [[ ! -f "$file" ]] && continue

            if ! rpm -qf "$file" > /dev/null 2>&1; then
                warn "  Unowned: $file"
                unowned=$((unowned + 1))
            fi

            checked=$((checked + 1))
            [[ $checked -gt 100 ]] && break
        done < <(find "$dir" -type f -mtime -30 2>/dev/null | head -100)

        [[ $checked -gt 100 ]] && break
    done

    echo ""
    info "Files checked: $checked"
    if [[ $unowned -gt 0 ]]; then
        warn "Unowned files: $unowned (potential manual installations)"
    fi
}

# Create baseline configuration snapshot
create_baseline() {
    info "Creating baseline configuration snapshot..."

    mkdir -p "$BASELINE_DIR"

    {
        echo "=== Baseline Configuration Snapshot ==="
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "RHEL Version: $RHEL_VERSION"
        echo ""

        echo "=== Modified Config Files (rpm -V) ==="
        rpm -V -a 2>/dev/null | grep "^M" || echo "None"
        echo ""

        echo "=== /etc Directory Checksum ==="
        find /etc -type f 2>/dev/null | xargs md5sum 2>/dev/null | sort > "${BASELINE_DIR}/etc.checksums.baseline"
        echo "Baseline created: ${BASELINE_DIR}/etc.checksums.baseline"
        echo ""

        echo "=== Installed Packages ==="
        rpm -qa --queryformat='%{NAME}-%{VERSION}-%{RELEASE}\n' | sort > "${BASELINE_DIR}/packages.baseline"
        echo "Packages: $(wc -l < ${BASELINE_DIR}/packages.baseline)"
        echo ""

        echo "=== File Statistics ==="
        find /etc -type f 2>/dev/null | wc -l | awk '{print "Files in /etc: " $1}'
        echo ""

    } | tee "$BASELINE_FILE"

    success "Baseline saved to: $BASELINE_FILE"
}

# Compare current state with baseline
compare_with_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run --baseline first"
        exit 1
    fi

    info "Comparing current state with baseline..."
    echo ""

    # Compare packages
    if [[ -f "${BASELINE_DIR}/packages.baseline" ]]; then
        info "Package changes:"
        local current_packages=$(rpm -qa --queryformat='%{NAME}-%{VERSION}-%{RELEASE}\n' | sort)
        local baseline_packages=$(cat "${BASELINE_DIR}/packages.baseline")

        local added=$(comm -23 <(echo "$current_packages") <(echo "$baseline_packages") | wc -l)
        local removed=$(comm -13 <(echo "$current_packages") <(echo "$baseline_packages") | wc -l)

        if [[ $added -gt 0 ]]; then
            warn "  Packages added: $added"
            comm -23 <(echo "$current_packages") <(echo "$baseline_packages") | head -5
        fi

        if [[ $removed -gt 0 ]]; then
            warn "  Packages removed: $removed"
            comm -13 <(echo "$current_packages") <(echo "$baseline_packages") | head -5
        fi

        if [[ $added -eq 0 && $removed -eq 0 ]]; then
            success "  No package changes"
        fi
    fi

    echo ""

    # Compare checksums
    if [[ -f "${BASELINE_DIR}/etc.checksums.baseline" ]]; then
        info "Configuration file changes:"
        local current_checksums=$(find /etc -type f 2>/dev/null | xargs md5sum 2>/dev/null | sort)
        local baseline_checksums=$(cat "${BASELINE_DIR}/etc.checksums.baseline")

        local changed=$(comm -13 <(echo "$baseline_checksums") <(echo "$current_checksums") | wc -l)

        if [[ $changed -gt 0 ]]; then
            warn "  Files changed: $changed"
            comm -13 <(echo "$baseline_checksums") <(echo "$current_checksums") | head -5
        else
            success "  No configuration changes"
        fi
    fi

    echo ""
}

# Report on configuration drift
report_drift() {
    info "=== Configuration Drift Report ==="
    echo ""

    success "Configuration Management Status:"
    echo ""
    echo "  [Check] RPM file verification"
    echo "  [Check] Unowned files detection"
    echo "  [Check] Package inventory"
    echo "  [Check] Configuration checksums"

    echo ""
    info "Recommendations:"
    echo "  1. Review modified config files"
    echo "  2. Remove unauthorized packages"
    echo "  3. Investigate unowned files"
    echo "  4. Document intentional changes"

    echo ""
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel

    {
        info "=== Configuration Change Tracker ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        if [[ $BASELINE_MODE -eq 1 ]]; then
            create_baseline
            echo ""
            report_drift
        elif [[ $COMPARE_MODE -eq 1 ]]; then
            compare_with_baseline
            echo ""
            report_drift
        elif [[ $CHECK_MODE -eq 1 ]]; then
            verify_rpm_files
            find_unowned_files
            echo ""
            report_drift
        else
            verify_rpm_files
        fi
    }
}

main "$@"
