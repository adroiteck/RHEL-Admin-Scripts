#!/bin/bash

################################################################################
# Script: log-analyzer.sh
# Description: Analyzes system logs for errors, warnings, and anomalies
# Usage: ./log-analyzer.sh [--hours 24] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root or journalctl read access, standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
HOURS=24
OUTPUT_FILE=""
RHEL_VERSION=""
USE_JOURNAL=0
LOG_FILE="/var/log/messages"

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hours) HOURS="$2"; shift ;;
            --output) OUTPUT_FILE="$2"; shift ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Detect RHEL version and logging system
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi

    if command -v journalctl &> /dev/null; then
        USE_JOURNAL=1
    fi
}

# Get logs from journal or syslog
get_logs() {
    local since_time="${HOURS}h"

    if [[ $USE_JOURNAL -eq 1 ]]; then
        journalctl --no-pager --since "$since_time ago" --output cat 2>/dev/null || true
    else
        if [[ -f "$LOG_FILE" ]]; then
            local cutoff_time=$(date -d "$HOURS hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v"-${HOURS}H" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
            grep "$cutoff_time" "$LOG_FILE" 2>/dev/null || tail -n 10000 "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# Count errors and warnings
count_messages() {
    local logs="$1"

    local error_count=$(echo "$logs" | grep -iE "(error|fail|critical)" | wc -l)
    local warn_count=$(echo "$logs" | grep -iE "(warn|notice)" | wc -l)
    local info_count=$(echo "$logs" | grep -iE "info" | wc -l)

    info "Message counts (last $HOURS hours):"
    success "  Errors: $error_count"
    warn "  Warnings: $warn_count"
    info "  Info: $info_count"
    echo ""
}

# Find top error sources
top_error_sources() {
    local logs="$1"

    info "Top 10 error sources:"
    echo "$logs" | grep -iE "(error|fail|critical)" | \
        sed 's/.*\[\([^]]*\)\].*/\1/' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{print "  " $0}' || true
    echo ""
}

# Track login failures
track_login_failures() {
    local logs="$1"

    info "Login failure analysis:"
    local ssh_fails=$(echo "$logs" | grep -iE "(authentication failure|invalid user|connection closed)" | wc -l)
    local su_fails=$(echo "$logs" | grep -E "sudo:|su\[" | grep -i "authentication failure" | wc -l)

    warn "  SSH failures: $ssh_fails"
    warn "  sudo/su failures: $su_fails"

    if [[ $ssh_fails -gt 50 ]]; then
        error "  WARNING: High SSH failure rate detected!"
    fi
    echo ""
}

# Check for kernel issues
check_kernel_issues() {
    local logs="$1"

    info "Kernel issue detection:"
    local panics=$(echo "$logs" | grep -i "kernel panic" | wc -l)
    local oops=$(echo "$logs" | grep -i "kernel.*oops" | wc -l)
    local oom=$(echo "$logs" | grep -i "out of memory" | wc -l)

    if [[ $panics -gt 0 ]]; then
        error "  Kernel panics: $panics"
    else
        success "  Kernel panics: 0"
    fi

    if [[ $oops -gt 0 ]]; then
        error "  Kernel oops: $oops"
    else
        success "  Kernel oops: 0"
    fi

    if [[ $oom -gt 0 ]]; then
        error "  OOM kills: $oom"
    else
        success "  OOM kills: 0"
    fi
    echo ""
}

# Analyze systemd/service failures
analyze_service_issues() {
    local logs="$1"

    info "Service issue analysis:"
    local service_fails=$(echo "$logs" | grep -iE "unit.*failed|service.*failed" | wc -l)
    local timeout_fails=$(echo "$logs" | grep -i "timeout" | wc -l)

    warn "  Service failures: $service_fails"
    if [[ $timeout_fails -gt 0 ]]; then
        warn "  Timeout issues: $timeout_fails"
    else
        success "  Timeout issues: 0"
    fi

    if [[ $service_fails -gt 0 ]]; then
        info "  Failed services:"
        echo "$logs" | grep -iE "unit.*failed|service.*failed" | \
            sed 's/.*unit \([^ ]*\).*/\1/' | sort | uniq | head -5 | \
            awk '{print "    " $0}' || true
    fi
    echo ""
}

# Main execution
main() {
    parse_args "$@"
    detect_environment

    {
        info "=== System Log Analysis ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Log period: Last $HOURS hours"
        info "Logging system: $([ $USE_JOURNAL -eq 1 ] && echo 'systemd-journal' || echo 'syslog')"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        local logs=$(get_logs)

        if [[ -z "$logs" ]]; then
            error "No logs found for the specified period"
            echo ""
            return 1
        fi

        count_messages "$logs"
        top_error_sources "$logs"
        track_login_failures "$logs"
        check_kernel_issues "$logs"
        analyze_service_issues "$logs"

        success "Log analysis complete"
    } | tee -a "${OUTPUT_FILE:-.}"
}

main "$@"
