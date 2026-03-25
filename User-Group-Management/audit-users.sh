#!/bin/bash

################################################################################
# Script: audit-users.sh
# Description: Comprehensive user account audit. Lists users with UID >= 1000,
#              displays last login, password age/expiry, shell, and groups.
#              Flags suspicious accounts (no password, never expires, unused).
# Usage: ./audit-users.sh [--csv] [--output FILE] [--flags-only]
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

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    fi
}

# Get last login for user
get_last_login() {
    local username="$1"
    local last_login="Never"

    if [[ -r /var/log/lastlog ]]; then
        last_login=$(lastlog -u "$username" 2>/dev/null | tail -1 | awk '{print $4, $5, $6, $7, $8}')
        [[ -z "$last_login" ]] && last_login="Never"
    fi

    echo "$last_login"
}

# Get password age info
get_password_info() {
    local username="$1"

    local max_age=$(chage -l "$username" 2>/dev/null | grep "Maximum" | awk -F': ' '{print $2}')
    local last_change=$(chage -l "$username" 2>/dev/null | grep "Last password change" | awk -F': ' '{print $2}')
    local expires=$(chage -l "$username" 2>/dev/null | grep "Account expires" | awk -F': ' '{print $2}')

    echo "$max_age|$last_change|$expires"
}

# Check for suspicious accounts
check_account_flags() {
    local username="$1"
    local flags=""

    # Check for no password set
    if [[ -z "$(grep "^$username:" /etc/shadow | cut -d':' -f2)" ]]; then
        flags="${flags}NO_PASSWORD "
    fi

    # Check for password never expires
    if chage -l "$username" 2>/dev/null | grep -q "never"; then
        flags="${flags}NEVER_EXPIRES "
    fi

    # Check for /bin/bash shell with no login
    local shell=$(getent passwd "$username" | cut -d':' -f7)
    if [[ "$shell" == "/bin/bash" ]] || [[ "$shell" == "/bin/sh" ]]; then
        local last_login=$(get_last_login "$username")
        if [[ "$last_login" == "Never" ]]; then
            flags="${flags}NEVER_LOGGED_IN "
        fi
    fi

    echo "$flags"
}

# Print header for table output
print_header() {
    printf "%-20s %-10s %-20s %-15s %-10s %-25s %s\n" \
        "USERNAME" "UID" "LAST LOGIN" "SHELL" "PWD MAX" "EXPIRES" "FLAGS"
    printf "%s\n" "$(printf '%.0s-' {1..130})"
}

# Print CSV header
print_csv_header() {
    echo "USERNAME,UID,LAST_LOGIN,SHELL,PASSWORD_MAX_AGE,ACCOUNT_EXPIRES,GROUPS,FLAGS"
}

# Output user info in table format
output_table_format() {
    local username="$1"
    local uid=$(getent passwd "$username" | cut -d':' -f3)
    local shell=$(getent passwd "$username" | cut -d':' -f7)
    local groups=$(groups "$username" 2>/dev/null | cut -d':' -f2 | xargs)
    local last_login=$(get_last_login "$username")

    IFS='|' read -r max_age last_change expires <<< "$(get_password_info "$username")"
    local flags=$(check_account_flags "$username")

    printf "%-20s %-10s %-20s %-15s %-10s %-25s %s\n" \
        "$username" "$uid" "${last_login:0:20}" "$shell" "$max_age" "${expires:0:25}" "$flags"
}

# Output user info in CSV format
output_csv_format() {
    local username="$1"
    local uid=$(getent passwd "$username" | cut -d':' -f3)
    local shell=$(getent passwd "$username" | cut -d':' -f7)
    local groups=$(groups "$username" 2>/dev/null | cut -d':' -f2 | xargs)
    local last_login=$(get_last_login "$username")

    IFS='|' read -r max_age last_change expires <<< "$(get_password_info "$username")"
    local flags=$(check_account_flags "$username")

    echo "\"$username\",\"$uid\",\"$last_login\",\"$shell\",\"$max_age\",\"$expires\",\"$groups\",\"$flags\""
}

# Audit users
audit_users() {
    local csv_mode="$1"
    local output_file="$2"
    local flags_only="$3"
    local output=""

    detect_rhel_version
    info "Auditing users with UID >= 1000 on RHEL $RHEL_VERSION"

    if [[ "$csv_mode" == "true" ]]; then
        output="$(print_csv_header)"
    else
        output="$(print_header)"
    fi

    while IFS=':' read -r username _ uid _ _ _ _; do
        if [[ "$uid" -ge 1000 ]]; then
            if [[ "$flags_only" == "true" ]]; then
                local flags=$(check_account_flags "$username")
                [[ -n "$flags" ]] && {
                    if [[ "$csv_mode" == "true" ]]; then
                        output+=$'\n'"$(output_csv_format "$username")"
                    else
                        output+=$'\n'"$(output_table_format "$username")"
                    fi
                }
            else
                if [[ "$csv_mode" == "true" ]]; then
                    output+=$'\n'"$(output_csv_format "$username")"
                else
                    output+=$'\n'"$(output_table_format "$username")"
                fi
            fi
        fi
    done < /etc/passwd

    if [[ -n "$output_file" ]]; then
        echo "$output" > "$output_file"
        success "Audit report written to: $output_file"
    else
        echo "$output"
    fi
}

# Main function
main() {
    local csv_mode="false"
    local output_file=""
    local flags_only="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --csv)
                csv_mode="true"
                shift
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            --flags-only)
                flags_only="true"
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    audit_users "$csv_mode" "$output_file" "$flags_only"
}

main "$@"
