#!/bin/bash

################################################################################
# Script: check-open-ports.sh
# Description: Scan for open listening ports and validate against whitelist
# Usage: ./check-open-ports.sh [--whitelist FILE] [--report]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly DEFAULT_WHITELIST="/etc/allowed-ports.txt"
readonly REPORT_DIR="/var/log/port-reports"

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

# Get listening ports using ss (preferred) or netstat (fallback)
get_open_ports() {
    local ports=()

    if command -v ss &>/dev/null; then
        # Use ss - newer and more efficient
        mapfile -t ports < <(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | grep -oP ':\K[0-9]+$' | sort -u)
    elif command -v netstat &>/dev/null; then
        # Fallback to netstat
        mapfile -t ports < <(netstat -tlnp 2>/dev/null | tail -n +3 | awk '{print $4}' | grep -oP ':\K[0-9]+$' | sort -u)
    else
        error "Neither ss nor netstat available. Cannot scan ports."
        return 1
    fi

    printf '%s\n' "${ports[@]}"
}

# Get process information for a port
get_port_process() {
    local port="$1"

    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | head -1
    else
        netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | head -1
    fi
}

# Check if port is in whitelist
is_port_whitelisted() {
    local port="$1"
    local whitelist_file="$2"

    if [[ ! -f "$whitelist_file" ]]; then
        warn "Whitelist file not found: $whitelist_file"
        return 1
    fi

    if grep -q "^$port$" "$whitelist_file" 2>/dev/null; then
        return 0
    fi

    # Check for port ranges
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"

            if [[ "$port" -ge "$start" && "$port" -le "$end" ]]; then
                return 0
            fi
        fi
    done < "$whitelist_file"

    return 1
}

# Scan and validate open ports
scan_ports() {
    local whitelist_file="$1"
    local report_file="$2"

    info "Scanning for open listening ports..."

    local ports=()
    mapfile -t ports < <(get_open_ports)

    if [[ ${#ports[@]} -eq 0 ]]; then
        warn "No listening ports found"
        return
    fi

    success "Found ${#ports[@]} listening port(s)"
    echo ""

    local whitelisted=0 unauthorized=0

    printf "%-10s %-15s %-50s %s\n" "PORT" "STATUS" "PROCESS" "APPROVAL"
    printf "%s\n" "$(printf '=%.0s' {1..130})"

    for port in "${ports[@]}"; do
        local process=$(get_port_process "$port" || echo "unknown")
        local status="OPEN"

        if is_port_whitelisted "$port" "$whitelist_file"; then
            ((whitelisted++))
            status="APPROVED"
        else
            ((unauthorized++))
            warn "Unauthorized port: $port (process: $process)"
            status="UNAUTHORIZED"
        fi

        printf "%-10s %-15s %-50s %s\n" "$port" "$status" "$process" ""

        echo "Port: $port, Status: $status, Process: $process" >> "$report_file"
    done

    echo ""
    echo "$(printf '=%.0s' {1..130})"
    success "Summary: $whitelisted approved, $unauthorized unauthorized"

    echo "" >> "$report_file"
    echo "Summary: $whitelisted approved, $unauthorized unauthorized" >> "$report_file"

    if [[ $unauthorized -gt 0 ]]; then
        warn "Found $unauthorized unauthorized listening port(s)"
        return 1
    fi

    return 0
}

# Create sample whitelist
create_sample_whitelist() {
    local output_file="$1"

    cat > "$output_file" << 'EOF'
# Allowed ports whitelist
# Format: single port number or port range (start-end)
# Lines starting with # are comments

# SSH
22

# HTTP/HTTPS
80
443

# Common database ports
3306
5432
6379

# Port ranges (e.g., custom application ports)
8000-8100

# NTP
123

# DNS
53

# Mail services
25
110
143
587
993
995
EOF

    success "Sample whitelist created: $output_file"
    info "Edit this file to match your allowed ports"
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --whitelist FILE    Path to whitelist file (default: $DEFAULT_WHITELIST)
  --report            Generate detailed report
  --create-sample     Create a sample whitelist file
  --help              Show this help message

Whitelist Format:
  - One port per line
  - Port ranges: start-end (e.g., 8000-8100)
  - Comments: lines starting with #

Examples:
  $(basename "$0")                              # Check against default whitelist
  $(basename "$0") --whitelist /etc/my-ports    # Use custom whitelist
  $(basename "$0") --create-sample              # Create sample whitelist
  $(basename "$0") --report                     # Generate detailed report

EOF
}

# Main execution
main() {
    local whitelist_file="$DEFAULT_WHITELIST"
    local generate_report=false
    local create_sample=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --whitelist) whitelist_file="$2"; shift 2 ;;
            --report) generate_report=true; shift ;;
            --create-sample) create_sample=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    detect_rhel_version

    info "RHEL Version: $RHEL_VERSION"
    echo ""

    if [[ "$create_sample" == "true" ]]; then
        create_sample_whitelist "$whitelist_file"
        exit 0
    fi

    # Create report directory
    if [[ "$generate_report" == "true" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    local report_file="$REPORT_DIR/port-scan-$(date +%Y%m%d-%H%M%S).txt"

    if [[ "$generate_report" == "true" ]]; then
        {
            echo "Open Ports Report"
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Hostname: $(hostname)"
            echo "=================================================="
            echo ""
        } > "$report_file"
    fi

    scan_ports "$whitelist_file" "${report_file:-/dev/null}"

    if [[ "$generate_report" == "true" && -f "$report_file" ]]; then
        info "Report saved: $report_file"
    fi
}

main "$@"
