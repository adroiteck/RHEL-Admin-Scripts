#!/bin/bash

################################################################################
# Script: verify-backup.sh
# Description: Verifies backup integrity and validity
# Usage: ./verify-backup.sh --archive backup.tar.gz [--manifest file]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: tar, md5sum, gzip
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
ARCHIVE_FILE=""
MANIFEST_FILE=""
RHEL_VERSION=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive) ARCHIVE_FILE="$2"; shift ;;
            --manifest) MANIFEST_FILE="$2"; shift ;;
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

# Validate archive file
validate_archive() {
    if [[ -z "$ARCHIVE_FILE" ]]; then
        error "Archive file is required (use --archive)"
        exit 1
    fi

    if [[ ! -f "$ARCHIVE_FILE" ]]; then
        error "Archive file not found: $ARCHIVE_FILE"
        exit 1
    fi

    success "Archive file found: $ARCHIVE_FILE"
}

# Check archive format
check_archive_format() {
    info "Checking archive format..."

    local file_type=$(file -b "$ARCHIVE_FILE")

    if [[ "$file_type" =~ "gzip compressed" ]]; then
        success "Format: gzip compressed tar"
        return 0
    elif [[ "$file_type" =~ "POSIX tar" ]]; then
        success "Format: uncompressed tar"
        return 0
    else
        error "Unknown archive format: $file_type"
        return 1
    fi
}

# Test archive integrity
test_archive_integrity() {
    info "Testing archive integrity..."

    if tar -tzf "$ARCHIVE_FILE" > /dev/null 2>&1; then
        success "Archive integrity test: PASSED"
        return 0
    else
        error "Archive integrity test: FAILED"
        return 1
    fi
}

# Verify checksum
verify_checksum() {
    local checksum_file="${ARCHIVE_FILE}.md5"

    if [[ ! -f "$checksum_file" ]]; then
        warn "Checksum file not found: $checksum_file"
        return 1
    fi

    info "Verifying checksum..."

    if md5sum -c "$checksum_file" 2>/dev/null | grep -q "OK"; then
        success "Checksum verification: PASSED"
        return 0
    else
        error "Checksum verification: FAILED"
        return 1
    fi
}

# Get archive file count
get_file_count() {
    local count=$(tar -tzf "$ARCHIVE_FILE" 2>/dev/null | wc -l)
    echo "$count"
}

# Get archive size analysis
analyze_archive_size() {
    info "Analyzing archive size..."

    local archive_size=$(du -sh "$ARCHIVE_FILE" | awk '{print $1}')
    local archive_bytes=$(stat -c '%s' "$ARCHIVE_FILE")

    echo ""
    success "Archive size: $archive_size"
    info "Archive bytes: $archive_bytes"

    # Estimate compression ratio
    if [[ "$ARCHIVE_FILE" =~ \.tar\.gz$ ]]; then
        local uncompressed=$(tar -tzf "$ARCHIVE_FILE" 2>/dev/null | tar -c -T - 2>/dev/null | wc -c)
        if [[ $uncompressed -gt 0 ]]; then
            local ratio=$((archive_bytes * 100 / uncompressed))
            info "Compression ratio: ${ratio}%"
        fi
    fi
}

# List archive contents
list_archive_sample() {
    info "Archive contents (first 20 items):"
    echo ""
    tar -tzf "$ARCHIVE_FILE" 2>/dev/null | head -20 | awk '{print "  " $0}'
}

# Check for critical files
check_critical_files() {
    info "Checking for critical files..."

    local critical_files=("etc/" "root/" "boot/" "var/log/")
    local found_count=0

    for pattern in "${critical_files[@]}"; do
        if tar -tzf "$ARCHIVE_FILE" 2>/dev/null | grep -q "^$pattern"; then
            success "  Found: $pattern"
            found_count=$((found_count + 1))
        else
            warn "  Missing: $pattern"
        fi
    done

    return 0
}

# Check for excluded paths
check_excluded_paths() {
    info "Checking for properly excluded paths..."

    local excluded_paths=("proc/" "sys/" "dev/" "run/" "tmp/")
    local problem_count=0

    for pattern in "${excluded_paths[@]}"; do
        if tar -tzf "$ARCHIVE_FILE" 2>/dev/null | grep -q "^$pattern"; then
            warn "  Found (should be excluded): $pattern"
            problem_count=$((problem_count + 1))
        else
            success "  Correctly excluded: $pattern"
        fi
    done

    if [[ $problem_count -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Verify manifest
verify_manifest() {
    if [[ -z "$MANIFEST_FILE" || ! -f "$MANIFEST_FILE" ]]; then
        warn "Manifest file not provided or not found"
        return 1
    fi

    info "Verifying manifest..."

    local manifest_files=$(grep -c "^/" "$MANIFEST_FILE" 2>/dev/null || echo 0)
    local archive_files=$(get_file_count)

    if [[ "$manifest_files" -gt 0 ]]; then
        success "Manifest contains: $manifest_files entries"
        if [[ "$manifest_files" -eq "$archive_files" ]]; then
            success "Manifest matches archive file count"
            return 0
        else
            warn "File count mismatch - Manifest: $manifest_files, Archive: $archive_files"
            return 1
        fi
    fi
}

# Test extraction
test_extraction() {
    info "Testing extraction (dry run)..."

    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" RETURN

    if tar -tzf "$ARCHIVE_FILE" -C "$temp_dir" --extract 2>/dev/null | head -10 > /dev/null 2>&1; then
        success "Extraction test: PASSED"
        return 0
    else
        error "Extraction test: FAILED"
        return 1
    fi
}

# Generate verification report
generate_report() {
    local report_file="${ARCHIVE_FILE}.verify-report.txt"

    info "Generating verification report..."

    {
        echo "Backup Verification Report"
        echo "=================================="
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "RHEL Version: $RHEL_VERSION"
        echo ""
        echo "Archive Details:"
        echo "  File: $ARCHIVE_FILE"
        echo "  Size: $(du -sh "$ARCHIVE_FILE" | awk '{print $1}')"
        echo "  File count: $(get_file_count)"
        echo ""
        echo "Verification Results:"
        echo "  Archive format: $(file -b "$ARCHIVE_FILE")"
        echo "  Integrity test: $(tar -tzf "$ARCHIVE_FILE" > /dev/null 2>&1 && echo "PASSED" || echo "FAILED")"
        echo "  Checksum: $([ -f "${ARCHIVE_FILE}.md5" ] && md5sum -c "${ARCHIVE_FILE}.md5" 2>/dev/null | grep -q "OK" && echo "PASSED" || echo "FAILED or NOT FOUND")"
        echo ""
        echo "Archive contents sample:"
        tar -tzf "$ARCHIVE_FILE" 2>/dev/null | head -10
    } > "$report_file"

    success "Report generated: $report_file"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel
    validate_archive

    {
        info "=== Backup Verification Tool ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        check_archive_format || exit 1
        echo ""

        test_archive_integrity || exit 1
        echo ""

        analyze_archive_size
        echo ""

        verify_checksum || warn "Checksum verification failed"
        echo ""

        list_archive_sample
        echo ""

        check_critical_files
        echo ""

        check_excluded_paths
        echo ""

        if [[ -n "$MANIFEST_FILE" ]]; then
            verify_manifest
            echo ""
        fi

        generate_report
        echo ""

        success "Backup verification complete"
    }
}

main "$@"
