#!/bin/bash

################################################################################
# Script: security-audit.sh
# Description: Comprehensive security audit checking world-writable files,
#              SUID/SGID binaries, unowned files, open ports, failed logins,
#              and password policies. Generates HTML report.
# Usage: security-audit.sh [--html /tmp/audit.html]
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

# Initialize HTML report
init_html_report() {
    local report_file=$1
    cat > "$report_file" << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Security Audit Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: #333; color: white; padding: 20px; border-radius: 5px; }
        .section { background: white; margin: 20px 0; padding: 20px; border-radius: 5px; border-left: 5px solid #0066cc; }
        .warning { border-left-color: #ff9800; }
        .critical { border-left-color: #f44336; }
        .success { border-left-color: #4caf50; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f2f2f2; }
        .pass { color: green; font-weight: bold; }
        .fail { color: red; font-weight: bold; }
        .warn { color: orange; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Security Audit Report</h1>
        <p>Generated: <script>document.write(new Date().toString());</script></p>
    </div>
HTML
}

# Append section to HTML report
append_html_section() {
    local report_file=$1
    local title=$2
    local status=$3
    local content=$4

    local class="section"
    [[ "$status" == "critical" ]] && class="section critical"
    [[ "$status" == "warning" ]] && class="section warning"
    [[ "$status" == "pass" ]] && class="section success"

    cat >> "$report_file" << HTML
    <div class="$class">
        <h2>$title</h2>
        <div>$content</div>
    </div>
HTML
}

# Close HTML report
close_html_report() {
    local report_file=$1
    cat >> "$report_file" << 'HTML'
</body>
</html>
HTML
}

# Check world-writable files
check_world_writable() {
    local report_file=$1
    info "Checking world-writable files..."

    local ww_files=$(find / -xdev -type f -perm -002 2>/dev/null | head -20)
    local ww_count=$(echo "$ww_files" | grep -c . || echo 0)

    if [[ $ww_count -gt 0 ]]; then
        local content="<p class='warn'>Found $ww_count world-writable files:</p><pre>$(echo "$ww_files" | head -10)</pre>"
        append_html_section "$report_file" "World-Writable Files" "critical" "$content"
        warn "Found world-writable files: $ww_count"
    else
        append_html_section "$report_file" "World-Writable Files" "pass" "<p class='pass'>No world-writable files found</p>"
        success "No world-writable files found"
    fi
}

# Check SUID/SGID binaries
check_suid_binaries() {
    local report_file=$1
    info "Checking SUID/SGID binaries..."

    local suid_files=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l)

    local content="<p>Found $suid_files SUID/SGID binaries (sampling first 15):</p>"
    content="$content<pre>$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | head -15)</pre>"

    append_html_section "$report_file" "SUID/SGID Binaries" "warning" "$content"
    warn "Found $suid_files SUID/SGID binaries"
}

# Check unowned files
check_unowned_files() {
    local report_file=$1
    info "Checking unowned files..."

    local unowned=$(find / -xdev \( -nouser -o -nogroup \) -type f 2>/dev/null | head -20)
    local unowned_count=$(echo "$unowned" | grep -c . || echo 0)

    if [[ $unowned_count -gt 0 ]]; then
        local content="<p class='warn'>Found $unowned_count unowned files:</p><pre>$unowned</pre>"
        append_html_section "$report_file" "Unowned Files" "critical" "$content"
        warn "Found unowned files: $unowned_count"
    else
        append_html_section "$report_file" "Unowned Files" "pass" "<p class='pass'>No unowned files found</p>"
        success "No unowned files found"
    fi
}

# Check open ports
check_open_ports() {
    local report_file=$1
    info "Checking open ports..."

    local open_ports=$(netstat -tlnp 2>/dev/null | grep LISTEN || echo "No listening ports")

    local content="<p>Currently listening ports:</p><pre>$open_ports</pre>"
    append_html_section "$report_file" "Open Ports" "warning" "$content"
}

# Check failed logins
check_failed_logins() {
    local report_file=$1
    info "Checking failed logins..."

    local failed_logins=$(lastb -f /var/log/btmp 2>/dev/null | head -10 || echo "No failed logins")
    local failed_count=$(lastb 2>/dev/null | wc -l || echo 0)

    local content="<p>Failed login attempts (last 24h): $failed_count</p><pre>$failed_logins</pre>"
    append_html_section "$report_file" "Failed Logins" "warning" "$content"
}

# Check password policy
check_password_policy() {
    local report_file=$1
    info "Checking password policy..."

    local content="<table>"
    content="$content<tr><th>Parameter</th><th>Value</th></tr>"

    local params=(
        "PASS_MAX_DAYS:/etc/login.defs"
        "PASS_MIN_DAYS:/etc/login.defs"
        "PASS_WARN_AGE:/etc/login.defs"
        "PASS_MIN_LEN:/etc/login.defs"
    )

    for param in "${params[@]}"; do
        local key=${param%:*}
        local file=${param#*:}
        local value=$(grep "^$key" "$file" 2>/dev/null | awk '{print $NF}' || echo "not set")
        content="$content<tr><td>$key</td><td>$value</td></tr>"
    done

    content="$content</table>"
    append_html_section "$report_file" "Password Policy" "warning" "$content"
}

# Check firewall status
check_firewall() {
    local report_file=$1
    info "Checking firewall status..."

    local fw_status="$(systemctl is-active firewalld 2>/dev/null || echo 'inactive')"
    local content="<p>Firewall Status: <strong>$fw_status</strong></p>"

    if [[ "$fw_status" == "active" ]]; then
        content="$content<pre>$(firewall-cmd --list-all 2>/dev/null | head -20)</pre>"
        append_html_section "$report_file" "Firewall Status" "pass" "$content"
    else
        append_html_section "$report_file" "Firewall Status" "critical" "$content"
    fi
}

# Check SELinux status
check_selinux() {
    local report_file=$1
    info "Checking SELinux status..."

    local selinux_status="$(getenforce 2>/dev/null || echo 'disabled')"
    local content="<p>SELinux Status: <strong>$selinux_status</strong></p>"

    if [[ "$selinux_status" == "Enforcing" ]]; then
        append_html_section "$report_file" "SELinux Status" "pass" "$content"
    else
        append_html_section "$report_file" "SELinux Status" "warning" "$content"
    fi
}

# Parse arguments
REPORT_FILE=""
HTML_OUTPUT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --html) REPORT_FILE="$2"; HTML_OUTPUT=1; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

check_root
detect_rhel_version

info "Starting comprehensive security audit (RHEL $RHEL_VERSION)"

if [[ $HTML_OUTPUT -eq 1 ]]; then
    init_html_report "$REPORT_FILE"
fi

# Run all checks
check_world_writable "$REPORT_FILE"
check_suid_binaries "$REPORT_FILE"
check_unowned_files "$REPORT_FILE"
check_open_ports "$REPORT_FILE"
check_failed_logins "$REPORT_FILE"
check_password_policy "$REPORT_FILE"
check_firewall "$REPORT_FILE"
check_selinux "$REPORT_FILE"

if [[ $HTML_OUTPUT -eq 1 ]]; then
    close_html_report "$REPORT_FILE"
    success "HTML report generated: $REPORT_FILE"
fi

success "Security audit completed"
