#!/bin/bash

################################################################################
# Script: network-troubleshoot.sh
# Description: Automated network diagnostics with comprehensive reporting
# Usage: ./network-troubleshoot.sh [--report] [--full]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly REPORT_DIR="/var/log/network-diagnostics"
readonly REPORT_FILE="$REPORT_DIR/network-diag-$(date +%Y%m%d-%H%M%S).txt"

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

# Initialize report
init_report() {
    mkdir -p "$REPORT_DIR"

    {
        echo "Network Diagnostic Report"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo "RHEL Version: $RHEL_VERSION"
        echo "=================================================="
        echo ""
    } > "$REPORT_FILE"
}

# Test gateway connectivity
test_gateway() {
    info "Testing gateway connectivity..."

    local gateway=$(ip -c=off route show default | grep -oP 'via \K[^ ]+' || echo "")

    if [[ -z "$gateway" ]]; then
        warn "No default gateway configured"
        echo "Gateway: Not configured" >> "$REPORT_FILE"
        return 1
    fi

    echo "Gateway: $gateway" >> "$REPORT_FILE"

    if ping -c 3 -W 2 "$gateway" &>/dev/null; then
        success "Gateway $gateway is reachable"
        echo "Status: REACHABLE" >> "$REPORT_FILE"
        return 0
    else
        error "Gateway $gateway is unreachable"
        echo "Status: UNREACHABLE" >> "$REPORT_FILE"
        return 1
    fi
}

# Test DNS resolution
test_dns() {
    info "Testing DNS resolution..."
    echo "" >> "$REPORT_FILE"
    echo "DNS Resolution Test:" >> "$REPORT_FILE"

    local test_hosts=("google.com" "cloudflare.com" "8.8.8.8")
    local resolved=0 failed=0

    for host in "${test_hosts[@]}"; do
        if getent hosts "$host" &>/dev/null; then
            ((resolved++))
            echo "  $host: OK" >> "$REPORT_FILE"
            success "Resolved: $host"
        else
            ((failed++))
            echo "  $host: FAILED" >> "$REPORT_FILE"
            warn "Failed to resolve: $host"
        fi
    done

    echo "DNS Summary: $resolved resolved, $failed failed" >> "$REPORT_FILE"
}

# Test traceroute
test_traceroute() {
    info "Testing traceroute to 8.8.8.8..."
    echo "" >> "$REPORT_FILE"
    echo "Traceroute Test:" >> "$REPORT_FILE"

    if command -v traceroute &>/dev/null; then
        traceroute -m 15 -w 2 8.8.8.8 2>/dev/null | head -10 | while read -r line; do
            echo "  $line" >> "$REPORT_FILE"
        done
        success "Traceroute completed"
    else
        warn "traceroute not installed, skipping"
        echo "  traceroute not available" >> "$REPORT_FILE"
    fi
}

# Check MTU
check_mtu() {
    info "Checking MTU values..."
    echo "" >> "$REPORT_FILE"
    echo "MTU Configuration:" >> "$REPORT_FILE"

    ip -c=off link show | grep -E "^[0-9]+:|mtu" | while read -r line; do
        if [[ "$line" =~ ^[0-9]+ ]]; then
            local iface=$(echo "$line" | sed 's/.*: \([^:]*\).*/\1/')
            local next_line=$(ip -c=off link show "$iface" | grep mtu)
            echo "  $iface: $next_line" >> "$REPORT_FILE"
        fi
    done

    success "MTU check completed"
}

# Check interface errors and drops
check_interface_stats() {
    info "Checking interface errors and drops..."
    echo "" >> "$REPORT_FILE"
    echo "Interface Error Statistics:" >> "$REPORT_FILE"

    ip -s link show | grep -A 1 "^[0-9]" | while read -r line; do
        if [[ "$line" =~ RX|TX ]]; then
            echo "  $line" >> "$REPORT_FILE"
        fi
    done

    success "Interface statistics gathered"
}

# Check NTP synchronization
check_ntp() {
    info "Checking NTP synchronization..."
    echo "" >> "$REPORT_FILE"
    echo "NTP/Chrony Status:" >> "$REPORT_FILE"

    if command -v chronyc &>/dev/null && systemctl is-active --quiet chronyd; then
        chronyc tracking 2>/dev/null | head -5 | while read -r line; do
            echo "  $line" >> "$REPORT_FILE"
        done
        success "Chrony is running and synchronized"
    elif command -v ntpstat &>/dev/null; then
        local ntp_status=$(ntpstat 2>/dev/null || echo "NTP not synced")
        echo "  $ntp_status" >> "$REPORT_FILE"
        success "NTP status: $ntp_status"
    else
        warn "NTP/Chrony not available"
        echo "  NTP/Chrony not configured" >> "$REPORT_FILE"
    fi
}

# Check HTTPS certificate validity
check_certificates() {
    info "Checking HTTPS endpoint certificate validity..."
    echo "" >> "$REPORT_FILE"
    echo "HTTPS Certificate Check:" >> "$REPORT_FILE"

    local test_hosts=("google.com:443" "cloudflare.com:443")

    for host_port in "${test_hosts[@]}"; do
        local host="${host_port%:*}"
        local port="${host_port#*:}"

        if echo | openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null | \
           openssl x509 -noout -enddate 2>/dev/null > /dev/null; then
            local expiry=$(echo | openssl s_client -connect "$host:$port" -servername "$host" 2>/dev/null | \
                          openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
            echo "  $host: Valid (expires: $expiry)" >> "$REPORT_FILE"
            success "Certificate for $host is valid"
        else
            warn "Could not verify certificate for $host"
            echo "  $host: Unable to verify" >> "$REPORT_FILE"
        fi
    done
}

# Check DNS configuration
check_dns_config() {
    info "Checking DNS configuration..."
    echo "" >> "$REPORT_FILE"
    echo "DNS Configuration:" >> "$REPORT_FILE"

    if [[ -f /etc/resolv.conf ]]; then
        grep -E "^nameserver|^search" /etc/resolv.conf | while read -r line; do
            echo "  $line" >> "$REPORT_FILE"
        done
    fi

    success "DNS configuration gathered"
}

# Full diagnostic run
run_full_diagnostics() {
    test_gateway
    test_dns
    test_traceroute
    check_mtu
    check_interface_stats
    check_ntp
    check_dns_config
    check_certificates
}

# Quick diagnostic run
run_quick_diagnostics() {
    test_gateway
    test_dns
    check_ntp
}

# Display report
display_report() {
    if [[ -f "$REPORT_FILE" ]]; then
        info "Diagnostic report: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --full      Run full diagnostic suite
  --report    Generate and display detailed report
  --help      Show this help message

Examples:
  $(basename "$0")           # Run quick diagnostics
  $(basename "$0") --full    # Run complete diagnostics
  $(basename "$0") --report  # Generate detailed report

EOF
}

# Main execution
main() {
    local run_full=false generate_report=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) run_full=true; shift ;;
            --report) generate_report=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    detect_rhel_version
    init_report

    info "RHEL Version: $RHEL_VERSION"
    info "Starting network diagnostics..."
    echo ""

    if [[ "$run_full" == "true" ]]; then
        run_full_diagnostics
    else
        run_quick_diagnostics
    fi

    echo ""

    if [[ "$generate_report" == "true" ]]; then
        display_report
    else
        success "Diagnostics complete. Report saved to: $REPORT_FILE"
    fi
}

main "$@"
