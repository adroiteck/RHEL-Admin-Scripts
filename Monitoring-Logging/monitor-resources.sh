#!/bin/bash

################################################################################
# Script: monitor-resources.sh
# Description: Real-time resource monitoring with configurable intervals
# Usage: ./monitor-resources.sh [--interval 5] [--count 10] [--log FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: iostat (from sysstat), sar (optional), standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
INTERVAL=5
COUNT=0
LOG_FILE=""
RHEL_VERSION=""
HAVE_IOSTAT=0

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval) INTERVAL="$2"; shift ;;
            --count) COUNT="$2"; shift ;;
            --log) LOG_FILE="$2"; shift ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Detect RHEL version and available tools
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi

    command -v iostat &> /dev/null && HAVE_IOSTAT=1
}

# Get CPU stats per core
get_cpu_stats() {
    local cpu_stats=$(top -bn1 | grep "Cpu")
    local user=$(echo "$cpu_stats" | awk -F',' '{print $1}' | awk '{print $2}' | sed 's/%//')
    local system=$(echo "$cpu_stats" | awk -F',' '{print $2}' | awk '{print $1}' | sed 's/%//')
    local idle=$(echo "$cpu_stats" | awk -F',' '{print $4}' | awk '{print $1}' | sed 's/%//')
    local iowait=$(echo "$cpu_stats" | awk -F',' '{print $5}' | awk '{print $1}' | sed 's/%//')

    printf "%-35s | User: %5.1f%% | System: %5.1f%% | I/O-Wait: %5.1f%% | Idle: %5.1f%%\n" \
        "CPU Stats" "$user" "$system" "$iowait" "$idle"
}

# Get memory breakdown
get_memory_stats() {
    local mem_total=$(free -b | grep "^Mem:" | awk '{print $2}')
    local mem_used=$(free -b | grep "^Mem:" | awk '{print $3}')
    local mem_cached=$(free -b | grep "^Mem:" | awk '{print $7}')
    local mem_buffers=$(free -b | grep "^Mem:" | awk '{print $6}')
    local mem_available=$(free -b | grep "^Mem:" | awk '{print $7}')

    local used_pct=$((mem_used * 100 / mem_total))
    local cached_pct=$((mem_cached * 100 / mem_total))
    local buffers_pct=$((mem_buffers * 100 / mem_total))
    local available_pct=$((mem_available * 100 / mem_total))

    printf "%-35s | Used: %5d%% | Cached: %5d%% | Available: %5d%%\n" \
        "Memory Stats" "$used_pct" "$cached_pct" "$available_pct"
}

# Get disk I/O stats
get_disk_io_stats() {
    if [[ $HAVE_IOSTAT -eq 0 ]]; then
        printf "%-35s | iostat not available\n" "Disk I/O Stats"
        return
    fi

    local io_stats=$(iostat -dx 1 2 2>/dev/null | tail -n +4 | head -n 5)
    local avg_wait=$(echo "$io_stats" | awk '{sum+=$9; count++} END {if (count>0) printf "%.2f", sum/count; else print "0"}')
    local read_ops=$(echo "$io_stats" | awk '{sum+=$4} END {print sum}')
    local write_ops=$(echo "$io_stats" | awk '{sum+=$5} END {print sum}')

    printf "%-35s | Read/s: %6d | Write/s: %6d | Avg Wait: %6sms\n" \
        "Disk I/O Stats" "$read_ops" "$write_ops" "$avg_wait"
}

# Get network throughput
get_network_stats() {
    local netstat=$(cat /proc/net/dev | grep -v "^Inter\|^face\|lo:" | awk '{rx+=$2; tx+=$10} END {print rx, tx}')
    local rx_bytes=$(echo "$netstat" | awk '{print $1}')
    local tx_bytes=$(echo "$netstat" | awk '{print $2}')

    printf "%-35s | RX: %8d bytes | TX: %8d bytes\n" \
        "Network Stats" "$rx_bytes" "$tx_bytes"
}

# Get load average
get_load_average() {
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cores=$(grep -c "^processor" /proc/cpuinfo)

    printf "%-35s | Cores: %d | %s\n" \
        "Load Average" "$cores" "$load"
}

# Main monitoring loop
monitor_loop() {
    local iteration=0

    while true; do
        iteration=$((iteration + 1))

        {
            echo ""
            echo "=== Resource Monitoring - Iteration $iteration - $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo ""

            get_load_average
            get_cpu_stats
            get_memory_stats
            get_disk_io_stats
            get_network_stats

            echo ""
        } | tee -a "${LOG_FILE:-.}"

        # Check if we've reached the count limit
        if [[ $COUNT -gt 0 && $iteration -ge $COUNT ]]; then
            info "Monitoring complete (reached count limit of $COUNT)"
            break
        fi

        # Sleep before next iteration
        if [[ $COUNT -eq 0 ]]; then
            info "Next update in ${INTERVAL}s (press Ctrl+C to stop)..."
            sleep "$INTERVAL"
        else
            if [[ $iteration -lt $COUNT ]]; then
                sleep "$INTERVAL"
            fi
        fi
    done
}

# Main execution
main() {
    parse_args "$@"
    detect_environment

    {
        info "=== Resource Monitor ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Interval: ${INTERVAL}s"
        if [[ $COUNT -gt 0 ]]; then
            info "Count: $COUNT iterations"
        else
            info "Count: unlimited (continuous)"
        fi
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    } | tee -a "${LOG_FILE:-.}"

    monitor_loop
}

main "$@"
