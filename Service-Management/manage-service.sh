#!/bin/bash

################################################################################
# Script: manage-service.sh
# Description: Wrapper for managing services with comprehensive logging
# Usage: ./manage-service.sh --action {start|stop|restart|enable|disable|mask|unmask} --service SERVICE_NAME
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with systemd
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly LOG_FILE="/var/log/service-changes.log"
readonly ACTION_LOG_DIR="/var/log/service-management"

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

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Initialize logging
init_logging() {
    if [[ ! -d "$ACTION_LOG_DIR" ]]; then
        mkdir -p "$ACTION_LOG_DIR"
    fi

    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
    fi
}

# Log state change
log_change() {
    local service="$1"
    local action="$2"
    local before="$3"
    local after="$4"
    local status="$5"

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-root}"

    echo "[$timestamp] USER=$user ACTION=$action SERVICE=$service STATUS=$status BEFORE=$before AFTER=$after" >> "$LOG_FILE"
}

# Get service status
get_service_status() {
    local service="$1"

    if ! systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "inactive"
    else
        echo "active"
    fi
}

# Get service enabled status
get_enabled_status() {
    local service="$1"

    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

# Manage service
manage_service() {
    local action="$1"
    local service="$2"

    if ! systemctl list-unit-files "$service.service" &>/dev/null; then
        error "Service '$service' not found"
        return 1
    fi

    local before_active=$(get_service_status "$service")
    local before_enabled=$(get_enabled_status "$service")

    info "Performing action: $action on service: $service"
    info "Before - Active: $before_active, Enabled: $before_enabled"

    case "$action" in
        start)
            if systemctl start "$service"; then
                local after_active=$(get_service_status "$service")
                success "Service $service started successfully"
                log_change "$service" "start" "$before_active" "$after_active" "success"
                return 0
            else
                error "Failed to start service $service"
                log_change "$service" "start" "$before_active" "unknown" "failed"
                return 1
            fi
            ;;
        stop)
            if systemctl stop "$service"; then
                local after_active=$(get_service_status "$service")
                success "Service $service stopped successfully"
                log_change "$service" "stop" "$before_active" "$after_active" "success"
                return 0
            else
                error "Failed to stop service $service"
                log_change "$service" "stop" "$before_active" "unknown" "failed"
                return 1
            fi
            ;;
        restart)
            if systemctl restart "$service"; then
                local after_active=$(get_service_status "$service")
                success "Service $service restarted successfully"
                log_change "$service" "restart" "$before_active" "$after_active" "success"
                return 0
            else
                error "Failed to restart service $service"
                log_change "$service" "restart" "$before_active" "unknown" "failed"
                return 1
            fi
            ;;
        enable)
            if systemctl enable "$service"; then
                local after_enabled=$(get_enabled_status "$service")
                success "Service $service enabled for boot"
                log_change "$service" "enable" "$before_enabled" "$after_enabled" "success"
                return 0
            else
                error "Failed to enable service $service"
                log_change "$service" "enable" "$before_enabled" "unknown" "failed"
                return 1
            fi
            ;;
        disable)
            if systemctl disable "$service"; then
                local after_enabled=$(get_enabled_status "$service")
                success "Service $service disabled from boot"
                log_change "$service" "disable" "$before_enabled" "$after_enabled" "success"
                return 0
            else
                error "Failed to disable service $service"
                log_change "$service" "disable" "$before_enabled" "unknown" "failed"
                return 1
            fi
            ;;
        mask)
            if systemctl mask "$service"; then
                success "Service $service masked"
                log_change "$service" "mask" "$before_enabled" "masked" "success"
                return 0
            else
                error "Failed to mask service $service"
                log_change "$service" "mask" "$before_enabled" "unknown" "failed"
                return 1
            fi
            ;;
        unmask)
            if systemctl unmask "$service"; then
                success "Service $service unmasked"
                log_change "$service" "unmask" "$before_enabled" "$before_enabled" "success"
                return 0
            else
                error "Failed to unmask service $service"
                log_change "$service" "unmask" "$before_enabled" "unknown" "failed"
                return 1
            fi
            ;;
        *)
            error "Unknown action: $action"
            return 1
            ;;
    esac
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") --action ACTION --service SERVICE_NAME

Actions:
  start       - Start a service
  stop        - Stop a service
  restart     - Restart a service
  enable      - Enable service at boot
  disable     - Disable service at boot
  mask        - Mask a service (prevent startup)
  unmask      - Unmask a service

Examples:
  $(basename "$0") --action start --service httpd
  $(basename "$0") --action enable --service sshd
  $(basename "$0") --action restart --service postgresql

EOF
}

# Main execution
main() {
    local action="" service=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action) action="$2"; shift 2 ;;
            --service) service="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$action" || -z "$service" ]]; then
        error "Missing required arguments"
        usage
        exit 1
    fi

    check_root
    detect_rhel_version
    init_logging

    info "RHEL Version: $RHEL_VERSION"
    manage_service "$action" "$service"
}

main "$@"
