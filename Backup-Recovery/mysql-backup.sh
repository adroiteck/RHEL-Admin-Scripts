#!/bin/bash

################################################################################
# Script: mysql-backup.sh
# Description: MySQL/MariaDB backup with compression and rotation
# Usage: ./mysql-backup.sh --dest /backup [--databases all] [--retention 7]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root, mysqldump, gzip
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
BACKUP_DEST=""
DATABASES="all"
RETENTION_DAYS=7
DB_USER="root"
PASSWORD_FILE=""
RHEL_VERSION=""
BACKUP_DATE=$(date '+%Y%m%d-%H%M%S')

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest) BACKUP_DEST="$2"; shift ;;
            --databases) DATABASES="$2"; shift ;;
            --retention) RETENTION_DAYS="$2"; shift ;;
            --user) DB_USER="$2"; shift ;;
            --password-file) PASSWORD_FILE="$2"; shift ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges"
        exit 1
    fi
}

# Detect RHEL version
detect_rhel() {
    if [[ -f /etc/os-release ]]; then
        RHEL_VERSION=$(grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release)
    else
        RHEL_VERSION="unknown"
    fi
}

# Check MySQL/MariaDB availability
check_mysql() {
    if ! command -v mysqldump &> /dev/null; then
        error "mysqldump is not installed"
        exit 1
    fi

    if ! command -v mysql &> /dev/null; then
        error "mysql client is not installed"
        exit 1
    fi

    success "MySQL/MariaDB tools found"
}

# Validate backup destination
validate_destination() {
    if [[ -z "$BACKUP_DEST" ]]; then
        error "Backup destination is required (use --dest)"
        exit 1
    fi

    if [[ ! -d "$BACKUP_DEST" ]]; then
        mkdir -p "$BACKUP_DEST"
    fi

    if [[ ! -w "$BACKUP_DEST" ]]; then
        error "Destination is not writable: $BACKUP_DEST"
        exit 1
    fi

    success "Backup destination valid: $BACKUP_DEST"
}

# Build mysqldump command
build_mysql_cmd() {
    local mysql_cmd="mysqldump -u $DB_USER --single-transaction --routines --triggers"

    if [[ -n "$PASSWORD_FILE" && -f "$PASSWORD_FILE" ]]; then
        mysql_cmd="$mysql_cmd --defaults-extra-file=$PASSWORD_FILE"
    fi

    echo "$mysql_cmd"
}

# Get list of databases
get_database_list() {
    if [[ "$DATABASES" == "all" ]]; then
        local mysql_cmd=$(build_mysql_cmd)
        $mysql_cmd --execute "SHOW DATABASES;" | grep -v "^Database$" | grep -v "^information_schema$" | grep -v "^performance_schema$" | grep -v "^mysql$"
    else
        echo "$DATABASES" | tr ',' '\n'
    fi
}

# Backup single database
backup_database() {
    local db_name="$1"
    local backup_file="${BACKUP_DEST}/mysql-${db_name}-${BACKUP_DATE}.sql.gz"

    info "Backing up database: $db_name"

    local mysql_cmd=$(build_mysql_cmd)

    if $mysql_cmd "$db_name" 2>/dev/null | gzip > "$backup_file"; then
        local size=$(du -sh "$backup_file" | awk '{print $1}')
        success "  Backup created: $size"
        return 0
    else
        error "  Backup failed for database: $db_name"
        return 1
    fi
}

# Backup all databases
backup_all_databases() {
    local db_list=$(get_database_list)
    local success_count=0
    local fail_count=0

    info "Starting database backup..."
    echo ""

    while IFS= read -r database; do
        if backup_database "$database"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done <<< "$db_list"

    echo ""
    success "Successful backups: $success_count"
    if [[ $fail_count -gt 0 ]]; then
        error "Failed backups: $fail_count"
    fi
}

# Test database connectivity
test_connection() {
    info "Testing database connection..."

    local mysql_cmd=$(build_mysql_cmd)

    if $mysql_cmd --execute "SELECT 1;" > /dev/null 2>&1; then
        success "Database connection successful"
        return 0
    else
        error "Failed to connect to database"
        error "Check MySQL/MariaDB service and credentials"
        return 1
    fi
}

# Verify backup integrity
verify_backups() {
    info "Verifying backup integrity..."

    local verify_count=0
    while IFS= read -r backup_file; do
        if [[ -f "$backup_file" ]]; then
            if gunzip -t "$backup_file" 2>/dev/null; then
                verify_count=$((verify_count + 1))
            else
                error "Corrupted backup: $backup_file"
            fi
        fi
    done < <(find "$BACKUP_DEST" -name "mysql-*.sql.gz" -mtime -1)

    success "Verified backups: $verify_count"
}

# Rotate old backups
rotate_backups() {
    info "Rotating backups older than $RETENTION_DAYS days..."

    local count=0
    while IFS= read -r backup_file; do
        if [[ -f "$backup_file" ]]; then
            rm -f "$backup_file"
            count=$((count + 1))
        fi
    done < <(find "$BACKUP_DEST" -name "mysql-*.sql.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        success "Removed $count old backup(s)"
    else
        info "No old backups to remove"
    fi
}

# Create backup summary
create_summary() {
    local summary_file="${BACKUP_DEST}/backup-summary-${BACKUP_DATE}.txt"

    {
        echo "MySQL/MariaDB Backup Summary"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "RHEL Version: $RHEL_VERSION"
        echo ""
        echo "Backup Details:"
        ls -lh "${BACKUP_DEST}"/mysql-*.sql.gz 2>/dev/null | awk '{print $9, "(" $5 ")"}' || echo "No backups found"
        echo ""
        echo "Total backup size:"
        du -sh "${BACKUP_DEST}" | awk '{print $1}'
    } > "$summary_file"

    success "Summary created: $summary_file"
}

# List backups
list_backups() {
    info "Available backups:"
    echo ""
    ls -lh "${BACKUP_DEST}"/mysql-*.sql.gz 2>/dev/null | awk '{print $9, "(" $5 ")"}' || warn "No backups found"
}

# Main execution
main() {
    parse_args "$@"
    check_root
    detect_rhel
    check_mysql
    validate_destination

    {
        info "=== MySQL/MariaDB Backup Manager ==="
        info "RHEL Version: $RHEL_VERSION"
        info "Destination: $BACKUP_DEST"
        info "Retention: $RETENTION_DAYS days"
        info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        test_connection || exit 1
        echo ""

        backup_all_databases
        echo ""

        verify_backups
        echo ""

        rotate_backups
        echo ""

        create_summary
        echo ""

        list_backups
    }
}

main "$@"
