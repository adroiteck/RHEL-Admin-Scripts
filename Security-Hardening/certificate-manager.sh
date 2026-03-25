#!/bin/bash

################################################################################
# Script: certificate-manager.sh
# Description: Manages TLS certificates including expiry checking, self-signed
#              certificate generation, CSR creation, certificate details display,
#              and expiration alerts for certificates expiring within 30 days.
# Usage: certificate-manager.sh --action check [--cert-path /etc/ssl/certs]
#        certificate-manager.sh --action generate --cn example.com --days 365
#        certificate-manager.sh --action csr --cn example.com --output csr.pem
# Author: System Administrator
# Compatibility: RHEL 7/8/9, CentOS 7/8 with openssl
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

# Check if OpenSSL is installed
check_openssl() {
    if ! command -v openssl &> /dev/null; then
        error "openssl not installed. Install with: yum install openssl"
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

# Check certificate expiry dates
check_expiry() {
    local cert_path=$1
    local alert_days=30

    echo ""
    echo "================================ CERTIFICATE EXPIRY CHECK ================================"

    # Find all certificate files
    find "$cert_path" -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cert" \) 2>/dev/null | while read -r cert; do
        if ! openssl x509 -in "$cert" -noout 2>/dev/null; then
            continue
        fi

        subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject=//')
        issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/issuer=//')
        expiry_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        expiry_epoch=$(date -d "$expiry_date" +%s)
        current_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

        if [[ $days_left -lt 0 ]]; then
            status="\033[0;31m[EXPIRED]\033[0m"
        elif [[ $days_left -le $alert_days ]]; then
            status="\033[1;33m[EXPIRING]\033[0m"
        else
            status="\033[0;32m[OK]\033[0m"
        fi

        printf "%-60s %-40s %s\n" "$subject" "${expiry_date:0:10}" "$status"

        if [[ $days_left -le $alert_days && $days_left -ge 0 ]]; then
            warn "Certificate expiring in $days_left days: ${cert##*/}"
        elif [[ $days_left -lt 0 ]]; then
            error "Expired certificate found: ${cert##*/}"
        fi
    done

    success "Certificate expiry check completed"
}

# Show certificate details
show_details() {
    local cert_file=$1

    if [[ ! -f "$cert_file" ]]; then
        error "Certificate file not found: $cert_file"
        exit 1
    fi

    if ! openssl x509 -in "$cert_file" -noout &>/dev/null; then
        error "Invalid certificate file: $cert_file"
        exit 1
    fi

    echo ""
    echo "================================ CERTIFICATE DETAILS ================================"

    info "Subject:"
    openssl x509 -in "$cert_file" -noout -subject

    info "Issuer:"
    openssl x509 -in "$cert_file" -noout -issuer

    info "Valid From:"
    openssl x509 -in "$cert_file" -noout -startdate

    info "Valid To:"
    openssl x509 -in "$cert_file" -noout -enddate

    info "Serial Number:"
    openssl x509 -in "$cert_file" -noout -serial

    info "Fingerprint (SHA256):"
    openssl x509 -in "$cert_file" -noout -fingerprint -sha256

    info "Fingerprint (SHA1):"
    openssl x509 -in "$cert_file" -noout -fingerprint -sha1

    echo ""
    info "Full Details:"
    openssl x509 -in "$cert_file" -noout -text

    success "Certificate details displayed"
}

# Generate self-signed certificate
generate_self_signed() {
    local cn=$1
    local days=$2
    local output_cert=$3
    local output_key=$4
    local key_size=2048

    if [[ -f "$output_cert" || -f "$output_key" ]]; then
        error "Certificate or key file already exists"
        exit 1
    fi

    info "Generating self-signed certificate for: $cn"
    info "Validity: $days days, Key size: $key_size bits"

    # Generate private key
    if ! openssl genrsa -out "$output_key" "$key_size" 2>/dev/null; then
        error "Failed to generate private key"
        exit 1
    fi

    # Generate certificate
    if ! openssl req -new -x509 -key "$output_key" -out "$output_cert" \
        -subj "/CN=$cn" -days "$days" 2>/dev/null; then
        error "Failed to generate certificate"
        rm -f "$output_key"
        exit 1
    fi

    chmod 400 "$output_key"
    chmod 444 "$output_cert"

    success "Self-signed certificate generated"
    info "Certificate: $output_cert"
    info "Private Key: $output_key"
}

# Create Certificate Signing Request (CSR)
create_csr() {
    local cn=$1
    local output_csr=$2
    local output_key=$3
    local key_size=2048

    if [[ -f "$output_csr" || -f "$output_key" ]]; then
        error "CSR or key file already exists"
        exit 1
    fi

    info "Creating CSR for: $cn"

    # Generate private key
    if ! openssl genrsa -out "$output_key" "$key_size" 2>/dev/null; then
        error "Failed to generate private key"
        exit 1
    fi

    # Generate CSR
    if ! openssl req -new -key "$output_key" -out "$output_csr" \
        -subj "/CN=$cn" 2>/dev/null; then
        error "Failed to create CSR"
        rm -f "$output_key"
        exit 1
    fi

    chmod 400 "$output_key"
    chmod 644 "$output_csr"

    success "CSR created successfully"
    info "CSR: $output_csr"
    info "Private Key: $output_key"

    info "CSR Details:"
    openssl req -in "$output_csr" -noout -text
}

# List all alerts
show_alerts() {
    local cert_path=$1
    local alert_days=30

    echo ""
    echo "================================ CERTIFICATE ALERTS ================================"

    local alert_count=0

    find "$cert_path" -type f \( -name "*.crt" -o -name "*.pem" -o -name "*.cert" \) 2>/dev/null | while read -r cert; do
        if ! openssl x509 -in "$cert" -noout 2>/dev/null; then
            continue
        fi

        expiry_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        expiry_epoch=$(date -d "$expiry_date" +%s)
        current_epoch=$(date +%s)
        days_left=$(( (expiry_epoch - current_epoch) / 86400 ))

        if [[ $days_left -le $alert_days ]]; then
            alert_count=$((alert_count + 1))
            subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject=//')

            if [[ $days_left -lt 0 ]]; then
                echo "[EXPIRED] $subject (expired $((-days_left)) days ago)"
            else
                echo "[EXPIRING] $subject (expires in $days_left days)"
            fi
        fi
    done

    success "Alert check completed"
}

# Parse arguments
ACTION=""
CERT_PATH="/etc/ssl/certs"
CN=""
DAYS=365
CSR_OUTPUT="csr.pem"
KEY_OUTPUT="key.pem"
CERT_OUTPUT="cert.pem"
DETAILS_CERT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --action) ACTION="$2"; shift 2 ;;
        --cert-path) CERT_PATH="$2"; shift 2 ;;
        --cn) CN="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --csr-output) CSR_OUTPUT="$2"; shift 2 ;;
        --key-output) KEY_OUTPUT="$2"; shift 2 ;;
        --cert-output) CERT_OUTPUT="$2"; shift 2 ;;
        --cert) DETAILS_CERT="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ACTION" ]]; then
    error "Missing required argument: --action"
    echo "Usage: $0 --action [check|generate|csr|details|alerts]"
    exit 1
fi

check_openssl
detect_rhel_version

case "$ACTION" in
    check)
        if [[ ! -d "$CERT_PATH" ]]; then
            error "Certificate path not found: $CERT_PATH"
            exit 1
        fi
        check_expiry "$CERT_PATH"
        ;;
    generate)
        if [[ -z "$CN" ]]; then
            error "Missing argument: --cn (common name)"
            exit 1
        fi
        generate_self_signed "$CN" "$DAYS" "$CERT_OUTPUT" "$KEY_OUTPUT"
        ;;
    csr)
        if [[ -z "$CN" ]]; then
            error "Missing argument: --cn (common name)"
            exit 1
        fi
        create_csr "$CN" "$CSR_OUTPUT" "$KEY_OUTPUT"
        ;;
    details)
        if [[ -z "$DETAILS_CERT" ]]; then
            error "Missing argument: --cert"
            exit 1
        fi
        show_details "$DETAILS_CERT"
        ;;
    alerts)
        if [[ ! -d "$CERT_PATH" ]]; then
            error "Certificate path not found: $CERT_PATH"
            exit 1
        fi
        show_alerts "$CERT_PATH"
        ;;
    *)
        error "Unknown action: $ACTION"
        exit 1
        ;;
esac
