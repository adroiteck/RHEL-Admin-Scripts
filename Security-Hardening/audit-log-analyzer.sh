#!/bin/bash

################################################################################
# Script: audit-log-analyzer.sh
# Description: Analyzes audit logs for failed logins, sudo usage, file access
#              events, user/group changes, and SELinux denials with timeframe
#              and user filtering.
# Usage: audit-log-analyzer.sh --type failed-logins
#        audit-log-analyzer.sh --type sudo-usage --user root
#        audit-log-analyzer.sh --type selinux --start "2024-01-01"
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8 with audit daemon
# Version: 1.0
################################################################################

set -euo pipefail

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

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Check if audit daemon is running
check_audit_daemon() {
    if ! systemctl is-active auditd &>/dev/null; then
        warn "auditd is not running. Some features may not work correctly."
    fi

    if [[ ! -f /var/log/audit/audit.log ]]; then
        error "Audit log not found: /var/log/audit/audit.log"
        exit 1
    fi
}

# Analyze failed logins
analyze_failed_logins() {
    local start_time=$1
    local end_time=$2
    local user_filter=$3

    echo ""
    echo "================================ FAILED LOGIN ATTEMPTS ================================"

    local cmd="ausearch -m USER_LOGIN -m USER_AUTH -ts $start_time"
    [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"

    if $cmd 2>/dev/null | grep -i "auid=" | tail -50; then
        true
    else
        info "No failed login attempts found"
    fi
}

# Analyze sudo usage
analyze_sudo_usage() {
    local start_time=$1
    local end_time=$2
    local user_filter=$3

    echo ""
    echo "================================ SUDO USAGE ================================"

    local cmd="ausearch -m EXECVE -F comm=sudo -ts $start_time"
    [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"

    if $cmd 2>/dev/null | grep -i "sudo" | tail -50; then
        true
    else
        info "No sudo usage found"
    fi
}

# Analyze file access events
analyze_file_access() {
    local start_time=$1
    local end_time=$2
    local file_path=$3

    echo ""
    echo "================================ FILE ACCESS EVENTS ================================"

    if [[ -z "$file_path" ]]; then
        info "Analyzing all file access events..."
        local cmd="ausearch -m EXECVE -ts $start_time"
        [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"
    else
        info "Analyzing file access for: $file_path"
        local cmd="ausearch -F dir=$file_path -ts $start_time"
        [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"
    fi

    if $cmd 2>/dev/null | tail -50; then
        true
    else
        info "No file access events found"
    fi
}

# Analyze user/group changes
analyze_user_changes() {
    local start_time=$1
    local end_time=$2

    echo ""
    echo "================================ USER/GROUP CHANGES ================================"

    local cmd="ausearch -m ADD_USER,DEL_USER,ADD_GROUP,DEL_GROUP,MODIFY_USER -ts $start_time"
    [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"

    if $cmd 2>/dev/null | tail -50; then
        true
    else
        info "No user/group changes found"
    fi
}

# Analyze SELinux denials
analyze_selinux_denials() {
    local start_time=$1
    local end_time=$2

    echo ""
    echo "================================ SELINUX DENIALS ================================"

    local cmd="ausearch -m AVC -ts $start_time"
    [[ -n "$end_time" ]] && cmd="$cmd -te $end_time"

    local denial_count=$($cmd 2>/dev/null | wc -l || echo 0)
    info "Total SELinux denials: $denial_count"

    if [[ $denial_count -gt 0 ]]; then
        echo ""
        echo "Recent denials:"
        $cmd 2>/dev/null | tail -20

        # Try to suggest fixes
        if command -v audit2why &>/dev/null; then
            echo ""
            echo "Suggested fixes:"
            $cmd 2>/dev/null | audit2why 2>/dev/null || echo "Unable to generate fixes"
        fi
    fi
}

# Generate summary
generate_summary() {
    echo ""
    echo "================================ AUDIT SUMMARY ================================"

    local total_events=$(wc -l < /var/log/audit/audit.log)
    info "Total audit events: $total_events"

    local user_login=$(ausearch -m USER_LOGIN 2>/dev/null | wc -l)
    info "User login attempts: $user_login"

    local sudo_usage=$(ausearch -m EXECVE -F comm=sudo 2>/dev/null | wc -l)
    info "Sudo command executions: $sudo_usage"

    local file_changes=$(ausearch -m ATTR_CHANGE 2>/dev/null | wc -l)
    info "File attribute changes: $file_changes"

    local avc_denials=$(ausearch -m AVC 2>/dev/null | wc -l)
    info "SELinux AVC denials: $avc_denials"

    success "Summary generated"
}

# Parse arguments
TYPE=""
START_TIME="recent"
END_TIME=""
USER_FILTER=""
FILE_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --type) TYPE="$2"; shift 2 ;;
        --start) START_TIME="$2"; shift 2 ;;
        --end) END_TIME="$2"; shift 2 ;;
        --user) USER_FILTER="$2"; shift 2 ;;
        --file) FILE_PATH="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$TYPE" ]]; then
    error "Missing required argument: --type"
    echo "Usage: $0 --type [failed-logins|sudo-usage|file-access|user-changes|selinux|summary]"
    exit 1
fi

check_root
detect_rhel_version
check_audit_daemon

info "Analyzing audit logs (RHEL $RHEL_VERSION)"
info "Timeframe: from $START_TIME to ${END_TIME:-present}"

case "$TYPE" in
    failed-logins)
        analyze_failed_logins "$START_TIME" "$END_TIME" "$USER_FILTER"
        ;;
    sudo-usage)
        analyze_sudo_usage "$START_TIME" "$END_TIME" "$USER_FILTER"
        ;;
    file-access)
        analyze_file_access "$START_TIME" "$END_TIME" "$FILE_PATH"
        ;;
    user-changes)
        analyze_user_changes "$START_TIME" "$END_TIME"
        ;;
    selinux)
        analyze_selinux_denials "$START_TIME" "$END_TIME"
        ;;
    summary)
        generate_summary
        ;;
    *)
        error "Unknown type: $TYPE"
        exit 1
        ;;
esac

success "Audit log analysis completed"
