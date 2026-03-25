#!/bin/bash

################################################################################
# Script: password-policy-check.sh
# Description: Audit password policies across all system users. Reports min/max
#              age, complexity requirements (pam_pwquality/pam_cracklib), and
#              identifies policy violations. RHEL version-aware for PAM configs.
# Usage: ./password-policy-check.sh [--report] [--violations-only] [--output FILE]
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
    else
        error "Cannot determine RHEL version"
        exit 1
    fi
    info "Detected RHEL version: $RHEL_VERSION"
}

# Get password complexity requirements (RHEL 7: pam_cracklib, RHEL 8/9: pam_pwquality)
get_password_complexity() {
    local config_file=""
    local dcredit="0"
    local ucredit="0"
    local lcredit="0"
    local ocredit="0"
    local minlen="0"
    local minclass="0"

    if [[ "$RHEL_VERSION" == "7" ]]; then
        config_file="/etc/pam.d/password-auth"
        if [[ -f "$config_file" ]]; then
            # Extract pam_cracklib parameters
            dcredit=$(grep -o "dcredit=[^ ]*" "$config_file" 2>/dev/null | cut -d'=' -f2 || echo "-1")
            ucredit=$(grep -o "ucredit=[^ ]*" "$config_file" 2>/dev/null | cut -d'=' -f2 || echo "-1")
            lcredit=$(grep -o "lcredit=[^ ]*" "$config_file" 2>/dev/null | cut -d'=' -f2 || echo "-1")
            ocredit=$(grep -o "ocredit=[^ ]*" "$config_file" 2>/dev/null | cut -d'=' -f2 || echo "-1")
            minlen=$(grep -o "minlen=[^ ]*" "$config_file" 2>/dev/null | cut -d'=' -f2 || echo "0")
        fi
    else
        # RHEL 8/9: pam_pwquality
        config_file="/etc/security/pwquality.conf"
        if [[ -f "$config_file" ]]; then
            dcredit=$(grep "^dcredit" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
            ucredit=$(grep "^ucredit" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
            lcredit=$(grep "^lcredit" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
            ocredit=$(grep "^ocredit" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
            minlen=$(grep "^minlen" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
            minclass=$(grep "^minclass" "$config_file" 2>/dev/null | cut -d'=' -f2 | xargs || echo "0")
        fi
    fi

    echo "$dcredit|$ucredit|$lcredit|$ocredit|$minlen|$minclass"
}

# Get global password policies
get_global_policy() {
    local min_age=$(grep "^PASS_MIN_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "0")
    local max_age=$(grep "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "99999")
    local warn_age=$(grep "^PASS_WARN_AGE" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "7")

    echo "$min_age|$max_age|$warn_age"
}

# Check user password policy violations
check_user_violations() {
    local username="$1"
    local max_age="$2"
    local violations=""

    # Check for no password
    if [[ -z "$(grep "^$username:" /etc/shadow | cut -d':' -f2)" ]]; then
        violations="${violations}NO_PASSWORD "
    fi

    # Check for password never expires
    local user_max=$(chage -l "$username" 2>/dev/null | grep "Maximum" | awk -F': ' '{print $2}')
    if [[ "$user_max" == "never" ]]; then
        violations="${violations}NEVER_EXPIRES "
    fi

    # Check for password older than max age
    local last_change=$(chage -l "$username" 2>/dev/null | grep "Last password change" | awk -F': ' '{print $2}')
    if [[ "$last_change" != "never" ]] && [[ "$last_change" != "password must be changed" ]]; then
        local days_old=$(( ($(date +%s) - $(date -d "$last_change" +%s)) / 86400 ))
        if [[ $days_old -gt $max_age ]]; then
            violations="${violations}PASSWORD_EXPIRED "
        fi
    fi

    echo "$violations"
}

# Print global policy info
print_global_policy() {
    IFS='|' read -r min_age max_age warn_age <<< "$(get_global_policy)"
    IFS='|' read -r dcredit ucredit lcredit ocredit minlen minclass <<< "$(get_password_complexity)"

    echo ""
    echo "========== GLOBAL PASSWORD POLICY (login.defs) =========="
    echo "Min Days Between Changes: $min_age"
    echo "Max Days Before Expiry: $max_age"
    echo "Warning Days: $warn_age"
    echo ""
    echo "========== COMPLEXITY REQUIREMENTS =========="
    if [[ "$RHEL_VERSION" == "7" ]]; then
        echo "PAM Module: pam_cracklib (RHEL 7)"
    else
        echo "PAM Module: pam_pwquality (RHEL 8/9)"
    fi
    echo "Min Length: $minlen"
    echo "Min Digits: $dcredit"
    echo "Min Uppercase: $ucredit"
    echo "Min Lowercase: $lcredit"
    echo "Min Other: $ocredit"
    echo "Min Classes: $minclass"
    echo ""
}

# Audit all users
audit_password_policy() {
    local violations_only="$1"
    local output_file="$2"

    local output="========== USER PASSWORD POLICY AUDIT ==========$(printf '\n')"
    output+="Generated: $(date)$(printf '\n')"
    output+="RHEL Version: $RHEL_VERSION$(printf '\n')"

    output+="$(print_global_policy)"

    IFS='|' read -r _ max_age _ <<< "$(get_global_policy)"

    output+="========== USER ACCOUNTS ==========$(printf '\n')"
    output+="$(printf '%-20s %-15s %-20s %-30s\n' "USERNAME" "UID" "PWD MAX AGE" "VIOLATIONS")$(printf '\n')"
    output+="$(printf '%.0s-' {1..85})$(printf '\n')"

    while IFS=':' read -r username _ uid _ _ _ _; do
        if [[ "$uid" -ge 1000 ]] || [[ "$username" == "root" ]]; then
            local user_max=$(chage -l "$username" 2>/dev/null | grep "Maximum" | awk -F': ' '{print $2}' || echo "N/A")
            local violations=$(check_user_violations "$username" "$max_age")

            if [[ "$violations_only" == "false" ]] || [[ -n "$violations" ]]; then
                output+="$(printf '%-20s %-15s %-20s %-30s\n' "$username" "$uid" "$user_max" "${violations:0:30}")$(printf '\n')"
            fi
        fi
    done < /etc/passwd

    if [[ -n "$output_file" ]]; then
        echo "$output" > "$output_file"
        success "Report written to: $output_file"
    else
        echo "$output"
    fi
}

# Main function
main() {
    detect_rhel_version

    local violations_only="false"
    local output_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --violations-only)
                violations_only="true"
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

    audit_password_policy "$violations_only" "$output_file"
}

main "$@"
