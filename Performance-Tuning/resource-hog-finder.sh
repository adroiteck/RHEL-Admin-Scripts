#!/bin/bash

################################################################################
# Script: resource-hog-finder.sh
# Description: Identifies resource-heavy processes and suggests actions
# Usage: ./resource-hog-finder.sh --type cpu [--top 5] [--output FILE]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: ps, top, lsof (for file descriptor counting)
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
TYPE="all"
TOP_COUNT=5
OUTPUT_FILE=""
RHEL_VERSION=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) TYPE="$2"; shift ;;
            --top) TOP_COUNT="$2"; shift ;;
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

# Find top CPU consumers
find_cpu_hogs() {
    info "Top $TOP_COUNT CPU-consuming processes:"
    echo ""

    top -bn1 | head -n 7 | tail -n +7 > /dev/null
    top -bn1 | grep "^ " | head -n "$TOP_COUNT" | while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local user=$(echo "$line" | awk '{print $2}')
        local cpu=$(echo "$line" | awk '{print $9}')
        local mem=$(echo "$line" | awk '{print $10}')
        local cmd=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=$9=$10=""; print $0}' | xargs)

        printf "  PID: %6d | User: %-10s | CPU: %6s%% | Mem: %6s%% | Cmd: %s\n" \
            "$pid" "$user" "$cpu" "$mem" "${cmd:0:40}"

        # Suggest action if CPU > 50%
        if (( $(echo "$cpu > 50" | bc -l) )); then
            warn "    WARNING: High CPU usage - Consider: kill -TERM $pid"
        fi
    done

    echo ""
}

# Find top memory consumers
find_memory_hogs() {
    info "Top $TOP_COUNT memory-consuming processes:"
    echo ""

    ps aux --sort=-%mem | head -n $((TOP_COUNT + 1)) | tail -n "$TOP_COUNT" | while read -r line; do
        local user=$(echo "$line" | awk '{print $1}')
        local pid=$(echo "$line" | awk '{print $2}')
        local mem=$(echo "$line" | awk '{print $4}')
        local rss=$(echo "$line" | awk '{print $6}')
        local cmd=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=$9=$10=""; print $0}' | xargs)

        printf "  PID: %6d | User: %-10s | Mem: %6s%% | RSS: %8s | Cmd: %s\n" \
            "$pid" "$user" "$mem" "$rss" "${cmd:0:40}"

        # Suggest action if memory > 10%
        if (( $(echo "$mem > 10" | bc -l) )); then
            warn "    WARNING: High memory usage - Consider: kill -TERM $pid"
        fi
    done

    echo ""
}

# Find high I/O processes
find_io_hogs() {
    info "High I/O processes:"
    echo ""

    if [[ ! -f /proc/sys/fs/aio-max-nr ]]; then
        warn "I/O statistics not available (kernel < 3.16)"
        echo ""
        return
    fi

    # Use iotop if available
    if command -v iotop &> /dev/null; then
        iotop -b -n 1 2>/dev/null | tail -n "$TOP_COUNT" | while read -r line; do
            [[ -z "$line" ]] && continue
            echo "  $line"
        done
    else
        warn "iotop not installed, showing alternative:"
        ps aux --sort=-%cpu | head -n $((TOP_COUNT + 1)) | tail -n "$TOP_COUNT" | while read -r line; do
            local pid=$(echo "$line" | awk '{print $2}')
            local cmd=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=$9=$10=""; print $0}' | xargs)
            echo "  PID: $pid | Cmd: ${cmd:0:40}"
        done
    fi

    echo ""
}

# Find processes with most open files
find_file_descriptor_hogs() {
    info "Processes with most open file descriptors:"
    echo ""

    if ! command -v lsof &> /dev/null; then
        warn "lsof not installed, skipping file descriptor analysis"
        echo ""
        return
    fi

    # Count FDs per process
    {
        for dir in /proc/[0-9]*/fd; do
            [[ -d "$dir" ]] || continue
            local pid=$(basename $(dirname "$dir"))
            local cmd=$(cat /proc/$pid/comm 2>/dev/null || echo "unknown")
            local fd_count=$(ls -1 "$dir" 2>/dev/null | wc -l)
            echo "$fd_count $pid $cmd"
        done
    } | sort -rn | head -n "$TOP_COUNT" | while read -r count pid cmd; do
        printf "  PID: %6d | FDs: %6d | Cmd: %s\n" "$pid" "$count" "$cmd"

        if [[ $count -gt 1000 ]]; then
            warn "    WARNING: Excessive file descriptors - May indicate leak"
        fi
    done

    echo ""
}

# Generate process kill recommendations
generate_kill_list() {
    info "=== Process Kill Recommendations ==="
    echo ""

    local kill_list_file="${OUTPUT_FILE%.txt}_kill_recommendations.sh"

    {
        echo "#!/bin/bash"
        echo "# Auto-generated process kill recommendations"
        echo "# Review before executing!"
        echo ""

        case "$TYPE" in
            cpu)
                echo "# Kill top CPU consumers:"
                top -bn1 | grep "^ " | head -n 3 | while read -r line; do
                    local pid=$(echo "$line" | awk '{print $1}')
                    local cpu=$(echo "$line" | awk '{print $9}')
                    echo "# CPU: ${cpu}% - kill -TERM $pid"
                done
                ;;
            memory)
                echo "# Kill top memory consumers:"
                ps aux --sort=-%mem | head -n 4 | tail -n 3 | while read -r line; do
                    local pid=$(echo "$line" | awk '{print $2}')
                    local mem=$(echo "$line" | awk '{print $4}')
                    echo "# Mem: ${mem}% - kill -TERM $pid"
                done
                ;;
            *)
                echo "# Combined recommendations available per analysis"
                ;;
        esac

        echo ""
        echo "# WARNING: Review PIDs before uncommenting kill commands"
        echo "# Using -TERM allows graceful shutdown; -KILL forces immediate termination"
    } > "$kill_list_file"

    success "Kill recommendations saved to: $kill_list_file"
}

# Generate nice recommendations
generate_nice_recommendations() {
    info "=== Process Nice Recommendations ==="
    echo ""

    local nice_file="${OUTPUT_FILE%.txt}_nice_recommendations.sh"

    {
        echo "#!/bin/bash"
        echo "# Auto-generated process nice recommendations"
        echo "# Reduce priority of lower-priority processes"
        echo ""

        case "$TYPE" in
            cpu)
                echo "# Lower priority of CPU-intensive processes:"
                top -bn1 | grep "^ " | head -n 5 | tail -n 3 | while read -r line; do
                    local pid=$(echo "$line" | awk '{print $1}')
                    echo "nice -n 10 -p $pid  # Increase niceness"
                done
                ;;
        esac

        echo ""
        echo "# Note: Higher nice values = lower priority"
    } > "$nice_file"

    success "Nice recommendations saved to: $nice_file"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel

    {
        info "=== Resource Hog Finder ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Analysis type: $TYPE"
        info "Top count: $TOP_COUNT"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        case "$TYPE" in
            cpu)
                find_cpu_hogs
                ;;
            memory)
                find_memory_hogs
                ;;
            io)
                find_io_hogs
                ;;
            files)
                find_file_descriptor_hogs
                ;;
            all)
                find_cpu_hogs
                find_memory_hogs
                find_io_hogs
                find_file_descriptor_hogs
                ;;
            *)
                error "Unknown type: $TYPE"
                exit 1
                ;;
        esac

        generate_kill_list
        echo ""
        generate_nice_recommendations
    } | tee -a "${OUTPUT_FILE:-.}"
}

main "$@"
