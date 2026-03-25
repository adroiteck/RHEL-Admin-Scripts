#!/bin/bash

################################################################################
# Script: network-info.sh
# Description: Display comprehensive network information
# Usage: ./network-info.sh [--interface INTERFACE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
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

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Display system hostname and DNS
show_hostname_dns() {
    info "=== System Hostname and DNS ==="
    echo "Hostname: $(hostname)"
    echo "FQDN: $(hostname -f 2>/dev/null || echo "N/A")"
    echo ""
    echo "DNS Configuration:"

    if [[ -f /etc/resolv.conf ]]; then
        grep -E "^nameserver|^search|^domain" /etc/resolv.conf | awk '{print "  " $0}'
    else
        echo "  No /etc/resolv.conf found"
    fi

    echo ""
}

# Display network interfaces
show_interfaces() {
    local filter_interface="${1:-.}"

    info "=== Network Interfaces ==="

    if command -v ip &>/dev/null; then
        ip -c=off addr show | grep -E "^[0-9]+:|inet|inet6|link/ether" | while read -r line; do
            if [[ "$line" =~ ^[0-9]+: ]]; then
                echo ""
                echo "$line" | sed 's/^[0-9]*: //' | sed 's/:$//'
            else
                echo "  $line"
            fi
        done
    else
        ifconfig 2>/dev/null | grep -E "^[a-z]|inet|HWaddr" || echo "No interface information available"
    fi

    echo ""
}

# Display routing table
show_routes() {
    info "=== Routing Table ==="

    if command -v ip &>/dev/null; then
        ip -c=off route show | awk '{print "  " $0}'
    else
        route -n | tail -n +3 | awk '{print "  " $0}'
    fi

    echo ""
}

# Display gateway information
show_gateway() {
    info "=== Gateway Information ==="

    local default_route=$(ip -c=off route show default 2>/dev/null | grep -oP 'via \K[^ ]+' || echo "Not configured")
    echo "Default Gateway: $default_route"

    local gateway_interface=$(ip -c=off route show default 2>/dev/null | grep -oP 'dev \K[^ ]+' || echo "N/A")
    echo "Gateway Interface: $gateway_interface"

    echo ""
}

# Display bond/team information
show_bonding_info() {
    info "=== Bonding/Teaming Information ==="

    local has_bonds=false
    local has_teams=false

    if [[ -d /sys/class/net/bonding_masters ]] && [[ -s /sys/class/net/bonding_masters ]]; then
        has_bonds=true
        echo "Bonded Interfaces:"
        cat /sys/class/net/bonding_masters | tr ' ' '\n' | while read -r bond; do
            [[ -z "$bond" ]] && continue
            echo "  $bond:"
            cat /proc/net/bonding/"$bond" 2>/dev/null | grep -E "Slave Interface|Status" | awk '{print "    " $0}'
        done
    fi

    if command -v nmcli &>/dev/null; then
        if nmcli connection show | grep -q "team"; then
            has_teams=true
            echo "Team Interfaces:"
            nmcli connection show | grep "team" | awk '{print "  " $1}'
        fi
    fi

    if [[ "$has_bonds" == "false" && "$has_teams" == "false" ]]; then
        echo "No bonding or teaming configured"
    fi

    echo ""
}

# Display VLAN information
show_vlan_info() {
    info "=== VLAN Information ==="

    if command -v ip &>/dev/null && ip link show | grep -q "vlan"; then
        ip -c=off link show | grep -E "^[0-9]+:.*vlan|vlan protocol" | while read -r line; do
            echo "  $line"
        done
    else
        echo "No VLAN interfaces found"
    fi

    echo ""
}

# Show NetworkManager or network-scripts configuration
show_network_config() {
    info "=== Network Configuration Method ==="

    if [[ $RHEL_VERSION -ge 8 ]]; then
        if systemctl is-active --quiet NetworkManager; then
            success "Using NetworkManager (RHEL $RHEL_VERSION)"
            echo ""
            echo "Active connections (nmcli):"
            nmcli connection show --active 2>/dev/null | grep "NAME\|TYPE" | awk '{print "  " $0}' || true
        else
            warn "Using network-scripts (RHEL $RHEL_VERSION)"
        fi
    else
        warn "Using network-scripts (RHEL $RHEL_VERSION)"

        if [[ -d /etc/sysconfig/network-scripts ]]; then
            echo ""
            echo "Network interface configs:"
            ls -1 /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | while read -r file; do
                echo "  $(basename "$file")"
            done
        fi
    fi

    echo ""
}

# Display IP connectivity test
test_connectivity() {
    info "=== Network Connectivity Test ==="

    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        success "Internet connectivity: OK"
    else
        warn "Internet connectivity: No response (8.8.8.8)"
    fi

    if ping -c 1 -W 2 "$(ip -c=off route show default | grep -oP 'via \K[^ ]+' || echo '127.0.0.1')" &>/dev/null; then
        success "Gateway connectivity: OK"
    else
        warn "Gateway connectivity: Failed"
    fi

    echo ""
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --interface INTERFACE    Show details for specific interface
  --help                   Show this help message

Examples:
  $(basename "$0")                      # Show all network info
  $(basename "$0") --interface eth0     # Show eth0 details

EOF
}

# Main execution
main() {
    local filter_interface=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interface) filter_interface="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    detect_rhel_version

    info "RHEL Network Information"
    info "RHEL Version: $RHEL_VERSION"
    info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    show_hostname_dns
    show_interfaces "$filter_interface"
    show_routes
    show_gateway
    show_bonding_info
    show_vlan_info
    show_network_config
    test_connectivity

    success "Network information gathering complete"
}

main "$@"
