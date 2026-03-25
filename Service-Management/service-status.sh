#!/bin/bash

################################################################################
# Script: service-status.sh
# Description: Display status of systemd services grouped by state
# Usage: ./service-status.sh [SERVICE_NAME]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with systemd
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
        RHEL_VERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    else
        RHEL_VERSION="unknown"
    fi
    info "Detected RHEL Version: $RHEL_VERSION"
}

# Check systemd availability
check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        error "systemctl not found. This script requires systemd."
        exit 1
    fi
}

# Display service status grouped by state
display_service_status() {
    local service_pattern="$1"

    info "Gathering service information..."

    local running=() stopped=() failed=() disabled=()

    # Get all services matching pattern
    while IFS= read -r service; do
        local unit_name="${service%%.*}"
        local active_state=$(systemctl is-active "$unit_name" 2>/dev/null || echo "unknown")
        local enabled_state=$(systemctl is-enabled "$unit_name" 2>/dev/null || echo "unknown")

        case "$active_state" in
            running)
                running+=("$unit_name|$enabled_state")
                ;;
            stopped)
                stopped+=("$unit_name|$enabled_state")
                ;;
            failed)
                failed+=("$unit_name|$enabled_state")
                ;;
            *)
                if [[ "$enabled_state" == "disabled" ]]; then
                    disabled+=("$unit_name|$enabled_state")
                fi
                ;;
        esac
    done < <(systemctl list-unit-files --type=service --all --quiet 2>/dev/null | awk '{print $1}' | grep -E "$service_pattern" || true)

    # Display running services
    if [[ ${#running[@]} -gt 0 ]]; then
        success "=== RUNNING SERVICES (${#running[@]}) ==="
        for entry in "${running[@]}"; do
            IFS='|' read -r service enabled_state <<< "$entry"
            printf "  %-50s [%s] %s\n" "$service" "RUNNING" "($enabled_state)"
        done
        echo ""
    fi

    # Display stopped services
    if [[ ${#stopped[@]} -gt 0 ]]; then
        warn "=== STOPPED SERVICES (${#stopped[@]}) ==="
        for entry in "${stopped[@]}"; do
            IFS='|' read -r service enabled_state <<< "$entry"
            printf "  %-50s [%s] %s\n" "$service" "STOPPED" "($enabled_state)"
        done
        echo ""
    fi

    # Display failed services (highlighted)
    if [[ ${#failed[@]} -gt 0 ]]; then
        error "=== FAILED SERVICES (${#failed[@]}) - ACTION REQUIRED ==="
        for entry in "${failed[@]}"; do
            IFS='|' read -r service enabled_state <<< "$entry"
            printf "  %-50s [%s] %s\n" "$service" "FAILED" "($enabled_state)"
        done
        echo ""
    fi

    # Display disabled services
    if [[ ${#disabled[@]} -gt 0 ]]; then
        info "=== DISABLED SERVICES (${#disabled[@]}) ==="
        for entry in "${disabled[@]}"; do
            IFS='|' read -r service enabled_state <<< "$entry"
            printf "  %-50s [%s]\n" "$service" "DISABLED"
        done
        echo ""
    fi

    # Summary
    local total=$((${#running[@]} + ${#stopped[@]} + ${#failed[@]} + ${#disabled[@]}))
    info "Total services found: $total"
}

# Main execution
main() {
    detect_rhel_version
    check_systemd

    local service_pattern="${1:-.}"

    if [[ "$service_pattern" != "." ]]; then
        info "Filtering services matching: $service_pattern"
    else
        info "Showing all services"
    fi

    display_service_status "$service_pattern"
}

main "$@"
