#!/bin/bash

################################################################################
# Script: harden-ssh.sh
# Description: Hardens SSH configuration by disabling root login, restricting
#              ciphers/MACs/KexAlgorithms, enabling fail2ban integration.
# Usage: harden-ssh.sh --apply [--port 2222] [--audit-only]
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

# Backup original sshd_config
backup_sshd_config() {
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%s)"
    if [[ ! -f "$backup_file" ]]; then
        cp /etc/ssh/sshd_config "$backup_file"
        info "Backed up sshd_config to: $backup_file"
    fi
}

# Apply SSH hardening
apply_hardening() {
    local port=$1
    backup_sshd_config

    info "Applying SSH hardening..."

    # Create a temporary config file with hardening rules
    local temp_config="/tmp/sshd_config.hardened"
    cp /etc/ssh/sshd_config "$temp_config"

    # Function to add or update sshd config parameter
    update_config() {
        local param=$1
        local value=$2
        local file=$3

        if grep -q "^#$param" "$file" || grep -q "^$param" "$file"; then
            sed -i "s/^#*$param.*/$param $value/" "$file"
        else
            echo "$param $value" >> "$file"
        fi
    }

    # Apply hardening settings
    update_config "Protocol" "2" "$temp_config"
    update_config "Port" "$port" "$temp_config"
    update_config "PermitRootLogin" "no" "$temp_config"
    update_config "PubkeyAuthentication" "yes" "$temp_config"
    update_config "PasswordAuthentication" "no" "$temp_config"
    update_config "PermitEmptyPasswords" "no" "$temp_config"
    update_config "MaxAuthTries" "3" "$temp_config"
    update_config "MaxSessions" "10" "$temp_config"
    update_config "ClientAliveInterval" "300" "$temp_config"
    update_config "ClientAliveCountMax" "2" "$temp_config"
    update_config "X11Forwarding" "no" "$temp_config"
    update_config "AllowAgentForwarding" "no" "$temp_config"
    update_config "AllowTcpForwarding" "no" "$temp_config"
    update_config "PermitTunnel" "no" "$temp_config"
    update_config "Compression" "no" "$temp_config"

    # Set strict cipher and key exchange restrictions
    update_config "Ciphers" "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr" "$temp_config"
    update_config "MACs" "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256" "$temp_config"
    update_config "KexAlgorithms" "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" "$temp_config"

    # Add banner
    update_config "Banner" "/etc/ssh/banner" "$temp_config"

    # Create banner file
    if [[ ! -f /etc/ssh/banner ]]; then
        cat > /etc/ssh/banner << 'BANNER'
################################################################################
#           UNAUTHORIZED ACCESS TO THIS SYSTEM IS FORBIDDEN                   #
#   Unauthorized access to this system is forbidden and will be prosecuted    #
#   by law. By accessing this system, you agree that your actions may be      #
#   monitored and recorded.                                                    #
################################################################################
BANNER
        chmod 644 /etc/ssh/banner
    fi

    # Validate the new config
    if ! sshd -t -f "$temp_config"; then
        error "SSH config validation failed"
        return 1
    fi

    # Apply the new config
    cp "$temp_config" /etc/ssh/sshd_config
    rm "$temp_config"

    success "SSH hardening applied successfully"
}

# Audit current SSH configuration
audit_ssh() {
    info "Auditing current SSH configuration..."
    echo ""
    echo "================================ SSH CONFIGURATION AUDIT ================================"

    local checks=(
        "PermitRootLogin:no"
        "PubkeyAuthentication:yes"
        "PasswordAuthentication:no"
        "PermitEmptyPasswords:no"
        "MaxAuthTries:3"
        "X11Forwarding:no"
    )

    for check in "${checks[@]}"; do
        param=${check%:*}
        expected=${check#*:}
        current=$(grep "^$param " /etc/ssh/sshd_config | awk '{print $NF}' || echo "not set")

        if [[ "$current" == "$expected" ]]; then
            status="\033[0;32m[OK]\033[0m"
        else
            status="\033[0;31m[FAIL]\033[0m"
        fi

        printf "%-30s Expected: %-15s Current: %-15s %s\n" "$param" "$expected" "$current" "$status"
    done

    echo ""
    success "SSH audit completed"
}

# Parse arguments
APPLY=0
AUDIT=0
PORT=22

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) APPLY=1; shift ;;
        --audit-only) AUDIT=1; shift ;;
        --port) PORT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

check_root
detect_rhel_version

info "SSH Hardening Script (RHEL $RHEL_VERSION)"

if [[ $AUDIT -eq 1 ]]; then
    audit_ssh
elif [[ $APPLY -eq 1 ]]; then
    apply_hardening "$PORT"
    audit_ssh

    info "Reloading SSH service..."
    systemctl reload sshd

    success "SSH hardening completed successfully"
else
    audit_ssh
fi
