#!/bin/bash

################################################################################
# Script: apply-cis-benchmark.sh
# Description: Applies CIS Level 1 benchmark hardening including kernel
#              parameters, filesystem restrictions, password policies, and
#              sensitive file permissions. Supports audit-only mode.
# Usage: apply-cis-benchmark.sh --audit-only
#        apply-cis-benchmark.sh --apply --section filesystem
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

# Apply kernel parameters
apply_kernel_params() {
    local apply=$1

    info "Applying kernel parameters..."

    local params=(
        "kernel.kptr_restrict=2"
        "kernel.dmesg_restrict=1"
        "kernel.printk=3 3 3 3"
        "kernel.unprivileged_userns_clone=0"
        "net.ipv4.ip_forward=0"
        "net.ipv4.conf.all.send_redirects=0"
        "net.ipv4.conf.default.send_redirects=0"
        "net.ipv4.conf.all.accept_source_route=0"
        "net.ipv4.conf.default.accept_source_route=0"
        "net.ipv4.conf.all.accept_redirects=0"
        "net.ipv4.conf.default.accept_redirects=0"
        "net.ipv4.icmp_echo_ignore_broadcasts=1"
        "net.ipv4.conf.all.log_martians=1"
        "net.ipv4.conf.default.log_martians=1"
    )

    for param in "${params[@]}"; do
        key=${param%=*}
        value=${param#*=}

        if [[ $apply -eq 1 ]]; then
            echo "$param" >> /etc/sysctl.d/99-cis-hardening.conf
            sysctl -w "$param" > /dev/null 2>&1
            success "Applied: $param"
        else
            current=$(sysctl -n "$key" 2>/dev/null || echo "not set")
            if [[ "$current" == "$value" ]]; then
                echo "[OK] $param"
            else
                echo "[FAIL] $param (current: $current)"
            fi
        fi
    done

    if [[ $apply -eq 1 ]]; then
        sysctl -p /etc/sysctl.d/99-cis-hardening.conf > /dev/null
        success "Kernel parameters applied"
    fi
}

# Disable unused filesystems
disable_unused_filesystems() {
    local apply=$1

    info "Disabling unused filesystems..."

    local filesystems=("cramfs" "squashfs" "udf")

    for fs in "${filesystems[@]}"; do
        if [[ $apply -eq 1 ]]; then
            echo "install $fs /bin/true" >> /etc/modprobe.d/cis-disable-filesystems.conf
            modprobe -r "$fs" 2>/dev/null || true
            success "Disabled filesystem: $fs"
        else
            if lsmod | grep -q "$fs"; then
                echo "[FAIL] Filesystem is loaded: $fs"
            else
                echo "[OK] Filesystem disabled: $fs"
            fi
        fi
    done
}

# Configure password policies
configure_password_policy() {
    local apply=$1

    info "Configuring password policies..."

    local policies=(
        "PASS_MAX_DAYS:90"
        "PASS_MIN_DAYS:1"
        "PASS_WARN_AGE:7"
        "PASS_MIN_LEN:14"
    )

    for policy in "${policies[@]}"; do
        key=${policy%:*}
        value=${policy#*:}

        if [[ $apply -eq 1 ]]; then
            if grep -q "^$key" /etc/login.defs; then
                sed -i "s/^$key.*/$key $value/" /etc/login.defs
            else
                echo "$key $value" >> /etc/login.defs
            fi
            success "Applied: $policy"
        else
            current=$(grep "^$key" /etc/login.defs | awk '{print $NF}' 2>/dev/null || echo "not set")
            if [[ "$current" == "$value" ]]; then
                echo "[OK] $policy"
            else
                echo "[FAIL] $policy (current: $current)"
            fi
        fi
    done
}

# Restrict core dumps
restrict_core_dumps() {
    local apply=$1

    info "Restricting core dumps..."

    if [[ $apply -eq 1 ]]; then
        echo "*   soft  core  0" >> /etc/security/limits.conf
        echo "*   hard  core  0" >> /etc/security/limits.conf
        sysctl -w kernel.core_uses_pid=0 > /dev/null
        success "Core dumps restricted"
    else
        current=$(sysctl -n kernel.core_uses_pid)
        if [[ "$current" == "0" ]]; then
            echo "[OK] Core dumps restricted"
        else
            echo "[FAIL] Core dumps not restricted"
        fi
    fi
}

# Set permissions on sensitive files
set_file_permissions() {
    local apply=$1

    info "Setting permissions on sensitive files..."

    local files=(
        "/etc/passwd:0644"
        "/etc/shadow:0600"
        "/etc/group:0644"
        "/etc/gshadow:0600"
        "/boot/grub2/grub.cfg:0600"
    )

    for file_perm in "${files[@]}"; do
        file=${file_perm%:*}
        perm=${file_perm#*:}

        if [[ ! -e "$file" ]]; then
            continue
        fi

        if [[ $apply -eq 1 ]]; then
            chmod "$perm" "$file"
            success "Set permissions: $file ($perm)"
        else
            current=$(stat -c %a "$file")
            if [[ "$current" == "$perm" ]]; then
                echo "[OK] $file ($perm)"
            else
                echo "[FAIL] $file (current: $current, expected: $perm)"
            fi
        fi
    done
}

# Disable unnecessary services
disable_unnecessary_services() {
    local apply=$1

    info "Checking unnecessary services..."

    local services=("avahi-daemon" "cups" "isc-dhcp-server" "isc-dhcp-server6" "slapd" "xserver-xorg*")

    for service in "${services[@]}"; do
        if [[ $apply -eq 1 ]]; then
            systemctl disable "$service" 2>/dev/null || true
            systemctl stop "$service" 2>/dev/null || true
        else
            if systemctl is-enabled "$service" &>/dev/null; then
                echo "[FAIL] Service is enabled: $service"
            else
                echo "[OK] Service disabled: $service"
            fi
        fi
    done
}

# Parse arguments
APPLY=0
AUDIT_ONLY=0
SECTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) APPLY=1; shift ;;
        --audit-only) AUDIT_ONLY=1; shift ;;
        --section) SECTION="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

check_root
detect_rhel_version

info "CIS Benchmark Hardening Script (RHEL $RHEL_VERSION)"

if [[ $AUDIT_ONLY -eq 1 ]]; then
    APPLY=0
    info "Running in audit-only mode"
fi

if [[ -z "$SECTION" || "$SECTION" == "kernel" ]]; then
    apply_kernel_params "$APPLY"
fi

if [[ -z "$SECTION" || "$SECTION" == "filesystem" ]]; then
    disable_unused_filesystems "$APPLY"
fi

if [[ -z "$SECTION" || "$SECTION" == "password" ]]; then
    configure_password_policy "$APPLY"
fi

if [[ -z "$SECTION" || "$SECTION" == "core" ]]; then
    restrict_core_dumps "$APPLY"
fi

if [[ -z "$SECTION" || "$SECTION" == "permissions" ]]; then
    set_file_permissions "$APPLY"
fi

if [[ -z "$SECTION" || "$SECTION" == "services" ]]; then
    disable_unnecessary_services "$APPLY"
fi

if [[ $APPLY -eq 1 ]]; then
    success "CIS benchmark hardening applied"
else
    info "Audit completed. Use --apply flag to apply changes."
fi
