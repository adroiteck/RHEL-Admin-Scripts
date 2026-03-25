#!/bin/bash

################################################################################
# Script: configure-static-ip.sh
# Description: Configure static IP address with NetworkManager or network-scripts
# Usage: ./configure-static-ip.sh --interface ETH0 --ip 192.168.1.100 --netmask 255.255.255.0 --gateway 192.168.1.1 --dns 8.8.8.8
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly BACKUP_DIR="/etc/network-backup"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)

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

# Validate IP address format
validate_ip() {
    local ip="$1"

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        error "Invalid IP address: $ip"
        return 1
    fi
}

# Create backup directory
create_backup() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        info "Created backup directory: $BACKUP_DIR"
    fi
}

# Backup existing configuration (NetworkManager)
backup_nm_config() {
    local interface="$1"

    if systemctl is-active --quiet NetworkManager; then
        local conn_name=$(nmcli -g NAME connection show | grep -i "$interface" || echo "$interface")

        if [[ -n "$conn_name" ]]; then
            local backup_file="$BACKUP_DIR/${conn_name}-${TIMESTAMP}.backup"
            nmcli connection show "$conn_name" > "$backup_file"
            info "Backed up NetworkManager config: $backup_file"
        fi
    fi
}

# Backup existing configuration (network-scripts)
backup_scripts_config() {
    local interface="$1"
    local config_file="/etc/sysconfig/network-scripts/ifcfg-$interface"

    if [[ -f "$config_file" ]]; then
        local backup_file="$BACKUP_DIR/ifcfg-${interface}-${TIMESTAMP}.backup"
        cp "$config_file" "$backup_file"
        info "Backed up network-scripts config: $backup_file"
    fi
}

# Validate interface exists
validate_interface() {
    local interface="$1"

    if ! ip link show "$interface" &>/dev/null; then
        error "Interface $interface does not exist"
        return 1
    fi

    return 0
}

# Configure static IP using NetworkManager (RHEL 8/9)
configure_nm() {
    local interface="$1"
    local ip="$2"
    local netmask="$3"
    local gateway="$4"
    local dns="$5"

    # Convert netmask to CIDR
    local cidr=$(netmask_to_cidr "$netmask")

    info "Configuring static IP using NetworkManager..."

    backup_nm_config "$interface"

    # Get or create connection
    local conn_name=$(nmcli -g NAME connection show | grep -i "$interface" || echo "$interface")

    if [[ -z "$conn_name" ]]; then
        # Create new connection
        nmcli connection add type ethernet con-name "$interface" ifname "$interface"
        conn_name="$interface"
    fi

    # Set IPv4 configuration
    nmcli connection modify "$conn_name" ipv4.method manual
    nmcli connection modify "$conn_name" ipv4.addresses "$ip/$cidr"
    nmcli connection modify "$conn_name" ipv4.gateway "$gateway"

    if [[ -n "$dns" ]]; then
        nmcli connection modify "$conn_name" ipv4.dns "$dns"
        nmcli connection modify "$conn_name" ipv4.ignore-auto-dns yes
    fi

    # Apply configuration
    nmcli connection down "$conn_name" 2>/dev/null || true
    nmcli connection up "$conn_name"

    success "Static IP configured via NetworkManager"
    return 0
}

# Configure static IP using network-scripts (RHEL 7)
configure_scripts() {
    local interface="$1"
    local ip="$2"
    local netmask="$3"
    local gateway="$4"
    local dns="$5"

    local config_file="/etc/sysconfig/network-scripts/ifcfg-$interface"

    info "Configuring static IP using network-scripts..."

    backup_scripts_config "$interface"

    # Create or update configuration file
    cat > "$config_file" << EOF
TYPE=Ethernet
BOOTPROTO=none
IPADDR=$ip
NETMASK=$netmask
GATEWAY=$gateway
DEVICE=$interface
ONBOOT=yes
EOF

    if [[ -n "$dns" ]]; then
        echo "DNS1=$dns" >> "$config_file"
    fi

    info "Configuration file created: $config_file"

    # Restart networking
    systemctl restart network

    success "Static IP configured via network-scripts"
    return 0
}

# Convert netmask to CIDR notation
netmask_to_cidr() {
    local netmask="$1"
    local cidr=0

    IFS='.' read -ra parts <<< "$netmask"

    for part in "${parts[@]}"; do
        case "$part" in
            255) cidr=$((cidr + 8)) ;;
            254) cidr=$((cidr + 7)) ;;
            252) cidr=$((cidr + 6)) ;;
            248) cidr=$((cidr + 5)) ;;
            240) cidr=$((cidr + 4)) ;;
            224) cidr=$((cidr + 3)) ;;
            192) cidr=$((cidr + 2)) ;;
            128) cidr=$((cidr + 1)) ;;
            0) cidr=$((cidr + 0)) ;;
            *) error "Invalid netmask: $netmask"; return 1 ;;
        esac
    done

    echo "$cidr"
}

# Display current configuration
show_current_config() {
    local interface="$1"

    info "Current configuration for $interface:"
    ip -c=off addr show "$interface" | grep -E "inet|link/ether"
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") --interface IFACE --ip IP --netmask MASK --gateway GW [--dns DNS]

Required Options:
  --interface IFACE     Network interface name (e.g., eth0, ens3)
  --ip IP               Static IP address (e.g., 192.168.1.100)
  --netmask MASK        Subnet mask (e.g., 255.255.255.0)
  --gateway GW          Default gateway (e.g., 192.168.1.1)

Optional Options:
  --dns DNS             DNS server (e.g., 8.8.8.8)
  --help                Show this help message

Examples:
  $(basename "$0") --interface eth0 --ip 192.168.1.100 --netmask 255.255.255.0 --gateway 192.168.1.1
  $(basename "$0") --interface ens3 --ip 10.0.0.50 --netmask 255.255.255.0 --gateway 10.0.0.1 --dns 8.8.8.8

Note:
  - Configuration will be backed up to: $BACKUP_DIR
  - RHEL 8/9 uses NetworkManager
  - RHEL 7 uses network-scripts

EOF
}

# Main execution
main() {
    local interface="" ip="" netmask="" gateway="" dns=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interface) interface="$2"; shift 2 ;;
            --ip) ip="$2"; shift 2 ;;
            --netmask) netmask="$2"; shift 2 ;;
            --gateway) gateway="$2"; shift 2 ;;
            --dns) dns="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$interface" || -z "$ip" || -z "$netmask" || -z "$gateway" ]]; then
        error "Missing required arguments"
        usage
        exit 1
    fi

    check_root
    detect_rhel_version

    info "RHEL Version: $RHEL_VERSION"

    # Validate inputs
    validate_interface "$interface" || exit 1
    validate_ip "$ip" || exit 1
    validate_ip "$gateway" || exit 1

    [[ -n "$dns" ]] && validate_ip "$dns" || true

    echo ""
    show_current_config "$interface"
    echo ""

    create_backup

    # Choose configuration method based on RHEL version
    if [[ $RHEL_VERSION -ge 8 ]]; then
        configure_nm "$interface" "$ip" "$netmask" "$gateway" "$dns"
    else
        configure_scripts "$interface" "$ip" "$netmask" "$gateway" "$dns"
    fi

    echo ""
    success "Configuration complete. Displaying new configuration:"
    show_current_config "$interface"
}

main "$@"
