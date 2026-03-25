#!/bin/bash

################################################################################
# Script: timer-audit.sh
# Description: Audit systemd timers and identify inactive/problematic timers
# Usage: ./timer-audit.sh [--verbose]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with systemd
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly STALE_DAYS=7

# Color output functions
info() {
    echo -e "\033[0;36m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

error() {
    echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $*"
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Check if systemd is available
check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        error "systemctl not found. This script requires systemd."
        exit 1
    fi
}

# Convert systemd time format to readable format
format_systemd_time() {
    local timestr="$1"

    if [[ -z "$timestr" || "$timestr" == "n/a" || "$timestr" == "-" ]]; then
        echo "Never"
        return
    fi

    # Try to parse ISO 8601 format
    if [[ "$timestr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        date -d "$timestr" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$timestr"
    else
        echo "$timestr"
    fi
}

# Calculate days since last run
days_since() {
    local last_run="$1"

    if [[ "$last_run" == "Never" || -z "$last_run" ]]; then
        echo "N/A"
        return
    fi

    local last_epoch=$(date -d "$last_run" +%s 2>/dev/null || echo "0")
    if [[ "$last_epoch" -eq 0 ]]; then
        echo "N/A"
        return
    fi

    local current_epoch=$(date +%s)
    local diff=$((current_epoch - last_epoch))
    local days=$((diff / 86400))

    echo "$days"
}

# Get timer unit file
get_timer_unit() {
    local timer="$1"

    if [[ ! -f "/etc/systemd/system/$timer.timer" && ! -f "/usr/lib/systemd/system/$timer.timer" ]]; then
        echo "Not found"
        return 1
    fi

    if [[ -f "/etc/systemd/system/$timer.timer" ]]; then
        echo "/etc/systemd/system/$timer.timer"
    else
        echo "/usr/lib/systemd/system/$timer.timer"
    fi
}

# Audit all timers
audit_timers() {
    local verbose="${1:-false}"

    info "Scanning for systemd timers..."

    local timers=()
    local active_count=0 inactive_count=0 stale_count=0

    # Get list of all timers
    mapfile -t timers < <(systemctl list-timers --all --no-pager | tail -n +2 | awk '{print $NF}' | sed 's/\.timer$//' | sort -u)

    if [[ ${#timers[@]} -eq 0 ]]; then
        warn "No systemd timers found"
        return
    fi

    info "Found ${#timers[@]} timer(s)"
    echo ""

    # Print header
    printf "%-50s %-10s %-15s %-20s %s\n" "TIMER" "ENABLED" "NEXT RUN" "LAST RUN" "DAYS SINCE"
    printf "%s\n" "$(printf '=%.0s' {1..120})"

    for timer in "${timers[@]}"; do
        [[ -z "$timer" ]] && continue

        # Get timer properties
        local enabled=$(systemctl is-enabled "$timer.timer" 2>/dev/null || echo "unknown")
        local next_run=$(systemctl show "$timer.timer" -p NextElapseUSecMonotonic --value 2>/dev/null || echo "n/a")
        local last_run=$(systemctl show "$timer.timer" -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
        local active=$(systemctl is-active "$timer.timer" 2>/dev/null || echo "inactive")

        # Format times
        next_run=$(format_systemd_time "$next_run")
        last_run=$(format_systemd_time "$last_run")
        local days=$(days_since "$last_run")

        # Determine status
        if [[ "$enabled" == "enabled" && "$active" == "active" ]]; then
            ((active_count++))
        elif [[ "$enabled" == "disabled" || "$active" == "inactive" ]]; then
            ((inactive_count++))
            if [[ "$enabled" == "disabled" ]]; then
                timer="$timer (disabled)"
            fi
        fi

        # Flag stale timers
        if [[ "$days" != "N/A" && "$days" -gt "$STALE_DAYS" ]]; then
            ((stale_count++))
            warn "Stale: $timer (last run $days days ago)"
        fi

        printf "%-50s %-10s %-15s %-20s %s\n" "$timer" "$enabled" "$next_run" "$last_run" "${days} days"
    done

    echo ""
    echo "$(printf '=%.0s' {1..120})"
    success "Summary: ${#timers[@]} total, $active_count active, $inactive_count inactive, $stale_count stale"

    if [[ "$stale_count" -gt 0 ]]; then
        warn "Found $stale_count timer(s) that haven't run in $STALE_DAYS+ days"
    fi

    if [[ "$verbose" == "true" ]]; then
        echo ""
        info "Verbose output enabled - showing timer details..."
        for timer in "${timers[@]}"; do
            [[ -z "$timer" ]] && continue
            echo ""
            echo "Timer: $timer"
            systemctl show "$timer.timer" --all 2>/dev/null | head -20
        done
    fi
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --verbose    Show detailed timer information
  --help       Show this help message

Examples:
  $(basename "$0")              # List all timers with status
  $(basename "$0") --verbose    # Show detailed timer information

EOF
}

# Main execution
main() {
    local verbose=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose) verbose=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    detect_rhel_version
    check_systemd

    info "RHEL Version: $RHEL_VERSION"
    echo ""

    audit_timers "$verbose"
}

main "$@"
