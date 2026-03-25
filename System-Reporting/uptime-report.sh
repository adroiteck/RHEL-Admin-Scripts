#!/bin/bash

################################################################################
# Script: uptime-report.sh
# Description: Tracks and reports system uptime and reboot history
# Usage: ./uptime-report.sh [--days 90] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root access recommended, wtmp, lastb
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
DAYS=90
OUTPUT_FILE=""
RHEL_VERSION=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) DAYS="$2"; shift ;;
            --output) OUTPUT_FILE="$2"; shift ;;
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

# Get current uptime
get_current_uptime() {
    local uptime_sec=$(cat /proc/uptime | awk '{print int($1)}')
    local days=$((uptime_sec / 86400))
    local hours=$(((uptime_sec % 86400) / 3600))
    local minutes=$(((uptime_sec % 3600) / 60))

    echo "$days days, $hours hours, $minutes minutes"
}

# Get last boot time
get_last_boot_time() {
    if command -v systemd-analyze &> /dev/null; then
        systemd-analyze 2>/dev/null | grep "Startup finished" | head -1 || echo "N/A"
    else
        who -b 2>/dev/null | awk '{print $3, $4}' || echo "N/A"
    fi
}

# Analyze reboot history from wtmp
analyze_reboot_history() {
    info "System reboot history (last $DAYS days):"
    echo ""

    if [[ ! -f /var/log/wtmp ]]; then
        warn "wtmp file not found"
        return
    fi

    # Use last command to show reboots
    if command -v last &> /dev/null; then
        last reboot 2>/dev/null | head -20 | while read -r line; do
            echo "  $line"
        done
    else
        warn "last command not available"
    fi
}

# Count unplanned shutdowns
count_unplanned_shutdowns() {
    info "Analyzing unplanned shutdowns..."
    echo ""

    local unplanned=0

    if [[ -f /var/log/messages ]]; then
        unplanned=$(grep -i "kernel panic\|kernel oops\|emergency reboot\|forced reboot" /var/log/messages 2>/dev/null | wc -l)
    fi

    if [[ $unplanned -gt 0 ]]; then
        error "Unplanned shutdowns detected: $unplanned"
    else
        success "No unplanned shutdowns detected"
    fi

    echo ""
}

# Calculate average uptime
calculate_average_uptime() {
    info "Average uptime calculation (over $DAYS days):"
    echo ""

    if [[ ! -f /var/log/wtmp ]]; then
        warn "wtmp file not available"
        return
    fi

    # Get current uptime in days
    local current_uptime=$(cat /proc/uptime | awk '{printf "%.1f", $1 / 86400}')
    success "Current uptime: $current_uptime days"

    # Try to calculate from boot times
    if command -v last &> /dev/null; then
        local total_boots=$(last reboot 2>/dev/null | wc -l)
        local avg_uptime=$(echo "scale=1; 90 / $total_boots" | bc 2>/dev/null || echo "N/A")

        if [[ "$avg_uptime" != "N/A" ]]; then
            success "Average uptime per cycle: $avg_uptime days"
        fi

        success "Total boot cycles (90 days): $total_boots"
    fi

    echo ""
}

# Check kernel panic messages
check_kernel_panics() {
    info "Checking for kernel panic messages..."
    echo ""

    if [[ ! -f /var/log/messages ]]; then
        warn "Messages log not found"
        return
    fi

    local panic_count=$(grep -ci "kernel panic" /var/log/messages 2>/dev/null || echo 0)
    local oops_count=$(grep -ci "kernel oops" /var/log/messages 2>/dev/null || echo 0)

    if [[ $panic_count -gt 0 ]]; then
        error "Kernel panics: $panic_count"
    else
        success "Kernel panics: 0"
    fi

    if [[ $oops_count -gt 0 ]]; then
        error "Kernel oops: $oops_count"
    else
        success "Kernel oops: 0"
    fi

    echo ""
}

# Generate uptime statistics
generate_statistics() {
    info "=== Uptime Statistics ==="
    echo ""

    local uptime=$(cat /proc/uptime | awk '{print int($1)}')
    local boot_time=$(date -d "-$uptime seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

    success "Current uptime: $(get_current_uptime)"
    info "Last boot: $boot_time"

    echo ""
}

# Get detailed boot times
get_boot_times() {
    info "Recent boot times (last 10):"
    echo ""

    if command -v last &> /dev/null && [[ -f /var/log/wtmp ]]; then
        last reboot -f /var/log/wtmp 2>/dev/null | head -10 | while read -r line; do
            [[ -z "$line" ]] && continue
            echo "  $line"
        done
    else
        warn "Boot time history not available"
    fi

    echo ""
}

# Check systemd journal for boot info
check_journal_boots() {
    if ! command -v journalctl &> /dev/null; then
        return
    fi

    info "systemd journal boot count:"
    echo ""

    journalctl --list-boots 2>/dev/null | head -10 | while read -r line; do
        echo "  $line"
    done

    echo ""
}

# Generate comprehensive report
generate_report() {
    {
        info "=== System Uptime Report ==="
        info "RHEL Version: $RHEL_VERSION"
        info "System: $(hostname)"
        info "Report date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        generate_statistics
        get_boot_times
        check_journal_boots
        analyze_reboot_history
        count_unplanned_shutdowns
        calculate_average_uptime
        check_kernel_panics

        success "Report generation complete"
    } | tee -a "${OUTPUT_FILE:-.}"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel

    generate_report
}

main "$@"
