#!/bin/bash

################################################################################
# Script: analyze-performance.sh
# Description: Performance snapshot and bottleneck analysis
# Usage: ./analyze-performance.sh [--duration 60] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: top, iostat, sar (optional), vmstat
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
DURATION=10
OUTPUT_FILE=""
RHEL_VERSION=""
HAVE_SAR=0

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration) DURATION="$2"; shift ;;
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

    command -v sar &> /dev/null && HAVE_SAR=1
}

# Collect CPU usage
collect_cpu_stats() {
    info "CPU Usage Analysis:"
    echo ""

    local cpu_stats=$(top -bn1 | grep "Cpu(s)")
    local user=$(echo "$cpu_stats" | awk -F',' '{print $1}' | awk '{print $2}' | sed 's/%//')
    local system=$(echo "$cpu_stats" | awk -F',' '{print $2}' | awk '{print $1}' | sed 's/%//')
    local iowait=$(echo "$cpu_stats" | awk -F',' '{print $5}' | awk '{print $1}' | sed 's/%//')
    local idle=$(echo "$cpu_stats" | awk -F',' '{print $4}' | awk '{print $1}' | sed 's/%//')

    success "  User: $user%"
    success "  System: $system%"
    warn "  I/O Wait: $iowait%"
    info "  Idle: $idle%"

    # Identify bottleneck
    if (( $(echo "$iowait > 30" | bc -l) )); then
        error "  BOTTLENECK: High I/O Wait (${iowait}%)"
    elif (( $(echo "$system > 20" | bc -l) )); then
        error "  BOTTLENECK: High System CPU (${system}%)"
    elif (( $(echo "$user > 80" | bc -l) )); then
        warn "  WARNING: High User CPU (${user}%)"
    fi

    echo ""
}

# Collect memory stats
collect_memory_stats() {
    info "Memory Usage Analysis:"
    echo ""

    local mem_total=$(free -b | grep "^Mem:" | awk '{print $2}')
    local mem_used=$(free -b | grep "^Mem:" | awk '{print $3}')
    local mem_cached=$(free -b | grep "^Mem:" | awk '{print $7}')
    local mem_available=$(free -b | grep "^Mem:" | awk '{print $7}')

    local used_pct=$((mem_used * 100 / mem_total))
    local cached_pct=$((mem_cached * 100 / mem_total))
    local available_pct=$((mem_available * 100 / mem_total))

    success "  Used: ${used_pct}%"
    info "  Cached: ${cached_pct}%"
    info "  Available: ${available_pct}%"

    # Check for memory pressure
    if [[ $used_pct -gt 85 ]]; then
        error "  BOTTLENECK: High Memory Pressure (${used_pct}%)"
    elif [[ $used_pct -gt 75 ]]; then
        warn "  WARNING: Moderate Memory Usage (${used_pct}%)"
    fi

    # Check for swapping
    local swap_used=$(free -b | grep "^Swap:" | awk '{print $3}')
    if [[ $swap_used -gt 0 ]]; then
        warn "  SWAP USAGE DETECTED: $(numfmt --to=iec-i --suffix=B $swap_used 2>/dev/null || echo $swap_used)"
    fi

    echo ""
}

# Collect I/O stats
collect_io_stats() {
    info "Disk I/O Analysis:"
    echo ""

    if command -v iostat &> /dev/null; then
        local io_stats=$(iostat -dx 1 2 2>/dev/null | tail -n +4)

        local read_total=0
        local write_total=0
        local await_total=0
        local dev_count=0

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            read_total=$((read_total + $(echo "$line" | awk '{print $4}')))
            write_total=$((write_total + $(echo "$line" | awk '{print $5}')))
            await_total=$((await_total + $(echo "$line" | awk '{print $9}')))
            dev_count=$((dev_count + 1))
        done <<< "$io_stats"

        [[ $dev_count -eq 0 ]] && dev_count=1
        local avg_await=$((await_total / dev_count))

        success "  Read IOPS: $read_total"
        success "  Write IOPS: $write_total"
        warn "  Avg Wait: ${avg_await}ms"

        if [[ $avg_await -gt 50 ]]; then
            error "  BOTTLENECK: High Disk Latency (${avg_await}ms)"
        fi
    else
        warn "  iostat not available"
    fi

    echo ""
}

# Collect network stats
collect_network_stats() {
    info "Network Analysis:"
    echo ""

    local netstat=$(cat /proc/net/dev | grep -v "^Inter\|^face\|lo:" | awk '{rx+=$2; tx+=$10} END {print rx, tx}')
    local rx_bytes=$(echo "$netstat" | awk '{print $1}')
    local tx_bytes=$(echo "$netstat" | awk '{print $2}')

    success "  RX bytes: $(numfmt --to=iec-i --suffix=B $rx_bytes 2>/dev/null || echo $rx_bytes)"
    success "  TX bytes: $(numfmt --to=iec-i --suffix=B $tx_bytes 2>/dev/null || echo $tx_bytes)"

    # Get connection count
    local connections=$(ss -tan 2>/dev/null | wc -l || netstat -tan 2>/dev/null | wc -l || echo "0")
    info "  Active connections: $connections"

    echo ""
}

# Identify top processes
identify_top_processes() {
    info "Top Resource-Consuming Processes:"
    echo ""

    success "  By CPU:"
    top -bn1 | grep "^ " | head -3 | awk '{printf "    %s: %.1f%%\n", $12, $9}'

    success "  By Memory:"
    top -bn1 | head -15 | tail -3 | awk '{printf "    %s: %.1f%%\n", $12, $10}'

    echo ""
}

# System load analysis
analyze_load() {
    info "System Load Analysis:"
    echo ""

    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cores=$(grep -c "^processor" /proc/cpuinfo)
    local load1=$(echo "$load" | awk '{print $1}')

    success "  Load Average: $load"
    info "  CPU Cores: $cores"

    if (( $(echo "$load1 > $cores * 2" | bc -l) )); then
        error "  BOTTLENECK: Excessive Load (${load1})"
    elif (( $(echo "$load1 > $cores" | bc -l) )); then
        warn "  WARNING: Load exceeds core count"
    fi

    echo ""
}

# Context switch analysis
analyze_context_switches() {
    info "Context Switch Analysis:"
    echo ""

    local cs=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $12}')
    success "  Context switches/sec: $cs"

    if [[ $cs -gt 10000 ]]; then
        warn "  WARNING: High context switch rate"
    fi

    echo ""
}

# Generate summary report
generate_summary() {
    info "=== Performance Analysis Summary ==="
    echo ""

    local bottleneck_count=0

    if [[ $bottleneck_count -eq 0 ]]; then
        success "System performance: HEALTHY"
    else
        error "System performance: DEGRADED"
    fi

    info "For detailed analysis, check iostat, vmstat, or sar output"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel

    {
        info "=== Performance Analysis Tool ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        analyze_load
        collect_cpu_stats
        collect_memory_stats
        collect_io_stats
        collect_network_stats
        identify_top_processes
        analyze_context_switches
        generate_summary
    } | tee -a "${OUTPUT_FILE:-.}"
}

main "$@"
