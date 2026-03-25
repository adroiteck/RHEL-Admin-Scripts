#!/bin/bash

################################################################################
# Script: add-user.sh
# Description: Interactive or CLI-based user account creation with advanced
#              options including password expiry, groups, shell, and home dir.
# Usage: ./add-user.sh [--username USERNAME] [--fullname "Full Name"]
#        [--shell SHELL] [--groups GROUP1,GROUP2] [--home DIR] [--expiry DAYS]
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
    info "Detected RHEL version: $RHEL_VERSION"
}

# Validate username
validate_username() {
    local username="$1"
    if [[ ! $username =~ ^[a-z_][a-z0-9_-]*$ ]] || [[ ${#username} -gt 32 ]]; then
        error "Invalid username: must be lowercase, start with letter, max 32 chars"
        return 1
    fi
    if id "$username" &>/dev/null; then
        error "User '$username' already exists"
        return 1
    fi
    return 0
}

# Interactive mode
interactive_mode() {
    info "Starting interactive user creation mode..."

    read -p "Username: " username
    validate_username "$username" || return 1

    read -p "Full name: " fullname
    read -p "Shell [/bin/bash]: " shell
    shell="${shell:-/bin/bash}"

    read -p "Groups (comma-separated) []: " groups
    groups="${groups:-}"

    read -p "Home directory [/home/$username]: " home_dir
    home_dir="${home_dir:-/home/$username}"

    read -p "Password expiry in days [90]: " expiry
    expiry="${expiry:-90}"

    create_user "$username" "$fullname" "$shell" "$groups" "$home_dir" "$expiry"
}

# Create user account
create_user() {
    local username="$1"
    local fullname="$2"
    local shell="$3"
    local groups="$4"
    local home_dir="$5"
    local expiry="$6"

    info "Creating user account: $username"

    # Create user with home directory and shell
    useradd -m -d "$home_dir" -s "$shell" -c "$fullname" "$username" || {
        error "Failed to create user account"
        return 1
    }
    success "User account created: $username"

    # Set password expiry policy
    if [[ -n "$expiry" ]] && [[ "$expiry" =~ ^[0-9]+$ ]]; then
        chage -M "$expiry" "$username"
        info "Password expiry set to $expiry days"
    fi

    # Add to groups
    if [[ -n "$groups" ]]; then
        IFS=',' read -ra group_array <<< "$groups"
        for group in "${group_array[@]}"; do
            group=$(echo "$group" | xargs)  # trim whitespace
            if getent group "$group" &>/dev/null; then
                usermod -aG "$group" "$username"
                info "Added user to group: $group"
            else
                warn "Group does not exist: $group"
            fi
        done
    fi

    # Set restrictive home directory permissions
    chmod 700 "$home_dir"
    info "Home directory permissions set to 700"

    success "User '$username' created successfully with full name: '$fullname'"
}

# Main function
main() {
    check_root
    detect_rhel_version

    local username="" fullname="" shell="/bin/bash" groups="" home_dir="" expiry="90"

    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)
                username="$2"
                shift 2
                ;;
            --fullname)
                fullname="$2"
                shift 2
                ;;
            --shell)
                shell="$2"
                shift 2
                ;;
            --groups)
                groups="$2"
                shift 2
                ;;
            --home)
                home_dir="$2"
                shift 2
                ;;
            --expiry)
                expiry="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Use interactive mode if no arguments provided
    if [[ -z "$username" ]]; then
        interactive_mode
        return
    fi

    # Validate and create user
    validate_username "$username" || exit 1
    [[ -z "$fullname" ]] && fullname="$username"
    [[ -z "$home_dir" ]] && home_dir="/home/$username"

    create_user "$username" "$fullname" "$shell" "$groups" "$home_dir" "$expiry"
}

main "$@"
