#!/bin/bash

################################################################################
# Script: rollback-update.sh
# Description: Rollback last package update transaction. Uses yum history
#              (RHEL 7) or dnf history (RHEL 8/9). Shows transaction details
#              before confirming rollback action.
# Usage: ./rollback-update.sh [--transaction-id ID] [--list] [--dry-run]
# Author: System Administration Team
# Compatibility: RHEL 7, RHEL 8, RHEL 9
# License: GPL v2
################################################################################

set -euo pipefail

# Color output functions
info() {
    echo -e "\033[36m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[33m[WARN]\033[0m $*" >&2
}

error() {
    echo -e "\033[31m[ERROR]\033[0m $*" >&2
}

success() {
    echo -e "\033[32m[SUCCESS]\033[0m $*"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect RHEL version and package manager
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
    else
        error "Cannot determine RHEL version"
        exit 1
    fi

    if [[ "$RHEL_VERSION" -ge 8 ]]; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi

    info "RHEL $RHEL_VERSION detected, using: $PKG_MANAGER"
}

# List transaction history
list_transaction_history() {
    info "Transaction history:"
    echo "========== RECENT TRANSACTIONS =========="

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf history list 2>/dev/null | head -20
    else
        yum history list 2>/dev/null | head -20
    fi
}

# Get transaction details
get_transaction_details() {
    local txn_id="$1"

    info "Transaction details for ID: $txn_id"
    echo "========== TRANSACTION DETAILS =========="

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf history info "$txn_id" 2>/dev/null || {
            error "Transaction not found: $txn_id"
            return 1
        }
    else
        yum history info "$txn_id" 2>/dev/null || {
            error "Transaction not found: $txn_id"
            return 1
        }
    fi
}

# Get last transaction ID
get_last_transaction_id() {
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf history list 2>/dev/null | grep -v "^ID\|^$" | head -1 | awk '{print $1}'
    else
        yum history list 2>/dev/null | grep -v "^ID\|^$" | head -1 | awk '{print $1}'
    fi
}

# Perform rollback
perform_rollback() {
    local txn_id="$1"
    local dry_run="$2"

    if [[ -z "$txn_id" ]]; then
        error "Transaction ID required"
        return 1
    fi

    info "Rolling back transaction: $txn_id"

    if [[ "$dry_run" == "true" ]]; then
        info "[DRY-RUN] Would rollback transaction: $txn_id"
        return 0
    fi

    # Show confirmation
    warn "This will rollback all changes from transaction $txn_id"
    read -p "Continue with rollback? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        warn "Rollback cancelled"
        return 1
    fi

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf history undo "$txn_id" -y || {
            error "Rollback failed for transaction: $txn_id"
            return 1
        }
    else
        yum history undo "$txn_id" -y || {
            error "Rollback failed for transaction: $txn_id"
            return 1
        }
    fi

    success "Transaction rolled back successfully"
}

# Verify transaction integrity
verify_transaction() {
    local txn_id="$1"

    info "Verifying transaction: $txn_id"

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf history info "$txn_id" 2>/dev/null | grep -q "Return-Code: 0" && {
            success "Transaction is valid"
            return 0
        }
    else
        yum history info "$txn_id" 2>/dev/null | grep -q "Return-Code: 0" && {
            success "Transaction is valid"
            return 0
        }
    fi

    error "Transaction verification failed or transaction has errors"
    return 1
}

# Main function
main() {
    check_root
    detect_environment

    local transaction_id=""
    local list_mode="false"
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --transaction-id)
                transaction_id="$2"
                shift 2
                ;;
            --list)
                list_mode="true"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # List mode
    if [[ "$list_mode" == "true" ]]; then
        list_transaction_history
        return 0
    fi

    # If no transaction ID provided, use the last one
    if [[ -z "$transaction_id" ]]; then
        transaction_id=$(get_last_transaction_id)
        if [[ -z "$transaction_id" ]]; then
            error "No transactions found in history"
            exit 1
        fi
        info "Using last transaction ID: $transaction_id"
    fi

    # Show transaction details
    get_transaction_details "$transaction_id" || exit 1

    # Verify transaction
    verify_transaction "$transaction_id" || exit 1

    # Perform rollback
    perform_rollback "$transaction_id" "$dry_run"
}

main "$@"
