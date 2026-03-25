#!/bin/bash

################################################################################
# Script: lvm-report.sh
# Description: Provides comprehensive LVM status report including physical volumes,
#              volume groups, logical volumes, snapshots, and thin pool usage.
# Usage: lvm-report.sh [--detailed] [--format text|json]
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8 with lvm2 installed
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

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Check if LVM is installed
check_lvm_installed() {
    if ! command -v lvs &> /dev/null; then
        error "LVM tools not installed. Install with: yum install lvm2"
        exit 1
    fi
}

# Parse arguments
DETAILED=0
OUTPUT_FORMAT="text"

while [[ $# -gt 0 ]]; do
    case $1 in
        --detailed) DETAILED=1; shift ;;
        --format) OUTPUT_FORMAT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

check_root
detect_rhel_version
check_lvm_installed

info "Generating LVM report (RHEL $RHEL_VERSION)"

if [[ "$OUTPUT_FORMAT" == "text" ]]; then
    echo ""
    echo "================================ PHYSICAL VOLUMES ================================"
    pvdisplay -c 2>/dev/null | while IFS=: read -r pv vg fmt attr ppv crda ppva pe psize allocpe freepe pvuuid; do
        if [[ -n "$pv" && "$pv" != "PV" ]]; then
            free_pct=$((freepe * 100 / pe))
            if [[ $free_pct -lt 10 ]]; then
                status="\033[0;31m[CRITICAL]\033[0m"
            elif [[ $free_pct -lt 20 ]]; then
                status="\033[1;33m[WARNING]\033[0m"
            else
                status="\033[0;32m[OK]\033[0m"
            fi
            printf "%-20s %-15s %8d PE %8d Free (%-3d%%) %s\n" "$pv" "$vg" "$pe" "$freepe" "$free_pct" "$status"
        fi
    done

    echo ""
    echo "================================ VOLUME GROUPS ================================"
    vgdisplay -c 2>/dev/null | while IFS=: read -r vg line lv pv attr vsize valloced vfree rest; do
        if [[ -n "$vg" && "$vg" != "VG" ]]; then
            vfree_pct=$((vfree * 100 / (vfree + valloced)))
            if [[ $vfree_pct -lt 10 ]]; then
                status="\033[0;31m[CRITICAL]\033[0m"
            elif [[ $vfree_pct -lt 20 ]]; then
                status="\033[1;33m[WARNING]\033[0m"
            else
                status="\033[0;32m[OK]\033[0m"
            fi
            printf "%-25s %3d LVs %3d PVs %15s total %15s free (%-3d%%) %s\n" \
                "$vg" "$lv" "$pv" "$vsize" "$vfree" "$vfree_pct" "$status"
        fi
    done

    echo ""
    echo "================================ LOGICAL VOLUMES ================================"
    printf "%-30s %-20s %-15s %-12s %-10s\n" "LV Name" "VG Name" "Size" "Type" "Status"
    echo "$(printf '=%.0s' {1..90})"

    lvdisplay -c 2>/dev/null | while IFS=: read -r lv vg attr lsize ele attr2 rest; do
        if [[ -n "$lv" && "$lv" != "LV" && "$vg" != "VG" ]]; then
            printf "%-30s %-20s %-15s %-12s %-10s\n" "$lv" "$vg" "$lsize" "standard" "active"
        fi
    done

    # Check for snapshots
    snapshots=$(lvs -o name,snap_percent 2>/dev/null | grep -v "^ " | wc -l)
    if [[ $snapshots -gt 1 ]]; then
        echo ""
        echo "================================ SNAPSHOTS ================================"
        lvs -o name,vg_name,size,snap_percent 2>/dev/null | grep -E "snap" | while read -r name vg size snap_pct; do
            if [[ -n "$name" && "$name" != "LV" ]]; then
                snap_val=$(echo "$snap_pct" | sed 's/\.//g' | sed 's/%//')
                if [[ $snap_val -gt 80 ]]; then
                    status="\033[0;31m[CRITICAL]\033[0m"
                elif [[ $snap_val -gt 50 ]]; then
                    status="\033[1;33m[WARNING]\033[0m"
                else
                    status="\033[0;32m[OK]\033[0m"
                fi
                printf "%-30s %-20s %-15s %-15s %s\n" "$name" "$vg" "$size" "$snap_pct" "$status"
            fi
        done
    fi

    # Check for thin pools
    thin_pools=$(lvs -o pool_lv 2>/dev/null | grep -v "^ " | grep -v "^POOL" | wc -l)
    if [[ $thin_pools -gt 0 ]]; then
        echo ""
        echo "================================ THIN POOLS ================================"
        lvs -o name,vg_name,size,data_percent 2>/dev/null | grep "POOL\|pool" | while read -r name vg size data_pct; do
            if [[ -n "$name" && "$name" != "LV" ]]; then
                data_val=$(echo "$data_pct" | sed 's/\.//g' | sed 's/%//')
                if [[ $data_val -gt 80 ]]; then
                    status="\033[0;31m[CRITICAL]\033[0m"
                elif [[ $data_val -gt 50 ]]; then
                    status="\033[1;33m[WARNING]\033[0m"
                else
                    status="\033[0;32m[OK]\033[0m"
                fi
                printf "%-30s %-20s %-15s %-15s %s\n" "$name" "$vg" "$size" "$data_pct" "$status"
            fi
        done
    fi

    if [[ $DETAILED -eq 1 ]]; then
        echo ""
        echo "================================ DETAILED LV INFORMATION ================================"
        lvdisplay 2>/dev/null
    fi

elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "{"
    echo '  "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
    echo '  "physical_volumes": ['
    pvs -o pv_name,vg_name,pv_size,pv_free --noheadings 2>/dev/null | \
        while read -r pv vg size free; do
            [[ -z "$pv" ]] && continue
            echo '    {"pv": "'$pv'", "vg": "'$vg'", "size": "'$size'", "free": "'$free'"},'
        done | sed '$ s/,$//'
    echo '  ],'
    echo '  "volume_groups": ['
    vgs -o vg_name,pv_count,lv_count,vg_size,vg_free --noheadings 2>/dev/null | \
        while read -r vg pv lv size free; do
            [[ -z "$vg" ]] && continue
            echo '    {"vg": "'$vg'", "pv_count": '$pv', "lv_count": '$lv', "size": "'$size'", "free": "'$free'"},'
        done | sed '$ s/,$//'
    echo '  ]'
    echo "}"
fi

success "LVM report completed"
