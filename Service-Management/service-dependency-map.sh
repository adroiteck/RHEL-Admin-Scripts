#!/bin/bash

################################################################################
# Script: service-dependency-map.sh
# Description: Map systemd service dependencies and show dependency tree
# Usage: ./service-dependency-map.sh --service SERVICE_NAME [--format {tree|flat}]
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
}

# Get service dependencies
get_dependencies() {
    local service="$1"
    local dep_type="$2"

    systemctl show "$service" -p "$dep_type" --value 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true
}

# Display dependencies in tree format
display_tree_format() {
    local service="$1"
    local indent="${2:-}"
    local visited="${3:-}"

    # Avoid circular dependencies
    if [[ "$visited" == *"$service"* ]]; then
        echo "${indent}(circular: $service)"
        return
    fi

    visited="$visited $service"

    info "Dependencies for: $service"

    # Get all dependency types
    local wants=$(get_dependencies "$service" "Wants")
    local requires=$(get_dependencies "$service" "Requires")
    local before=$(get_dependencies "$service" "Before")
    local after=$(get_dependencies "$service" "After")

    if [[ -z "$wants" && -z "$requires" && -z "$before" && -z "$after" ]]; then
        echo "${indent}No dependencies found"
        return
    fi

    if [[ -n "$requires" ]]; then
        echo "${indent}├─ Requires:"
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            echo "${indent}│  ├─ $dep"
        done <<< "$requires"
    fi

    if [[ -n "$wants" ]]; then
        echo "${indent}├─ Wants:"
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            echo "${indent}│  ├─ $dep"
        done <<< "$wants"
    fi

    if [[ -n "$after" ]]; then
        echo "${indent}├─ After:"
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            echo "${indent}│  ├─ $dep"
        done <<< "$after"
    fi

    if [[ -n "$before" ]]; then
        echo "${indent}└─ Before:"
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            echo "${indent}   └─ $dep"
        done <<< "$before"
    fi
}

# Display dependencies in flat format
display_flat_format() {
    local service="$1"

    info "Dependencies for: $service"

    echo ""
    echo "Requires:"
    get_dependencies "$service" "Requires" | awk '{print "  - " $0}'

    echo ""
    echo "Wants:"
    get_dependencies "$service" "Wants" | awk '{print "  - " $0}'

    echo ""
    echo "After:"
    get_dependencies "$service" "After" | awk '{print "  - " $0}'

    echo ""
    echo "Before:"
    get_dependencies "$service" "Before" | awk '{print "  - " $0}'
}

# Find services that depend on a given service
find_dependents() {
    local service="$1"

    info "Services that depend on: $service"

    local dependents=()

    while IFS= read -r unit; do
        unit="${unit%.service}"
        if systemctl show "$unit" -p "Requires\nWants" --value 2>/dev/null | grep -q "$service"; then
            dependents+=("$unit")
        fi
    done < <(systemctl list-unit-files --type=service --all --quiet 2>/dev/null | awk '{print $1}')

    if [[ ${#dependents[@]} -eq 0 ]]; then
        warn "No services depend on: $service"
        return
    fi

    success "Found ${#dependents[@]} dependent service(s):"
    for dep in "${dependents[@]}"; do
        echo "  - $dep"
    done
}

# Validate service exists
validate_service() {
    local service="$1"

    if ! systemctl list-unit-files "$service.service" &>/dev/null; then
        error "Service '$service' not found"
        return 1
    fi

    return 0
}

# Display help
usage() {
    cat << EOF
Usage: $(basename "$0") --service SERVICE_NAME [OPTIONS]

Options:
  --service SERVICE_NAME    Target service to analyze (required)
  --format {tree|flat}      Output format (default: tree)
  --dependents              Show services that depend on this service
  --help                    Show this help message

Examples:
  $(basename "$0") --service httpd
  $(basename "$0") --service postgresql --format flat
  $(basename "$0") --service sshd --dependents

EOF
}

# Main execution
main() {
    local service="" format="tree" show_dependents=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service) service="$2"; shift 2 ;;
            --format) format="$2"; shift 2 ;;
            --dependents) show_dependents=true; shift ;;
            --help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "$service" ]]; then
        error "Missing required argument: --service"
        usage
        exit 1
    fi

    detect_rhel_version

    info "RHEL Version: $RHEL_VERSION"

    if ! validate_service "$service"; then
        exit 1
    fi

    echo ""

    case "$format" in
        tree)
            display_tree_format "$service"
            ;;
        flat)
            display_flat_format "$service"
            ;;
        *)
            error "Invalid format: $format"
            exit 1
            ;;
    esac

    echo ""

    if [[ "$show_dependents" == "true" ]]; then
        echo ""
        find_dependents "$service"
    fi
}

main "$@"
