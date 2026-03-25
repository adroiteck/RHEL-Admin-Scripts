#!/bin/bash

################################################################################
# Script: system-health-check.sh
# Description: Quick system health check with color-coded output
# Usage: ./system-health-check.sh [--verbose] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, standard utilities (uptime, free, df, ps)
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
VERBOSE=0
OUTPUT_FILE=""
WORST_STATUS=0
RHEL_VERSION=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose) VERBOSE=1 ;;
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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges"
        exit 1
    fi
}

# CPU load check
check_cpu_load() {
    local load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}')
    local cores=$(grep -c "^processor" /proc/cpuinfo)
    local load_threshold=$(echo "$cores * 2" | bc)

    if (( $(echo "$load > $load_threshold" | bc -l) )); then
        error "CPU load: $load (critical - threshold: $load_threshold)"
        WORST_STATUS=2
    elif (( $(echo "$load > $cores" | bc -l) )); then
        warn "CPU load: $load (warning - cores: $cores)"
        [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1
    else
        success "CPU load: $load (cores: $cores)"
    fi
}

# Memory check
check_memory() {
    local mem_info=$(free -b | grep "^Mem:")
    local total=$(echo "$mem_info" | awk '{print $2}')
    local used=$(echo "$mem_info" | awk '{print $3}')
    local available=$(echo "$mem_info" | awk '{print $7}')
    local percent=$((used * 100 / total))

    if [[ $percent -ge 90 ]]; then
        error "Memory: ${percent}% used (critical)"
        WORST_STATUS=2
    elif [[ $percent -ge 80 ]]; then
        warn "Memory: ${percent}% used (warning)"
        [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1
    else
        success "Memory: ${percent}% used"
    fi
}

# Disk space check
check_disk() {
    local critical=0 warning=0
    while IFS= read -r line; do
        local percent=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local mount=$(echo "$line" | awk '{print $6}')

        if [[ $percent -ge 95 ]]; then
            error "Disk $mount: ${percent}% used (critical)"
            critical=$((critical + 1))
        elif [[ $percent -ge 85 ]]; then
            warn "Disk $mount: ${percent}% used"
            warning=$((warning + 1))
        fi
    done < <(df -h | grep -v "^Filesystem" | grep -v "^tmpfs")

    if [[ $critical -gt 0 ]]; then
        WORST_STATUS=2
    elif [[ $warning -gt 0 && $WORST_STATUS -lt 1 ]]; then
        WORST_STATUS=1
    fi

    [[ $critical -eq 0 && $warning -eq 0 ]] && success "Disk usage: healthy"
}

# Swap check
check_swap() {
    local swap_info=$(free -b | grep "^Swap:")
    local total=$(echo "$swap_info" | awk '{print $2}')
    local used=$(echo "$swap_info" | awk '{print $3}')

    if [[ $total -eq 0 ]]; then
        warn "Swap: not configured"
        [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1
        return
    fi

    local percent=$((used * 100 / total))
    if [[ $percent -gt 50 ]]; then
        warn "Swap: ${percent}% used"
        [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1
    else
        success "Swap: ${percent}% used"
    fi
}

# Zombie processes check
check_zombies() {
    local zombies=$(ps aux | awk '$8 ~ /Z/ {count++} END {print count+0}')

    if [[ $zombies -gt 10 ]]; then
        error "Zombie processes: $zombies (critical)"
        WORST_STATUS=2
    elif [[ $zombies -gt 0 ]]; then
        warn "Zombie processes: $zombies"
        [[ $WORST_STATUS -lt 1 ]] && WORST_STATUS=1
    else
        success "Zombie processes: 0"
    fi
}

# Failed services check
check_failed_services() {
    if command -v systemctl &> /dev/null; then
        local failed=$(systemctl list-units --failed --no-pager --no-legend 2>/dev/null | wc -l)

        if [[ $failed -gt 0 ]]; then
            error "Failed services: $failed"
            WORST_STATUS=2
            if [[ $VERBOSE -eq 1 ]]; then
                systemctl list-units --failed --no-pager --no-legend | awk '{print "    " $1}'
            fi
        else
            success "Failed services: 0"
        fi
    fi
}

# Uptime check
check_uptime() {
    local uptime=$(cat /proc/uptime | awk '{print int($1/86400)}')
    success "System uptime: $uptime days"
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel

    {
        info "=== System Health Check ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        info "Checking CPU load..."
        check_cpu_load

        info "Checking memory..."
        check_memory

        info "Checking disk space..."
        check_disk

        info "Checking swap..."
        check_swap

        info "Checking zombie processes..."
        check_zombies

        info "Checking services..."
        check_failed_services

        info "Checking uptime..."
        check_uptime

        echo ""
        if [[ $WORST_STATUS -eq 0 ]]; then
            success "Overall status: HEALTHY"
        elif [[ $WORST_STATUS -eq 1 ]]; then
            warn "Overall status: WARNING"
        else
            error "Overall status: CRITICAL"
        fi
    } | tee -a "${OUTPUT_FILE:-.}"

    exit "$WORST_STATUS"
}

main "$@"
