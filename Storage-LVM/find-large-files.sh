#!/bin/bash

################################################################################
# Script: find-large-files.sh
# Description: Finds and lists the largest files on disk with size, owner,
#              modification date, and optional CSV output.
# Usage: find-large-files.sh --path / --count 50 --min-size 100M --exclude /proc
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8
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
    else
        RHEL_VERSION="unknown"
    fi
}

# Convert size string to bytes for comparison
size_to_bytes() {
    local size=$1
    local num=$(echo "$size" | sed 's/[^0-9]//g')
    local unit=$(echo "$size" | sed 's/[0-9]//g')

    case "$unit" in
        K|k) echo $((num * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        T|t) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}

# Parse arguments
SEARCH_PATH="/"
FILE_COUNT=50
MIN_SIZE="0"
EXCLUDE_PATHS=()
OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
    case $1 in
        --path) SEARCH_PATH="$2"; shift 2 ;;
        --count) FILE_COUNT="$2"; shift 2 ;;
        --min-size) MIN_SIZE="$2"; shift 2 ;;
        --exclude) EXCLUDE_PATHS+=("$2"); shift 2 ;;
        --output) OUTPUT_FORMAT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

detect_rhel_version

if [[ ! -d "$SEARCH_PATH" ]]; then
    error "Search path does not exist: $SEARCH_PATH"
    exit 1
fi

info "Searching for large files in: $SEARCH_PATH"
info "Minimum size: $MIN_SIZE, Limit: $FILE_COUNT files"

# Build find command with exclusions
FIND_CMD="find $SEARCH_PATH -type f"

for exclude in "${EXCLUDE_PATHS[@]}"; do
    FIND_CMD="$FIND_CMD ! -path '$exclude*'"
done

FIND_CMD="$FIND_CMD -printf '%s %p %u %T@\n' 2>/dev/null"

# Execute find and process results
MIN_BYTES=$(size_to_bytes "$MIN_SIZE")

eval "$FIND_CMD" | \
    awk -v min_bytes="$MIN_BYTES" '
    $1 >= min_bytes { print $0 }
    ' | \
    sort -rn | \
    head -n "$FILE_COUNT" > /tmp/large_files_$$

# Process output based on format
if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    echo ""
    echo "================================ TOP $FILE_COUNT LARGEST FILES ================================"
    printf "%-15s %-35s %-15s %s\n" "Size" "Owner" "Modified" "Path"
    echo "$(printf '=%.0s' {1..100})"

    while read -r size path owner timestamp; do
        if [[ -z "$path" ]]; then
            continue
        fi

        # Convert size to human-readable format
        if [[ $size -gt $((1024 * 1024 * 1024)) ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fG\", $size/(1024*1024*1024)}")
        elif [[ $size -gt $((1024 * 1024)) ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fM\", $size/(1024*1024)}")
        elif [[ $size -gt 1024 ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fK\", $size/1024}")
        else
            size_fmt="${size}B"
        fi

        # Convert timestamp
        mtime=$(date -d @"${timestamp%.*}" +%Y-%m-%d 2>/dev/null || echo "unknown")

        printf "%-15s %-35s %-15s %s\n" "$size_fmt" "$owner" "$mtime" "$path"
    done < /tmp/large_files_$$

    echo ""
    success "Found $(wc -l < /tmp/large_files_$$) large files"

elif [[ "$OUTPUT_FORMAT" == "csv" ]]; then
    echo "Size_Bytes,Size_Human,Owner,Modified_Date,Path"

    while read -r size path owner timestamp; do
        if [[ -z "$path" ]]; then
            continue
        fi

        # Convert size to human-readable format
        if [[ $size -gt $((1024 * 1024 * 1024)) ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fG\", $size/(1024*1024*1024)}")
        elif [[ $size -gt $((1024 * 1024)) ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fM\", $size/(1024*1024)}")
        elif [[ $size -gt 1024 ]]; then
            size_fmt=$(awk "BEGIN {printf \"%.2fK\", $size/1024}")
        else
            size_fmt="${size}B"
        fi

        mtime=$(date -d @"${timestamp%.*}" +%Y-%m-%d 2>/dev/null || echo "unknown")
        # Escape commas and quotes in paths
        path_safe=$(echo "$path" | sed 's/"/\\"/g')

        echo "$size,$size_fmt,$owner,$mtime,\"$path_safe\""
    done < /tmp/large_files_$$

    success "CSV export completed ($(wc -l < /tmp/large_files_$$) files)"
fi

rm -f /tmp/large_files_$$
