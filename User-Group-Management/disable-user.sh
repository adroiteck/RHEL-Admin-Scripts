#!/bin/bash

################################################################################
# Script: disable-user.sh
# Description: Safely disables user accounts by locking password, expiring
#              account, optionally killing active sessions, and logging actions.
# Usage: ./disable-user.sh USERNAME [--kill-sessions] [--reason REASON]
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
        RHEL_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        error "Cannot determine RHEL version"
        exit 1
    fi
}

# Log action to audit file
log_action() {
    local username="$1"
    local action="$2"
    local reason="${3:-No reason provided}"
    local log_file="/var/log/user-management-audit.log"

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ACTION: $action | USER: $username | EXECUTOR: $(whoami) | REASON: $reason"
    } >> "$log_file"

    info "Action logged to $log_file"
}

# Kill user's active sessions
kill_user_sessions() {
    local username="$1"
    local killed_count=0

    info "Killing active sessions for user: $username"

    # Kill SSH sessions
    pkill -u "$username" -f sshd: 2>/dev/null || true
    ((killed_count++))

    # Kill other processes
    if pkill -u "$username" 2>/dev/null; then
        killed_count=$(pgrep -u "$username" 2>/dev/null | wc -l)
        info "Terminated $killed_count process(es) for user: $username"
    fi

    # Remove from utmp/wtmp (login records)
    who | grep "$username" | awk '{print $NF}' | while read -r tty; do
        pkill -f "w $tty" 2>/dev/null || true
    done

    success "Sessions terminated"
}

# Disable user account
disable_user() {
    local username="$1"
    local kill_sessions="$2"
    local reason="${3:-Administrative action}"

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        error "User does not exist: $username"
        return 1
    fi

    info "Disabling user account: $username"

    # Lock password (prevents login)
    if passwd -l "$username" &>/dev/null; then
        info "Password locked"
    else
        error "Failed to lock password"
        return 1
    fi

    # Expire account (forces password change on next login attempt)
    if chage -E 0 "$username" &>/dev/null; then
        info "Account expired"
    else
        error "Failed to expire account"
        return 1
    fi

    # Kill active sessions if requested
    if [[ "$kill_sessions" == "true" ]]; then
        kill_user_sessions "$username"
    fi

    # Log the action
    log_action "$username" "DISABLE" "$reason"

    success "User account disabled: $username"
}

# Main function
main() {
    check_root
    detect_rhel_version

    if [[ $# -lt 1 ]]; then
        error "Usage: $0 USERNAME [--kill-sessions] [--reason REASON]"
        exit 1
    fi

    local username="$1"
    local kill_sessions="false"
    local reason="Administrative action"
    shift || true

    # Parse additional arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kill-sessions)
                kill_sessions="true"
                shift
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    disable_user "$username" "$kill_sessions" "$reason"
}

main "$@"
