#!/bin/bash

################################################################################
# Script: generate-soc-report.sh
# Description: Generates SOC/compliance report in HTML format
# Usage: ./generate-soc-report.sh [--output report.html]
# Author: System Administration Team
# Compatibility: RHEL 7, 8, 9
# Requirements: root (recommended), standard utilities
################################################################################

set -euo pipefail

# Color output functions
info() { echo -e "\033[0;36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }

# Global variables
OUTPUT_FILE=""
RHEL_VERSION=""
REPORT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) OUTPUT_FILE="$2"; shift ;;
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

# Collect user accounts
collect_user_accounts() {
    awk -F: '$3 >= 1000 {print $1}' /etc/passwd
}

# Collect privileged access
collect_privileged_access() {
    if [[ -f /etc/sudoers ]]; then
        grep -v "^#" /etc/sudoers | grep -v "^Defaults" | grep -v "^%" | head -10
    fi
}

# Collect installed packages
collect_packages() {
    if command -v rpm &> /dev/null; then
        rpm -qa --queryformat='%{NAME}-%{VERSION}-%{RELEASE}\n' | head -20
    fi
}

# Collect open ports
collect_open_ports() {
    if command -v ss &> /dev/null; then
        ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | head -10
    else
        netstat -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | head -10 || echo "N/A"
    fi
}

# Collect firewall rules
collect_firewall_rules() {
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --list-all 2>/dev/null | head -15 || echo "Firewall not active"
    elif command -v iptables &> /dev/null; then
        iptables -L -n 2>/dev/null | head -10 || echo "No rules found"
    else
        echo "No firewall configured"
    fi
}

# Collect SELinux status
collect_selinux_status() {
    if command -v getenforce &> /dev/null; then
        getenforce
    else
        echo "SELinux not installed"
    fi
}

# Collect failed logins
collect_failed_logins() {
    if command -v lastb &> /dev/null; then
        lastb -f /var/log/btmp 2>/dev/null | head -20 | awk '{print $1, $3, $NF}'
    elif [[ -f /var/log/auth.log ]]; then
        grep "Failed password" /var/log/auth.log 2>/dev/null | tail -10 | awk '{print $1, $2, $3, $11}'
    else
        echo "No login failure data available"
    fi
}

# Collect cron jobs
collect_cron_jobs() {
    if [[ -d /var/spool/cron ]]; then
        ls -la /var/spool/cron/crontabs 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

# Collect mounted filesystems
collect_mounted_fs() {
    mount | grep -v "^proc\|^sys\|^dev\|^run" | head -10
}

# Generate HTML report
generate_html_report() {
    local output_file="${OUTPUT_FILE:-soc-report-$(date '+%Y%m%d-%H%M%S').html}"

    info "Generating SOC/Compliance Report..."

    cat > "$output_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SOC Compliance Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }
        .header { background-color: #2c3e50; color: white; padding: 20px; border-radius: 5px; }
        .section { background-color: white; margin: 20px 0; padding: 20px; border-radius: 5px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .section h2 { border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        .alert { padding: 10px; margin: 10px 0; border-radius: 3px; }
        .alert-warning { background-color: #fff3cd; border-left: 4px solid #ffc107; }
        .alert-danger { background-color: #f8d7da; border-left: 4px solid #dc3545; }
        .alert-success { background-color: #d4edda; border-left: 4px solid #28a745; }
        table { width: 100%; border-collapse: collapse; margin: 10px 0; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background-color: #f0f0f0; font-weight: bold; }
        tr:hover { background-color: #f9f9f9; }
        .metric { display: inline-block; width: 45%; margin: 10px 2.5%; padding: 10px; background-color: #f9f9f9; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>SOC Compliance Report</h1>
        <p>System: HOSTNAME | Generated: TIMESTAMP | RHEL Version: RHEL_VERSION</p>
    </div>

    <div class="section">
        <h2>Executive Summary</h2>
        <p>This report provides a security and operational compliance overview of the system.</p>
        <div class="metric">
            <strong>User Accounts:</strong> USER_COUNT
        </div>
        <div class="metric">
            <strong>Privileged Users:</strong> PRIV_COUNT
        </div>
        <div class="metric">
            <strong>Installed Packages:</strong> PKG_COUNT
        </div>
        <div class="metric">
            <strong>Open Ports:</strong> PORT_COUNT
        </div>
    </div>

    <div class="section">
        <h2>User Management</h2>
        <h3>Non-System User Accounts</h3>
        <pre>USER_LIST</pre>
    </div>

    <div class="section">
        <h2>Privileged Access</h2>
        <h3>sudo Configuration</h3>
        <pre>SUDO_CONFIG</pre>
    </div>

    <div class="section">
        <h2>Network Security</h2>
        <h3>Open Ports (Listening Services)</h3>
        <pre>PORT_LIST</pre>

        <h3>Firewall Configuration</h3>
        <pre>FIREWALL_CONFIG</pre>
    </div>

    <div class="section">
        <h2>System Security</h2>
        <h3>SELinux Status</h3>
        <p><strong>SELINUX_STATUS</strong></p>

        <h3>Failed Login Attempts (Last 30 Days)</h3>
        <pre>FAILED_LOGINS</pre>
    </div>

    <div class="section">
        <h2>Installed Software</h2>
        <h3>Package Inventory (Sample)</h3>
        <pre>PACKAGE_LIST</pre>
    </div>

    <div class="section">
        <h2>Scheduled Tasks</h2>
        <h3>Cron Jobs</h3>
        <p><strong>Total cron entries:</strong> CRON_COUNT</p>
    </div>

    <div class="section">
        <h2>Storage</h2>
        <h3>Mounted Filesystems</h3>
        <pre>MOUNTED_FS</pre>
    </div>

    <div class="section">
        <h2>Compliance Notes</h2>
        <ul>
            <li>Review user accounts for compliance with organizational standards</li>
            <li>Verify sudo configuration aligns with least-privilege principle</li>
            <li>Audit firewall rules for alignment with security policy</li>
            <li>Monitor failed login attempts for unauthorized access attempts</li>
            <li>Review installed packages and remove unnecessary components</li>
        </ul>
    </div>

    <div class="section" style="background-color: #f0f0f0; text-align: center; margin-top: 40px;">
        <p><small>Report generated on TIMESTAMP | System: HOSTNAME</small></p>
    </div>
</body>
</html>
HTMLEOF

    # Replace placeholders
    local user_list=$(collect_user_accounts | head -20 | paste -sd, -)
    local user_count=$(collect_user_accounts | wc -l)
    local priv_count=$(collect_privileged_access | wc -l)
    local pkg_count=$(rpm -qa 2>/dev/null | wc -l || echo 0)
    local port_count=$(collect_open_ports | wc -l)
    local sudo_config=$(collect_privileged_access | head -5)
    local port_list=$(collect_open_ports | head -10)
    local firewall=$(collect_firewall_rules | head -15)
    local selinux=$(collect_selinux_status)
    local failed_logins=$(collect_failed_logins | head -10)
    local packages=$(collect_packages | head -10)
    local cron_count=$(collect_cron_jobs)
    local mounted=$(collect_mounted_fs | head -10)

    sed -i "s|HOSTNAME|$HOSTNAME|g" "$output_file"
    sed -i "s|TIMESTAMP|$REPORT_DATE|g" "$output_file"
    sed -i "s|RHEL_VERSION|$RHEL_VERSION|g" "$output_file"
    sed -i "s|USER_COUNT|$user_count|g" "$output_file"
    sed -i "s|PRIV_COUNT|$priv_count|g" "$output_file"
    sed -i "s|PKG_COUNT|$pkg_count|g" "$output_file"
    sed -i "s|PORT_COUNT|$port_count|g" "$output_file"
    sed -i "s|USER_LIST|$user_list|g" "$output_file"
    sed -i "s|SUDO_CONFIG|$sudo_config|g" "$output_file"
    sed -i "s|PORT_LIST|$(echo "$port_list" | sed 's/$/\\n/' | tr '\n' ' ')|g" "$output_file"
    sed -i "s|FIREWALL_CONFIG|$firewall|g" "$output_file"
    sed -i "s|SELINUX_STATUS|$selinux|g" "$output_file"
    sed -i "s|FAILED_LOGINS|$failed_logins|g" "$output_file"
    sed -i "s|PACKAGE_LIST|$(echo "$packages" | sed 's/$/\\n/' | head -c 200)|g" "$output_file"
    sed -i "s|CRON_COUNT|$cron_count|g" "$output_file"
    sed -i "s|MOUNTED_FS|$mounted|g" "$output_file"

    success "Report generated: $output_file"
    info "Size: $(du -sh "$output_file" | awk '{print $1}')"
}

# Main execution
main() {
    parse_args "$@"
    detect_rhel

    {
        info "=== SOC/Compliance Report Generator ==="
        info "RHEL Version: $RHEL_VERSION"
        info "System: $HOSTNAME"
        info "Timestamp: $REPORT_DATE"
        echo ""

        generate_html_report
    }
}

main "$@"
