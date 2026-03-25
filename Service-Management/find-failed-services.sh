#!/bin/bash

################################################################################
# Script: find-failed-services.sh
# Description: Find all failed systemd units and optionally attempt restart
# Usage: ./find-failed-services.sh [--auto-restart] [--report]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9 with systemd
# Version: 1.0
################################################################################

set -euo pipefail

# Configuration
readonly REPORT_DIR="/var/log/service-reports"
readonly REPORT_FILE="$REPORT_DIR/failed-services-$(date +%Y%m%d-%H%M%S).txt"

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

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel_version() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    else
        RHEL_VERSION="unknown"
    fi
}

# Initialize reporting
init_report() {
    if [[ ! -d "$REPORT_DIR" ]]; then
        mkdir -p "$REPORT_DIR"
    fi

    cat > "$REPORT_FILE" << EOF
Failed Services Report
Generated: $(date '+%Y-%m-%d %H:%M:%S')
RHEL Version: $RHEL_VERSION
Hostname: $(hostname)
=======================================================

EOF
}

# Find all failed services
find_failed_services() {
    systemctl list-units --failed --no-pager --output=json 2>/dev/null | \
        grep -oP '(?<="unit":")[^"]+' || true
}

# Get service journal logs
get_service_logs() {
    local service="$1"
    local lines="${2:-20}"

    journalctl -u "$service" -n "$lines" --no-pager 2>/dev/null || echo "No journal logs available"
}

# Attempt to restart failed service
restart_failed_service() {
    local service="$1"

    info "Attempting to restart: $service"

    if systemctl restart "$service" 2>/dev/null; then
        success "Service $service restarted successfully"
        return 0
    else
        error "Failed to restart service $service"
        return 1
    fi
}

# Analyze and report failed services
analyze_failures() {
    local auto_restart="${1:-false}"
    local failed_services=()

    info "Scanning for failed services..."

    mapfile -t failed_services < <(find_failed_services)

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        success "No failed services found"
        echo "No failed services found" >> "$REPORT_FILE"
        return 0
    fi

    warn "Found ${#failed_services[@]} failed service(s)"
    echo "Failed Services Found: ${#failed_services[@]}" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    local restarted=0 restart_failed=0

    for service in "${failed_services[@]}"; do
        echo "" >> "$REPORT_FILE"
        echo "Service: $service" >> "$REPORT_FILE"
        echo "---" >> "$REPORT_FILE"

        # Get and display journal logs
        error "Failed service detected: $service"
        echo "" >> "$REPORT_FILE"
        echo "Recent logs:" >> "$REPORT_FILE"
        get_service_logs "$service" 30 | tee -a "$REPORT_FILE"

        # Attempt restart if requested
        if [[ "$auto_restart" == "true" ]]; then
            if restart_failed_service "$service"; then
                ((restarted++))
                echo "Restart Status: SUCCESS" >> "$REPORT_FILE"
            else
                ((restart_failed++))
                echo "Restart Status: FAILED" >> "$REPORT_FILE"
            fi
        fi

        echo "" >> "$REPORT_FILE"
    done

    # Summary
    echo "" >> "$REPORT_FILE"
    echo "=======================================================" >> "$REPORT_FILE"
    echo "Summary:" >> "$REPORT_FILE"
    echo "  Total failed services: ${#failed_services[@]}" >> "$REPORT_FILE"

    if [[ "$auto_restart" == "true" ]]; then
        echo "  Successfully restarted: $restarted" >> "$REPORT_FILE"
        echo "  Restart attempts failed: $restart_failed" >> "$REPORT_FILE"
        success "Auto-restart complete: $restarted succeeded, $restart_failed failed"
    fi
}

# Display report
display_report() {
    if [[ -f "$REPORT_FILE" ]]; then
        info "Report generated: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --auto-restart    Attempt to restart failed services automatically
  --report          Generate and display detailed report
  --help            Show this help message

Examples:
  $(basename "$0")                      # List failed services
  $(basename "$0") --auto-restart       # Auto-restart all failed services
  $(basename "$0") --report             # Generate detailed report

EOF
}

# Main execution
main() {
    local auto_restart=false generate_report=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-restart) auto_restart=true; shift ;;
            --report) generate_report=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    check_root
    detect_rhel_version
    init_report

    info "RHEL Version: $RHEL_VERSION"
    analyze_failures "$auto_restart"

    if [[ "$generate_report" == "true" ]]; then
        display_report
    fi
}

main "$@"
