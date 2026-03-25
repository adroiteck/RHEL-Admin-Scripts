#!/bin/bash

################################################################################
# Script: firewall-audit.sh
# Description: Audit firewalld configuration and rules
# Usage: ./firewall-audit.sh [--report] [--check-permissive]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with firewalld
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly REPORT_DIR="/var/log/firewall-reports"
readonly REPORT_FILE="$REPORT_DIR/firewall-audit-$(date +%Y%m%d-%H%M%S).txt"

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

# Check firewalld status
check_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        error "firewall-cmd not found. firewalld is not installed."
        return 1
    fi

    if ! systemctl is-active --quiet firewalld; then
        warn "firewalld is not running"
        return 1
    fi

    success "firewalld is running and active"
    return 0
}

# Initialize report
init_report() {
    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    cat > "$REPORT_FILE" << EOF
Firewall Audit Report
Generated: $(date '+%Y-%m-%d %H:%M:%S')
RHEL Version: $RHEL_VERSION
Hostname: $(hostname)
=======================================================

EOF
}

# Audit firewall zones
audit_zones() {
    info "=== Firewall Zones ==="
    echo "Firewall Zones:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local zones=()
    mapfile -t zones < <(firewall-cmd --get-zones 2>/dev/null)

    for zone in "${zones[@]}"; do
        [[ -z "$zone" ]] && continue

        echo "Zone: $zone"
        echo "Zone: $zone" >> "$REPORT_FILE"

        local active=$(firewall-cmd --get-active-zones 2>/dev/null | grep -q "^$zone" && echo "ACTIVE" || echo "INACTIVE")
        local default=$(firewall-cmd --get-default-zone 2>/dev/null)

        [[ "$zone" == "$default" ]] && active="ACTIVE (DEFAULT)"

        echo "  Status: $active"
        echo "  Status: $active" >> "$REPORT_FILE"

        # Show interfaces
        local interfaces=$(firewall-cmd --zone="$zone" --list-interfaces 2>/dev/null || echo "")
        if [[ -n "$interfaces" ]]; then
            echo "  Interfaces: $interfaces"
            echo "  Interfaces: $interfaces" >> "$REPORT_FILE"
        fi

        echo "" >> "$REPORT_FILE"
    done

    echo ""
}

# Audit services
audit_services() {
    info "=== Enabled Services by Zone ==="
    echo "Services by Zone:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local zones=()
    mapfile -t zones < <(firewall-cmd --get-zones 2>/dev/null)

    for zone in "${zones[@]}"; do
        [[ -z "$zone" ]] && continue

        local services=$(firewall-cmd --zone="$zone" --list-services 2>/dev/null || echo "")

        if [[ -n "$services" ]]; then
            echo "Zone: $zone"
            echo "Zone: $zone" >> "$REPORT_FILE"
            echo "  Services: $services"
            echo "  Services: $services" >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"
        fi
    done

    echo ""
}

# Audit ports
audit_ports() {
    info "=== Open Ports by Zone ==="
    echo "Ports by Zone:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local zones=()
    mapfile -t zones < <(firewall-cmd --get-zones 2>/dev/null)

    for zone in "${zones[@]}"; do
        [[ -z "$zone" ]] && continue

        local ports=$(firewall-cmd --zone="$zone" --list-ports 2>/dev/null || echo "")

        if [[ -n "$ports" ]]; then
            echo "Zone: $zone - Ports: $ports"
            echo "Zone: $zone - Ports: $ports" >> "$REPORT_FILE"
        fi
    done

    echo ""
    echo "" >> "$REPORT_FILE"
}

# Audit rich rules
audit_rich_rules() {
    info "=== Rich Rules by Zone ==="
    echo "Rich Rules:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local zones=()
    mapfile -t zones < <(firewall-cmd --get-zones 2>/dev/null)

    local rich_count=0

    for zone in "${zones[@]}"; do
        [[ -z "$zone" ]] && continue

        local rules=$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || echo "")

        if [[ -n "$rules" ]]; then
            echo "Zone: $zone"
            echo "Zone: $zone" >> "$REPORT_FILE"

            while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                echo "  $rule"
                echo "  $rule" >> "$REPORT_FILE"
                ((rich_count++))

                # Flag permissive rules
                if [[ "$rule" =~ "family='ipv4' accept" ]] || [[ "$rule" =~ "source address='0.0.0.0/0'" ]]; then
                    warn "Permissive rule detected: $rule"
                fi
            done <<< "$rules"

            echo "" >> "$REPORT_FILE"
        fi
    done

    [[ $rich_count -eq 0 ]] && echo "No rich rules configured"
    echo ""
}

# Audit direct rules
audit_direct_rules() {
    info "=== Direct Rules ==="
    echo "Direct Rules:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local rules=$(firewall-cmd --direct --get-all-rules 2>/dev/null || echo "")

    if [[ -n "$rules" ]]; then
        echo "Direct firewall rules found:"
        echo "$rules" | while read -r rule; do
            [[ -z "$rule" ]] && continue
            echo "  $rule"
            echo "  $rule" >> "$REPORT_FILE"
        done
    else
        echo "No direct rules configured"
        echo "No direct rules configured" >> "$REPORT_FILE"
    fi

    echo ""
    echo "" >> "$REPORT_FILE"
}

# Check for overly permissive rules
check_permissive_rules() {
    info "=== Checking for Overly Permissive Rules ==="
    echo "Permissive Rule Check:" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local zones=()
    mapfile -t zones < <(firewall-cmd --get-zones 2>/dev/null)

    local permissive_count=0

    for zone in "${zones[@]}"; do
        [[ -z "$zone" ]] && continue

        # Check for rules allowing all traffic
        local rules=$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null || echo "")

        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue

            if [[ "$rule" =~ "source address='0.0.0.0/0'" ]] || \
               [[ "$rule" =~ "source address='::/0'" ]] || \
               [[ "$rule" =~ "family='ipv4' accept" ]]; then
                warn "Permissive rule in zone $zone: $rule"
                ((permissive_count++))
            fi
        done <<< "$rules"
    done

    echo "Permissive rules found: $permissive_count"
    echo "Permissive rules found: $permissive_count" >> "$REPORT_FILE"

    [[ $permissive_count -eq 0 ]] && success "No overly permissive rules detected"

    echo ""
    echo "" >> "$REPORT_FILE"
}

# Display report
display_report() {
    if [[ -f "$REPORT_FILE" ]]; then
        info "Report generated: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --report           Generate detailed audit report
  --check-permissive Focus on checking permissive rules
  --help             Show this help message

Examples:
  $(basename "$0")                  # Run firewall audit
  $(basename "$0") --report         # Generate detailed report
  $(basename "$0") --check-permissive  # Check for permissive rules

EOF
}

# Main execution
main() {
    local generate_report=false check_permissive=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report) generate_report=true; shift ;;
            --check-permissive) check_permissive=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    detect_rhel_version

    info "RHEL Version: $RHEL_VERSION"

    if ! check_firewalld; then
        exit 1
    fi

    init_report

    audit_zones
    audit_services
    audit_ports
    audit_rich_rules
    audit_direct_rules

    if [[ "$check_permissive" == "true" ]]; then
        check_permissive_rules
    fi

    if [[ "$generate_report" == "true" ]]; then
        display_report
    fi

    success "Firewall audit complete"
}

main "$@"
