#!/bin/bash

################################################################################
# Script: manage-firewall-rules.sh
# Description: Add/remove firewall rules with logging and persistence
# Usage: ./manage-firewall-rules.sh --action {add|remove} --port PORT [--protocol PROTO]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with firewalld
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly LOG_FILE="/var/log/firewall-rules.log"
readonly DEFAULT_ZONE="public"

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

# Check firewalld status
check_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        error "firewall-cmd not found. firewalld is not installed."
        return 1
    fi

    if ! systemctl is-active --quiet firewalld; then
        error "firewalld is not running. Please start it first."
        return 1
    fi

    return 0
}

# Log rule change
log_rule_change() {
    local action="$1"
    local rule_type="$2"
    local rule_value="$3"
    local status="$4"
    local zone="${5:-$DEFAULT_ZONE}"

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local user="${SUDO_USER:-root}"

    echo "[$timestamp] USER=$user ACTION=$action TYPE=$rule_type RULE=$rule_value ZONE=$zone STATUS=$status" >> "$LOG_FILE"
}

# Add port rule
add_port_rule() {
    local port="$1"
    local protocol="${2:-tcp}"
    local zone="${3:-$DEFAULT_ZONE}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        error "Invalid port number: $port"
        return 1
    fi

    if ! [[ "$protocol" =~ ^(tcp|udp)$ ]]; then
        error "Invalid protocol. Use 'tcp' or 'udp'"
        return 1
    fi

    info "Adding port rule: $port/$protocol in zone $zone"

    if firewall-cmd --zone="$zone" --add-port="$port/$protocol" --permanent; then
        firewall-cmd --reload
        success "Port $port/$protocol added permanently to zone $zone"
        log_rule_change "add" "port" "$port/$protocol" "success" "$zone"
        return 0
    else
        error "Failed to add port rule"
        log_rule_change "add" "port" "$port/$protocol" "failed" "$zone"
        return 1
    fi
}

# Remove port rule
remove_port_rule() {
    local port="$1"
    local protocol="${2:-tcp}"
    local zone="${3:-$DEFAULT_ZONE}"

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        error "Invalid port number: $port"
        return 1
    fi

    info "Removing port rule: $port/$protocol from zone $zone"

    if firewall-cmd --zone="$zone" --remove-port="$port/$protocol" --permanent; then
        firewall-cmd --reload
        success "Port $port/$protocol removed from zone $zone"
        log_rule_change "remove" "port" "$port/$protocol" "success" "$zone"
        return 0
    else
        error "Failed to remove port rule"
        log_rule_change "remove" "port" "$port/$protocol" "failed" "$zone"
        return 1
    fi
}

# Add service rule
add_service_rule() {
    local service="$1"
    local zone="${2:-$DEFAULT_ZONE}"

    info "Adding service rule: $service in zone $zone"

    if firewall-cmd --zone="$zone" --add-service="$service" --permanent; then
        firewall-cmd --reload
        success "Service $service added to zone $zone"
        log_rule_change "add" "service" "$service" "success" "$zone"
        return 0
    else
        error "Failed to add service rule"
        log_rule_change "add" "service" "$service" "failed" "$zone"
        return 1
    fi
}

# Remove service rule
remove_service_rule() {
    local service="$1"
    local zone="${2:-$DEFAULT_ZONE}"

    info "Removing service rule: $service from zone $zone"

    if firewall-cmd --zone="$zone" --remove-service="$service" --permanent; then
        firewall-cmd --reload
        success "Service $service removed from zone $zone"
        log_rule_change "remove" "service" "$service" "success" "$zone"
        return 0
    else
        error "Failed to remove service rule"
        log_rule_change "remove" "service" "$service" "failed" "$zone"
        return 1
    fi
}

# Add rich rule
add_rich_rule() {
    local rule="$1"
    local zone="${2:-$DEFAULT_ZONE}"

    info "Adding rich rule in zone $zone: $rule"

    if firewall-cmd --zone="$zone" --add-rich-rule="$rule" --permanent; then
        firewall-cmd --reload
        success "Rich rule added to zone $zone"
        log_rule_change "add" "rich-rule" "$rule" "success" "$zone"
        return 0
    else
        error "Failed to add rich rule"
        log_rule_change "add" "rich-rule" "$rule" "failed" "$zone"
        return 1
    fi
}

# Remove rich rule
remove_rich_rule() {
    local rule="$1"
    local zone="${2:-$DEFAULT_ZONE}"

    info "Removing rich rule from zone $zone: $rule"

    if firewall-cmd --zone="$zone" --remove-rich-rule="$rule" --permanent; then
        firewall-cmd --reload
        success "Rich rule removed from zone $zone"
        log_rule_change "remove" "rich-rule" "$rule" "success" "$zone"
        return 0
    else
        error "Failed to remove rich rule"
        log_rule_change "remove" "rich-rule" "$rule" "failed" "$zone"
        return 1
    fi
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") --action {add|remove} [OPTIONS]

Options:
  --action {add|remove}    Action to perform (required)
  --port PORT              Port number (1-65535)
  --protocol {tcp|udp}     Protocol (default: tcp)
  --service SERVICE        Service name (http, https, ssh, etc.)
  --source IP              Source IP address for rich rules
  --zone ZONE              Firewall zone (default: public)
  --rule RULE              Complete rich rule specification
  --help                   Show this help message

Examples:
  $(basename "$0") --action add --port 8080 --protocol tcp
  $(basename "$0") --action add --service http
  $(basename "$0") --action remove --port 3306 --protocol tcp
  $(basename "$0") --action add --zone internal --port 5432 --protocol tcp
  $(basename "$0") --action add --zone public --rule "rule family='ipv4' source address='192.168.1.0/24' port protocol='tcp' port='22' accept"

EOF
}

# Main execution
main() {
    local action="" port="" protocol="tcp" service="" source="" zone="$DEFAULT_ZONE" rule=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action) action="$2"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --protocol) protocol="$2"; shift 2 ;;
            --service) service="$2"; shift 2 ;;
            --source) source="$2"; shift 2 ;;
            --zone) zone="$2"; shift 2 ;;
            --rule) rule="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$action" ]]; then
        error "Missing required argument: --action"
        usage
        exit 1
    fi

    if [[ ! "$action" =~ ^(add|remove)$ ]]; then
        error "Invalid action: $action"
        usage
        exit 1
    fi

    check_root
    detect_rhel_version

    if ! check_firewalld; then
        exit 1
    fi

    info "RHEL Version: $RHEL_VERSION"
    info "Using zone: $zone"

    if [[ -n "$rule" ]]; then
        case "$action" in
            add) add_rich_rule "$rule" "$zone" ;;
            remove) remove_rich_rule "$rule" "$zone" ;;
        esac
    elif [[ -n "$port" ]]; then
        case "$action" in
            add) add_port_rule "$port" "$protocol" "$zone" ;;
            remove) remove_port_rule "$port" "$protocol" "$zone" ;;
        esac
    elif [[ -n "$service" ]]; then
        case "$action" in
            add) add_service_rule "$service" "$zone" ;;
            remove) remove_service_rule "$service" "$zone" ;;
        esac
    else
        error "Must specify --port, --service, or --rule"
        usage
        exit 1
    fi
}

main "$@"
