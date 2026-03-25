#!/bin/bash

################################################################################
# Script: manage-repos.sh
# Description: Repository management: list enabled/disabled repos, enable/
#              disable specific repos, add custom repos, show repo details,
#              and clean cache.
# Usage: ./manage-repos.sh --action [list|enable|disable|add|clean|info]
#        [--repo REPO_ID] [--url URL] [--gpg-key URL]
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

# Detect RHEL version and package manager
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        error "Cannot determine RHEL version"
        exit 1
    fi

    if [[ "$RHEL_VERSION" -ge 8 ]]; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi

    info "RHEL $RHEL_VERSION detected, using: $PKG_MANAGER"
}

# List enabled repositories
list_repos() {
    local status="${1:-all}"

    info "Listing repositories ($status)..."
    echo "========== REPOSITORIES =========="

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        case "$status" in
            enabled)
                dnf repolist enabled
                ;;
            disabled)
                dnf repolist disabled
                ;;
            all)
                dnf repolist all
                ;;
        esac
    else
        case "$status" in
            enabled)
                yum repolist enabled
                ;;
            disabled)
                yum repolist disabled
                ;;
            all)
                yum repolist all
                ;;
        esac
    fi
}

# Enable a repository
enable_repo() {
    local repo_id="$1"

    if [[ -z "$repo_id" ]]; then
        error "Repository ID required"
        return 1
    fi

    info "Enabling repository: $repo_id"

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf config-manager --set-enabled "$repo_id" || {
            error "Failed to enable repository: $repo_id"
            return 1
        }
    else
        yum-config-manager --enable "$repo_id" || {
            error "Failed to enable repository: $repo_id"
            return 1
        }
    fi

    success "Repository enabled: $repo_id"
}

# Disable a repository
disable_repo() {
    local repo_id="$1"

    if [[ -z "$repo_id" ]]; then
        error "Repository ID required"
        return 1
    fi

    info "Disabling repository: $repo_id"

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf config-manager --set-disabled "$repo_id" || {
            error "Failed to disable repository: $repo_id"
            return 1
        }
    else
        yum-config-manager --disable "$repo_id" || {
            error "Failed to disable repository: $repo_id"
            return 1
        }
    fi

    success "Repository disabled: $repo_id"
}

# Add custom repository
add_repo() {
    local repo_id="$1"
    local repo_url="$2"
    local gpg_key="${3:-}"

    if [[ -z "$repo_id" ]] || [[ -z "$repo_url" ]]; then
        error "Repository ID and URL required"
        return 1
    fi

    info "Adding custom repository: $repo_id"

    local repo_file="/etc/yum.repos.d/${repo_id}.repo"

    {
        echo "[$repo_id]"
        echo "name=$repo_id"
        echo "baseurl=$repo_url"
        echo "enabled=1"
        [[ -n "$gpg_key" ]] && echo "gpgkey=$gpg_key"
        echo "gpgcheck=1" && [[ -n "$gpg_key" ]] || echo "gpgcheck=0"
    } > "$repo_file"

    success "Repository added: $repo_file"
}

# Show repository info
show_repo_info() {
    local repo_id="$1"

    if [[ -z "$repo_id" ]]; then
        error "Repository ID required"
        return 1
    fi

    info "Repository information for: $repo_id"

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf repoinfo "$repo_id" || {
            error "Repository not found: $repo_id"
            return 1
        }
    else
        yum repoinfo "$repo_id" || {
            error "Repository not found: $repo_id"
            return 1
        }
    fi
}

# Clean repository cache
clean_cache() {
    info "Cleaning repository cache..."

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf clean all || {
            error "Failed to clean cache"
            return 1
        }
    else
        yum clean all || {
            error "Failed to clean cache"
            return 1
        }
    fi

    success "Repository cache cleaned"
}

# Main function
main() {
    check_root
    detect_environment

    local action=""
    local repo_id=""
    local repo_url=""
    local gpg_key=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action="$2"
                shift 2
                ;;
            --repo)
                repo_id="$2"
                shift 2
                ;;
            --url)
                repo_url="$2"
                shift 2
                ;;
            --gpg-key)
                gpg_key="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    case "$action" in
        list)
            list_repos "all"
            ;;
        list-enabled)
            list_repos "enabled"
            ;;
        list-disabled)
            list_repos "disabled"
            ;;
        enable)
            enable_repo "$repo_id"
            ;;
        disable)
            disable_repo "$repo_id"
            ;;
        add)
            add_repo "$repo_id" "$repo_url" "$gpg_key"
            ;;
        info)
            show_repo_info "$repo_id"
            ;;
        clean)
            clean_cache
            ;;
        *)
            error "Unknown action: $action"
            error "Valid actions: list, list-enabled, list-disabled, enable, disable, add, info, clean"
            exit 1
            ;;
    esac
}

main "$@"
