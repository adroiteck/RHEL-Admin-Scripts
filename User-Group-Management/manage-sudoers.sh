#!/bin/bash

################################################################################
# Script: manage-sudoers.sh
# Description: Safely manage sudoers entries by creating drop-in files in
#              /etc/sudoers.d/. Validates syntax with visudo before applying.
# Usage: ./manage-sudoers.sh --action [add|remove|list|validate] [--user USER]
#        [--commands CMDS] [--nopasswd] [--hosts HOSTS]
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

# Validate sudoers syntax
validate_sudoers() {
    if visudo -cf "$1" &>/dev/null; then
        return 0
    else
        error "Sudoers syntax validation failed for: $1"
        return 1
    fi
}

# Add sudoers entry
add_sudoers_entry() {
    local username="$1"
    local commands="${2:-ALL}"
    local nopasswd="${3:-false}"
    local hosts="${4:-ALL}"

    local drop_in_file="/etc/sudoers.d/50-${username}"

    info "Creating sudoers entry for user: $username"

    # Check if user exists
    if ! id "$username" &>/dev/null; then
        error "User does not exist: $username"
        return 1
    fi

    # Build sudoers line
    local sudoers_line="$username $hosts="
    [[ "$nopasswd" == "true" ]] && sudoers_line+="NOPASSWD: "
    sudoers_line+="$commands"

    # Create drop-in file
    {
        echo "# Sudoers entry for $username - Auto-generated"
        echo "# Created: $(date)"
        echo "$sudoers_line"
    } > "$drop_in_file"

    # Set proper permissions
    chmod 440 "$drop_in_file"
    chown root:root "$drop_in_file"

    # Validate syntax
    if validate_sudoers "$drop_in_file"; then
        success "Sudoers entry added: $drop_in_file"
        return 0
    else
        rm "$drop_in_file"
        return 1
    fi
}

# Remove sudoers entry
remove_sudoers_entry() {
    local username="$1"
    local drop_in_file="/etc/sudoers.d/50-${username}"

    if [[ ! -f "$drop_in_file" ]]; then
        error "Sudoers entry not found: $drop_in_file"
        return 1
    fi

    info "Removing sudoers entry: $drop_in_file"
    rm "$drop_in_file"
    success "Sudoers entry removed"
}

# List sudoers entries
list_sudoers_entries() {
    info "Sudoers entries in /etc/sudoers.d/:"
    echo "---"

    if [[ ! -d /etc/sudoers.d ]]; then
        error "Directory /etc/sudoers.d not found"
        return 1
    fi

    for file in /etc/sudoers.d/*; do
        if [[ -f "$file" ]] && [[ ! "$file" =~ .swp$ ]]; then
            echo "File: $(basename "$file")"
            cat "$file" | grep -v "^#" | grep -v "^$"
            echo "---"
        fi
    done

    success "Sudoers entries listed"
}

# Validate all sudoers files
validate_all_sudoers() {
    info "Validating all sudoers files..."

    local errors=0

    # Validate main sudoers
    if ! visudo -cf /etc/sudoers &>/dev/null; then
        error "Main sudoers file has syntax errors"
        ((errors++))
    else
        success "Main sudoers file is valid"
    fi

    # Validate drop-in files
    for file in /etc/sudoers.d/*; do
        if [[ -f "$file" ]] && [[ ! "$file" =~ .swp$ ]]; then
            if ! visudo -cf "$file" &>/dev/null; then
                error "Syntax error in: $(basename "$file")"
                ((errors++))
            else
                success "Valid: $(basename "$file")"
            fi
        fi
    done

    if [[ $errors -eq 0 ]]; then
        success "All sudoers files are valid"
        return 0
    else
        error "Found $errors file(s) with syntax errors"
        return 1
    fi
}

# Main function
main() {
    check_root
    detect_rhel_version

    local action=""
    local username=""
    local commands=""
    local nopasswd="false"
    local hosts="ALL"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action="$2"
                shift 2
                ;;
            --user)
                username="$2"
                shift 2
                ;;
            --commands)
                commands="$2"
                shift 2
                ;;
            --nopasswd)
                nopasswd="true"
                shift
                ;;
            --hosts)
                hosts="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    case "$action" in
        add)
            [[ -z "$username" ]] && {
                error "Username required for add action"
                exit 1
            }
            add_sudoers_entry "$username" "${commands:-ALL}" "$nopasswd" "$hosts"
            ;;
        remove)
            [[ -z "$username" ]] && {
                error "Username required for remove action"
                exit 1
            }
            remove_sudoers_entry "$username"
            ;;
        list)
            list_sudoers_entries
            ;;
        validate)
            validate_all_sudoers
            ;;
        *)
            error "Unknown action: $action (use: add|remove|list|validate)"
            exit 1
            ;;
    esac
}

main "$@"
