#!/bin/bash

################################################################################
# Script: system-inventory.sh
# Description: Full hardware and software inventory with text/JSON output
# Usage: ./system-inventory.sh [--format text] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: dmidecode (recommended), lscpu, lsblk
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
FORMAT="text"
OUTPUT_FILE=""
RHEL_VERSION=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) FORMAT="$2"; shift ;;
            --output) OUTPUT_FILE="$2"; shift ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Detect RHEL version
detect_rhel() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi
}

# Collect CPU info
collect_cpu_info() {
    local cores=$(grep -c "^processor" /proc/cpuinfo)
    local model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    local mhz=$(grep "^cpu MHz" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)

    echo "cores=$cores"
    echo "model=$model"
    echo "mhz=$mhz"
}

# Collect memory info
collect_memory_info() {
    local total=$(free -b | grep "^Mem:" | awk '{print $2}')
    local total_mb=$((total / 1024 / 1024))

    echo "total_mb=$total_mb"
}

# Collect disk info
collect_disk_info() {
    local count=0
    local size_total=0

    if command -v lsblk &> /dev/null; then
        while IFS= read -r line; do
            local size=$(echo "$line" | awk '{print $4}' | numfmt --from=iec --to=none 2>/dev/null || echo 0)
            size_total=$((size_total + size))
            count=$((count + 1))
        done < <(lsblk -d -n -o NAME,SIZE | grep -E "^sd|^vd|^nvme")
    fi

    echo "count=$count"
    echo "size_bytes=$size_total"
}

# Collect NIC info
collect_nic_info() {
    local count=$(ip link show | grep "^[0-9]:" | wc -l)
    count=$((count - 1))  # Exclude loopback

    echo "count=$count"
}

# Collect OS info
collect_os_info() {
    local kernel=$(uname -r)
    local hostname=$(hostname)
    local uptime_sec=$(cat /proc/uptime | awk '{print int($1)}')

    echo "kernel=$kernel"
    echo "hostname=$hostname"
    echo "uptime_sec=$uptime_sec"
}

# Collect package info
collect_package_info() {
    local count=0
    if command -v rpm &> /dev/null; then
        count=$(rpm -qa | wc -l)
    fi

    echo "count=$count"
}

# Collect service info
collect_service_info() {
    local count=0
    if command -v systemctl &> /dev/null; then
        count=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | wc -l)
    fi

    echo "count=$count"
}

# Output in text format
output_text() {
    info "=== System Inventory Report ==="
    echo ""
    info "RHEL Version: $RHEL_VERSION"
    info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # OS Information
    info "=== Operating System ==="
    local os_info=$(collect_os_info)
    while IFS='=' read -r key value; do
        case "$key" in
            kernel) success "  Kernel: $value" ;;
            hostname) success "  Hostname: $value" ;;
            uptime_sec)
                local days=$((value / 86400))
                success "  Uptime: $days days"
                ;;
        esac
    done <<< "$os_info"
    echo ""

    # CPU Information
    info "=== CPU ==="
    local cpu_info=$(collect_cpu_info)
    while IFS='=' read -r key value; do
        case "$key" in
            cores) success "  Cores: $value" ;;
            model) success "  Model: $value" ;;
            mhz) success "  Speed: ${value%.*} MHz" ;;
        esac
    done <<< "$cpu_info"
    echo ""

    # Memory Information
    info "=== Memory ==="
    local mem_info=$(collect_memory_info)
    while IFS='=' read -r key value; do
        case "$key" in
            total_mb) success "  Total: $(numfmt --to=iec-i --suffix=B $((value*1024*1024)) 2>/dev/null || echo "${value}MB")" ;;
        esac
    done <<< "$mem_info"
    echo ""

    # Disk Information
    info "=== Storage ==="
    local disk_info=$(collect_disk_info)
    while IFS='=' read -r key value; do
        case "$key" in
            count) success "  Disks: $value" ;;
            size_bytes) success "  Total capacity: $(numfmt --to=iec-i --suffix=B $value 2>/dev/null || echo "${value} bytes")" ;;
        esac
    done <<< "$disk_info"
    echo ""

    # Network Information
    info "=== Network ==="
    local nic_info=$(collect_nic_info)
    while IFS='=' read -r key value; do
        case "$key" in
            count) success "  Network interfaces: $value" ;;
        esac
    done <<< "$nic_info"
    echo ""

    # Software Information
    info "=== Software ==="
    local pkg_info=$(collect_package_info)
    while IFS='=' read -r key value; do
        case "$key" in
            count) success "  Installed packages: $value" ;;
        esac
    done <<< "$pkg_info"

    local svc_info=$(collect_service_info)
    while IFS='=' read -r key value; do
        case "$key" in
            count) success "  Running services: $value" ;;
        esac
    done <<< "$svc_info"
    echo ""
}

# Output in JSON format
output_json() {
    local os_info=$(collect_os_info)
    local cpu_info=$(collect_cpu_info)
    local mem_info=$(collect_memory_info)
    local disk_info=$(collect_disk_info)
    local nic_info=$(collect_nic_info)
    local pkg_info=$(collect_package_info)
    local svc_info=$(collect_service_info)

    # Parse info into associative arrays
    declare -A os_arr cpu_arr mem_arr disk_arr nic_arr pkg_arr svc_arr

    while IFS='=' read -r key value; do os_arr[$key]=$value; done <<< "$os_info"
    while IFS='=' read -r key value; do cpu_arr[$key]=$value; done <<< "$cpu_info"
    while IFS='=' read -r key value; do mem_arr[$key]=$value; done <<< "$mem_info"
    while IFS='=' read -r key value; do disk_arr[$key]=$value; done <<< "$disk_info"
    while IFS='=' read -r key value; do nic_arr[$key]=$value; done <<< "$nic_info"
    while IFS='=' read -r key value; do pkg_arr[$key]=$value; done <<< "$pkg_info"
    while IFS='=' read -r key value; do svc_arr[$key]=$value; done <<< "$svc_info"

    # Output JSON
    cat << EOF
{
  "metadata": {
    "rhel_version": "$RHEL_VERSION",
    "timestamp": "$(date -Iseconds)",
    "hostname": "${os_arr[hostname]}"
  },
  "os": {
    "kernel": "${os_arr[kernel]}",
    "uptime_seconds": ${os_arr[uptime_sec]}
  },
  "cpu": {
    "cores": ${cpu_arr[cores]},
    "model": "${cpu_arr[model]}",
    "mhz": ${cpu_arr[mhz]%.*}
  },
  "memory": {
    "total_mb": ${mem_arr[total_mb]}
  },
  "storage": {
    "disk_count": ${disk_arr[count]},
    "total_bytes": ${disk_arr[size_bytes]}
  },
  "network": {
    "interface_count": ${nic_arr[count]}
  },
  "software": {
    "installed_packages": ${pkg_arr[count]},
    "running_services": ${svc_arr[count]}
  }
}
EOF
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel

    case "$FORMAT" in
        text)
            output_text | tee -a "${OUTPUT_FILE:-.}"
            ;;
        json)
            output_json | tee -a "${OUTPUT_FILE:-.}"
            ;;
        *)
            error "Unknown format: $FORMAT"
            exit 1
            ;;
    esac
}

main "$@"
