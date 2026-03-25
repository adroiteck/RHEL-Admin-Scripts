#!/bin/bash

################################################################################
# Script: bulk-user-import.sh
# Description: Bulk user account creation from CSV file. Supports dry-run mode,
#              random password generation, and credential export to secure file.
# Usage: ./bulk-user-import.sh --csv FILE [--dry-run] [--export-creds FILE]
# CSV Format: username,fullname,groups,shell,password_expiry
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
    fi
}

# Generate random password
generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=[]{}|;:,.<>?' < /dev/urandom | head -c "$length"
}

# Validate username format
validate_username_format() {
    local username="$1"
    if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ ${#username} -gt 32 ]]; then
        return 1
    fi
    return 0
}

# Validate CSV format
validate_csv_format() {
    local csv_file="$1"

    if [[ ! -f "$csv_file" ]]; then
        error "CSV file not found: $csv_file"
        return 1
    fi

    local line_num=0
    while IFS=',' read -r username fullname groups shell expiry; do
        ((line_num++))
        [[ -z "$username" ]] && continue

        if ! validate_username_format "$username"; then
            error "Line $line_num: Invalid username format: $username"
            return 1
        fi
    done < "$csv_file"

    info "CSV file validation passed"
    return 0
}

# Process CSV and create users
process_csv() {
    local csv_file="$1"
    local dry_run="$2"
    local creds_file="$3"
    local created_count=0
    local failed_count=0
    local creds_data=""

    info "Processing CSV file: $csv_file"

    while IFS=',' read -r username fullname groups shell expiry; do
        # Skip empty lines and comments
        [[ -z "$username" ]] && continue
        [[ "$username" =~ ^# ]] && continue

        # Trim whitespace
        username=$(echo "$username" | xargs)
        fullname=$(echo "$fullname" | xargs)
        groups=$(echo "$groups" | xargs)
        shell=$(echo "$shell" | xargs)
        expiry=$(echo "$expiry" | xargs)

        info "Processing user: $username"

        # Check if user already exists
        if id "$username" &>/dev/null; then
            warn "User already exists: $username (skipping)"
            ((failed_count++))
            continue
        fi

        # Generate password
        local password=$(generate_password 16)

        if [[ "$dry_run" == "true" ]]; then
            info "[DRY-RUN] Would create user: $username ($fullname)"
            [[ -n "$groups" ]] && info "[DRY-RUN] Groups: $groups"
            [[ -n "$shell" ]] && info "[DRY-RUN] Shell: $shell"
        else
            # Set defaults
            shell="${shell:-/bin/bash}"
            expiry="${expiry:-90}"

            # Create user
            if useradd -m -s "$shell" -c "$fullname" "$username" &>/dev/null; then
                # Set password
                echo "$username:$password" | chpasswd

                # Set password expiry
                chage -M "$expiry" "$username" 2>/dev/null || true

                # Add to groups
                if [[ -n "$groups" ]]; then
                    IFS=';' read -ra group_array <<< "$groups"
                    for group in "${group_array[@]}"; do
                        group=$(echo "$group" | xargs)
                        if getent group "$group" &>/dev/null; then
                            usermod -aG "$group" "$username"
                        else
                            warn "Group does not exist: $group"
                        fi
                    done
                fi

                success "User created: $username"
                ((created_count++))

                # Store credentials
                if [[ -n "$creds_file" ]]; then
                    creds_data+="$username|$fullname|$password|$groups|$shell"$'\n'
                fi
            else
                error "Failed to create user: $username"
                ((failed_count++))
            fi
        fi

    done < "$csv_file"

    # Export credentials if requested
    if [[ -n "$creds_file" ]] && [[ "$dry_run" != "true" ]]; then
        echo "$creds_data" > "$creds_file"
        chmod 600 "$creds_file"
        success "Credentials exported to: $creds_file"
        warn "Protect this file - it contains passwords!"
    fi

    info "Summary: $created_count created, $failed_count failed"
}

# Main function
main() {
    check_root
    detect_rhel_version

    local csv_file=""
    local dry_run="false"
    local creds_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --csv)
                csv_file="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --export-creds)
                creds_file="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$csv_file" ]]; then
        error "Usage: $0 --csv FILE [--dry-run] [--export-creds FILE]"
        exit 1
    fi

    validate_csv_format "$csv_file" || exit 1
    process_csv "$csv_file" "$dry_run" "$creds_file"
}

main "$@"
