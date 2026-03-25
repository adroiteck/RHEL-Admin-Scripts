#!/bin/bash

################################################################################
# Script: manage-firewall-zones.sh
# Description: Advanced firewalld zone management including zone creation,
#              interface assignment, default zone configuration, and rich rules.
# Usage: manage-firewall-zones.sh --action list
#        manage-firewall-zones.sh --action create --zone custom
#        manage-firewall-zones.sh --action add-interface --zone dmz --interface eth1
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8 with firewalld
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

# Check if firewalld is running
check_firewalld() {
    if ! systemctl is-active firewalld &>/dev/null; then
        error "firewalld is not running. Start it with: systemctl start firewalld"
        exit 1
    fi
}

# List all zones
list_zones() {
    echo ""
    echo "================================ FIREWALL ZONES ================================"
    firewall-cmd --get-zones

    echo ""
    echo "================================ DEFAULT ZONE ================================"
    firewall-cmd --get-default-zone

    echo ""
    echo "================================ ZONE DETAILS ================================"
    for zone in $(firewall-cmd --get-zones); do
        echo ""
        info "Zone: $zone"
        firewall-cmd --zone="$zone" --list-all | sed 's/^/  /'
    done
}

# Create a new zone
create_zone() {
    local zone=$1

    if firewall-cmd --get-zones | grep -q "\\b$zone\\b"; then
        warn "Zone already exists: $zone"
        return 1
    fi

    info "Creating zone: $zone"
    if ! firewall-cmd --permanent --new-zone="$zone"; then
        error "Failed to create zone: $zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Zone created: $zone"
}

# Delete a zone
delete_zone() {
    local zone=$1

    if [[ "$zone" == "public" || "$zone" == "internal" || "$zone" == "external" ]]; then
        warn "Cannot delete default zone: $zone"
        return 1
    fi

    info "Deleting zone: $zone"
    if ! firewall-cmd --permanent --delete-zone="$zone"; then
        error "Failed to delete zone: $zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Zone deleted: $zone"
}

# Add interface to zone
add_interface() {
    local zone=$1
    local interface=$2

    if ! ip link show "$interface" &>/dev/null; then
        error "Interface not found: $interface"
        return 1
    fi

    info "Adding interface $interface to zone $zone"
    if ! firewall-cmd --permanent --zone="$zone" --add-interface="$interface"; then
        error "Failed to add interface to zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Interface $interface added to zone $zone"
}

# Remove interface from zone
remove_interface() {
    local zone=$1
    local interface=$2

    info "Removing interface $interface from zone $zone"
    if ! firewall-cmd --permanent --zone="$zone" --remove-interface="$interface"; then
        error "Failed to remove interface from zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Interface $interface removed from zone $zone"
}

# Set default zone
set_default_zone() {
    local zone=$1

    if ! firewall-cmd --get-zones | grep -q "\\b$zone\\b"; then
        error "Zone does not exist: $zone"
        return 1
    fi

    info "Setting default zone to: $zone"
    if ! firewall-cmd --set-default-zone="$zone"; then
        error "Failed to set default zone"
        return 1
    fi

    success "Default zone set to: $zone"
}

# Add service to zone
add_service() {
    local zone=$1
    local service=$2

    info "Adding service $service to zone $zone"
    if ! firewall-cmd --permanent --zone="$zone" --add-service="$service"; then
        error "Failed to add service to zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Service $service added to zone $zone"
}

# Add port to zone
add_port() {
    local zone=$1
    local port=$2
    local protocol=${3:-tcp}

    info "Adding port $port/$protocol to zone $zone"
    if ! firewall-cmd --permanent --zone="$zone" --add-port="$port/$protocol"; then
        error "Failed to add port to zone"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Port $port/$protocol added to zone $zone"
}

# Add rich rule
add_rich_rule() {
    local zone=$1
    local rule=$2

    info "Adding rich rule to zone $zone: $rule"
    if ! firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"; then
        error "Failed to add rich rule"
        return 1
    fi

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Rich rule added"
}

# Copy zone configuration
copy_zone() {
    local source_zone=$1
    local dest_zone=$2

    if ! firewall-cmd --get-zones | grep -q "\\b$source_zone\\b"; then
        error "Source zone does not exist: $source_zone"
        return 1
    fi

    if firewall-cmd --get-zones | grep -q "\\b$dest_zone\\b"; then
        error "Destination zone already exists: $dest_zone"
        return 1
    fi

    info "Copying zone $source_zone to $dest_zone"

    # Create destination zone
    if ! firewall-cmd --permanent --new-zone="$dest_zone"; then
        error "Failed to create destination zone"
        return 1
    fi

    # Copy services
    for service in $(firewall-cmd --zone="$source_zone" --list-services); do
        firewall-cmd --permanent --zone="$dest_zone" --add-service="$service"
    done

    # Copy ports
    for port in $(firewall-cmd --zone="$source_zone" --list-ports); do
        firewall-cmd --permanent --zone="$dest_zone" --add-port="$port"
    done

    if ! firewall-cmd --reload; then
        error "Failed to reload firewall"
        return 1
    fi

    success "Zone copied: $source_zone -> $dest_zone"
}

# Parse arguments
ACTION=""
ZONE=""
INTERFACE=""
SERVICE=""
PORT=""
PROTOCOL="tcp"
RICH_RULE=""
SOURCE_ZONE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --action) ACTION="$2"; shift 2 ;;
        --zone) ZONE="$2"; shift 2 ;;
        --interface) INTERFACE="$2"; shift 2 ;;
        --service) SERVICE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --protocol) PROTOCOL="$2"; shift 2 ;;
        --rule) RICH_RULE="$2"; shift 2 ;;
        --source) SOURCE_ZONE="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    error "Missing required argument: --action"
    exit 1
fi

check_root
detect_rhel_version
check_firewalld

case "$ACTION" in
    list)
        list_zones
        ;;
    create)
        [[ -z "$ZONE" ]] && error "Missing: --zone" && exit 1
        create_zone "$ZONE"
        ;;
    delete)
        [[ -z "$ZONE" ]] && error "Missing: --zone" && exit 1
        delete_zone "$ZONE"
        ;;
    add-interface)
        [[ -z "$ZONE" || -z "$INTERFACE" ]] && error "Missing: --zone and --interface" && exit 1
        add_interface "$ZONE" "$INTERFACE"
        ;;
    remove-interface)
        [[ -z "$ZONE" || -z "$INTERFACE" ]] && error "Missing: --zone and --interface" && exit 1
        remove_interface "$ZONE" "$INTERFACE"
        ;;
    set-default)
        [[ -z "$ZONE" ]] && error "Missing: --zone" && exit 1
        set_default_zone "$ZONE"
        ;;
    add-service)
        [[ -z "$ZONE" || -z "$SERVICE" ]] && error "Missing: --zone and --service" && exit 1
        add_service "$ZONE" "$SERVICE"
        ;;
    add-port)
        [[ -z "$ZONE" || -z "$PORT" ]] && error "Missing: --zone and --port" && exit 1
        add_port "$ZONE" "$PORT" "$PROTOCOL"
        ;;
    add-rule)
        [[ -z "$ZONE" || -z "$RICH_RULE" ]] && error "Missing: --zone and --rule" && exit 1
        add_rich_rule "$ZONE" "$RICH_RULE"
        ;;
    copy)
        [[ -z "$SOURCE_ZONE" || -z "$ZONE" ]] && error "Missing: --source and --zone" && exit 1
        copy_zone "$SOURCE_ZONE" "$ZONE"
        ;;
    *)
        error "Unknown action: $ACTION"
        exit 1
        ;;
esac
