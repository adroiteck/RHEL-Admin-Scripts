#!/bin/bash

################################################################################
# Script: disk-usage-report.sh
# Description: Generates comprehensive disk usage reports for mounted filesystems,
#              including usage percentages, inode usage, and largest directories.
# Usage: disk-usage-report.sh [--threshold 80] [--top 20] [--output text|json|csv]
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8, Ubuntu 18.04+
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
        RHEL_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    elif [[ -f /etc/redhat-release ]]; then
        RHEL_VERSION=$(grep -oP '\d+(?=\.)' /etc/redhat-release | head -1)
    else
        RHEL_VERSION="unknown"
    fi
    info "Detected RHEL/CentOS version: $RHEL_VERSION"
}

# Parse arguments
THRESHOLD=80
TOP_COUNT=20
OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
    case $1 in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --top) TOP_COUNT="$2"; shift 2 ;;
        --output) OUTPUT_FORMAT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

detect_rhel_version

# Validate output format
if [[ ! "$OUTPUT_FORMAT" =~ ^(text|json|csv)$ ]]; then
    error "Invalid output format: $OUTPUT_FORMAT"
    exit 1
fi

info "Starting disk usage report with threshold: ${THRESHOLD}%"

# Generate filesystem usage report
echo ""
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    echo "================================ FILESYSTEM USAGE ================================"
    printf "%-25s %-15s %-15s %-10s %-15s\n" "Filesystem" "Size" "Used" "Use%" "Mounted On"
    echo "$(printf '=%.0s' {1..85})"

    df -h | tail -n +2 | while read -r line; do
        filesystem=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        use_pct=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')

        if [[ $use_pct -ge $THRESHOLD ]]; then
            status="\033[0;31m[CRITICAL]\033[0m"
        elif [[ $use_pct -ge $((THRESHOLD - 10)) ]]; then
            status="\033[1;33m[WARNING]\033[0m"
        else
            status="\033[0;32m[OK]\033[0m"
        fi

        printf "%-25s %-15s %-15s %-10s %-15s %s\n" "$filesystem" "$size" "$used" "${use_pct}%" "$mount" "$status"
    done

    echo ""
    echo "================================ INODE USAGE ================================"
    printf "%-25s %-15s %-15s %-10s %-15s\n" "Filesystem" "Inodes" "Used" "Use%" "Mounted On"
    echo "$(printf '=%.0s' {1..85})"

    df -i | tail -n +2 | while read -r line; do
        filesystem=$(echo "$line" | awk '{print $1}')
        inodes=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        use_pct=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')

        if [[ $use_pct -ge $THRESHOLD ]]; then
            status="\033[0;31m[CRITICAL]\033[0m"
        elif [[ $use_pct -ge $((THRESHOLD - 10)) ]]; then
            status="\033[1;33m[WARNING]\033[0m"
        else
            status="\033[0;32m[OK]\033[0m"
        fi

        printf "%-25s %-15s %-15s %-10s %-15s %s\n" "$filesystem" "$inodes" "$used" "${use_pct}%" "$mount" "$status"
    done

    echo ""
    echo "============================== TOP $TOP_COUNT LARGEST DIRECTORIES =============================="
    du -ah / 2>/dev/null | sort -rh | head -n "$TOP_COUNT" | while read -r size path; do
        printf "%-20s %s\n" "$size" "$path"
    done

elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "{"
    echo '  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
    echo '  "filesystems": ['

    df -h | tail -n +2 | while read -r line; do
        filesystem=$(echo "$line" | awk '{print $1}')
        use_pct=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')

        echo '    {'
        echo '      "filesystem": "'$filesystem'",'
        echo '      "mount": "'$mount'",'
        echo '      "usage_percent": '$use_pct','
        echo '      "threshold_exceeded": '$([ $use_pct -ge $THRESHOLD ] && echo 'true' || echo 'false')
        echo '    },'
    done | sed '$ s/,$//'
    echo '  ]'
    echo "}"

elif [[ "$OUTPUT_FORMAT" == "csv" ]]; then
    echo "Filesystem,Mount Point,Size,Used,Use%,Status"
    df -h | tail -n +2 | while read -r line; do
        filesystem=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        use_pct=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')

        if [[ $use_pct -ge $THRESHOLD ]]; then
            status="CRITICAL"
        elif [[ $use_pct -ge $((THRESHOLD - 10)) ]]; then
            status="WARNING"
        else
            status="OK"
        fi

        echo "$filesystem,$mount,$size,$used,$use_pct%,$status"
    done
fi

success "Disk usage report completed"
