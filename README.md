# RHEL Administration Bash Scripts

A comprehensive collection of **55 production-ready Bash scripts** for administering Red Hat Enterprise Linux environments. Organized into 10 categories covering every major RHEL administration task. Compatible with **RHEL 7, 8, and 9**.

## Requirements

- **RHEL 7, 8, or 9** (or compatible: CentOS 7, AlmaLinux 8/9, Rocky Linux 8/9)
- **Bash 4.2+**
- **Root or sudo access** for most scripts
- Standard RHEL packages: `coreutils`, `util-linux`, `systemd`, `firewalld`, `lvm2`
- Some scripts require optional packages noted in their headers (e.g., `sysstat`, `audit`, `openssl`)

## Repository Structure

```
RHEL-Admin-Scripts/
├── User-Group-Management/     # 6 scripts — user lifecycle, sudoers, password policy
├── Package-Management/        # 5 scripts — patching, updates, repos, rollback
├── Service-Management/        # 5 scripts — systemd services, timers, dependencies
├── Networking-Firewall/       # 6 scripts — network config, firewall, troubleshooting
├── Storage-LVM/               # 6 scripts — disk usage, LVM, snapshots, swap
├── Security-Hardening/        # 7 scripts — SSH, SELinux, CIS benchmarks, auditing, certs
├── Monitoring-Logging/        # 5 scripts — health checks, log analysis, journal mgmt
├── Backup-Recovery/           # 5 scripts — system/config/DB backup, restore, verify
├── Performance-Tuning/        # 5 scripts — kernel tuning, I/O scheduler, limits, profiling
└── System-Reporting/          # 5 scripts — inventory, SOC reports, change tracking
```

---

## User & Group Management (6 scripts)

| Script | Description |
|--------|-------------|
| `add-user.sh` | Interactive or CLI user creation — sets home directory, shell, groups, password expiry policy. Validates input and logs creation |
| `disable-user.sh` | Safely disables accounts — locks password, expires account, kills active sessions. Doesn't delete, preserving audit trail |
| `audit-users.sh` | Audits all user accounts — last login, password age, shell, group memberships. Flags accounts with no password, never-expire, or unused |
| `manage-sudoers.sh` | Manages sudoers via drop-in files in `/etc/sudoers.d/`. Uses `visudo -cf` to validate syntax before applying. Actions: add, remove, list |
| `bulk-user-import.sh` | Imports users from CSV — creates accounts, generates random passwords, exports credentials. Supports `--dry-run` |
| `password-policy-check.sh` | Checks password policies — min/max age, complexity (pam_pwquality or pam_cracklib), users violating policy. RHEL 7/8/9 aware |

## Package Management (5 scripts)

| Script | Description |
|--------|-------------|
| `patch-system.sh` | Full system patching with safety — checks disk space, creates LVM snapshot, runs yum/dnf update, logs changes, optional reboot on kernel update. Supports `--security-only`, `--exclude`, `--dry-run` |
| `check-updates.sh` | Lists available updates grouped by severity — critical, important, moderate, bugfix, enhancement. Shows CVE IDs. Uses yum (RHEL 7) or dnf (RHEL 8/9) |
| `manage-repos.sh` | Repository management — list enabled/disabled, enable/disable repos, add custom repo files, show repo info, clean cache |
| `package-audit.sh` | Audits installed packages — finds manually installed, non-official repo packages, RPM signature verification failures, largest packages |
| `rollback-update.sh` | Rolls back last update transaction — uses yum/dnf history, shows transaction details before confirming. Supports `--transaction-id`, `--list`, `--dry-run` |

## Service Management (5 scripts)

| Script | Description |
|--------|-------------|
| `service-status.sh` | Service overview — groups services by state (running, stopped, failed, disabled). Highlights failed services. Shows boot-enabled vs runtime |
| `manage-service.sh` | Service management wrapper with audit logging — start, stop, restart, enable, disable, mask. Logs all state changes to `/var/log/service-changes.log` |
| `find-failed-services.sh` | Finds all failed systemd units, shows journal logs for each, optionally auto-restarts. Generates failure report |
| `service-dependency-map.sh` | Maps service dependencies (Wants, Requires, After, Before). Tree or flat output. Shows reverse dependencies |
| `timer-audit.sh` | Audits all systemd timers — next/last run, associated service, enabled state. Flags timers that haven't run recently |

## Networking & Firewall (6 scripts)

| Script | Description |
|--------|-------------|
| `network-info.sh` | Complete network overview — interfaces, IPs, routes, DNS, gateway, hostname, bonding/teaming, VLANs. NetworkManager (RHEL 8/9) and network-scripts (RHEL 7) |
| `firewall-audit.sh` | Audits firewalld rules — zones, services, ports, rich rules, direct rules. Flags overly permissive rules (any/any). Generates report |
| `manage-firewall-rules.sh` | Add/remove firewall rules with logging — ports, services, rich rules, source IPs. Makes changes permanent. Logs to `/var/log/firewall-changes.log` |
| `check-open-ports.sh` | Scans listening ports, maps to processes, compares against allowed-ports whitelist. Flags unauthorized listeners. Uses `ss` |
| `network-troubleshoot.sh` | Automated diagnostics — gateway ping, DNS resolution, traceroute, MTU check, interface errors/drops, NTP sync, HTTPS certificate expiry |
| `configure-static-ip.sh` | Configures static IP — supports NetworkManager (RHEL 8/9) and network-scripts (RHEL 7). Backs up existing config. Params: interface, IP, netmask, gateway, DNS |

## Storage & LVM (6 scripts)

| Script | Description |
|--------|-------------|
| `disk-usage-report.sh` | Disk usage report — filesystems, mount points, usage %, inode usage. Flags over threshold (default 80%). Top 20 largest directories |
| `lvm-report.sh` | Full LVM status — PVs, VGs, LVs with sizes and free space. Thin pool usage. Color-coded warnings |
| `extend-lvm.sh` | Extends logical volume and resizes filesystem (ext4/xfs). Validates free space in VG first. Supports absolute or incremental sizing |
| `create-lvm-snapshot.sh` | Creates LVM snapshot with optional auto-removal after X hours. Validates sufficient VG free space |
| `find-large-files.sh` | Finds largest files — size, owner, last modified, full path. Supports `--min-size`, `--exclude`, CSV output |
| `manage-swap.sh` | Swap management — show current, add swap file, remove swap, set swappiness. Persists to `/etc/fstab` |

## Security & Hardening (7 scripts)

| Script | Description |
|--------|-------------|
| `harden-ssh.sh` | Hardens SSH — disables root login, restricts ciphers/MACs/KexAlgorithms, sets MaxAuthTries, configures banner. Backs up original config. `--audit-only` mode |
| `selinux-manager.sh` | SELinux management — show status, set mode, manage booleans, troubleshoot AVC denials with `audit2why`/`audit2allow`. RHEL 7/8/9 |
| `security-audit.sh` | Comprehensive security audit — world-writable files, SUID/SGID binaries, unowned files, open ports, failed logins, password policy, firewall, SELinux. HTML report |
| `manage-firewall-zones.sh` | Advanced firewalld zone management — create custom zones, assign interfaces, set default zone, manage rich rules |
| `audit-log-analyzer.sh` | Analyzes `/var/log/audit/audit.log` — failed logins, sudo usage, file access, user/group changes, SELinux denials. Filter by timeframe and user |
| `apply-cis-benchmark.sh` | CIS Level 1 hardening — disables unused filesystems, sets sysctl parameters, configures password aging, restricts core dumps, sets file permissions. `--audit-only` mode |
| `certificate-manager.sh` | TLS certificate management — check expiry, generate self-signed, create CSR, show cert details. Alerts on certificates expiring within 30 days |

## Monitoring & Logging (5 scripts)

| Script | Description |
|--------|-------------|
| `system-health-check.sh` | Quick health check — CPU load, memory, disk, swap, zombie processes, failed services. Color-coded pass/warn/fail. Exit code reflects worst status |
| `log-analyzer.sh` | Analyzes system logs — error/warning counts, top error sources, login failures, kernel panics, OOM kills. Supports journal and traditional syslog |
| `monitor-resources.sh` | Real-time resource monitor — CPU per core, memory breakdown, disk I/O, network throughput. Configurable interval and count |
| `setup-logrotate.sh` | Creates or audits logrotate configurations. Validates existing configs for common issues |
| `journal-cleanup.sh` | Manages systemd journal — shows usage, vacuums to size/time limit, configures persistent journal settings |

## Backup & Recovery (5 scripts)

| Script | Description |
|--------|-------------|
| `backup-system.sh` | Full or incremental system backup via tar — excludes virtual filesystems, supports local and NFS destinations, creates manifest, rotates old backups |
| `backup-configs.sh` | Backs up critical configs — `/etc`, crontabs, firewall rules, RPM package list, network configs, fstab, grub. Timestamped tarball |
| `restore-configs.sh` | Restores config backup — lists contents, allows selective restore, creates safety backup of current configs before overwriting |
| `mysql-backup.sh` | MySQL/MariaDB backup — mysqldump, compression, rotation. Supports all databases or specific ones. Uses password file for security |
| `verify-backup.sh` | Verifies backup integrity — tests tar archive, checks manifest, validates checksums, reports file counts and sizes |

## Performance Tuning (5 scripts)

| Script | Description |
|--------|-------------|
| `tune-kernel.sh` | Kernel tuning via sysctl — network buffers, file descriptors, vm.swappiness, etc. Profiles: web-server, database, general. `--audit` and `--revert` modes |
| `analyze-performance.sh` | Performance snapshot — CPU, I/O wait, memory pressure, disk latency, network stats. Identifies bottleneck type (CPU/memory/disk/network) |
| `tune-disk-scheduler.sh` | I/O scheduler management — auto-detects SSD vs HDD, recommends scheduler (none/mq-deadline for SSD, bfq for HDD). Persists via udev rules |
| `optimize-limits.sh` | System limits via `/etc/security/limits.d/` — open files, max processes, core dumps, stack size. Profiles: default, web, database, high-performance |
| `resource-hog-finder.sh` | Finds resource-heavy processes — top CPU, memory, I/O, or open-file consumers. Generates kill list or nice recommendations |

## System Reporting (5 scripts)

| Script | Description |
|--------|-------------|
| `system-inventory.sh` | Full hardware/software inventory — CPU, RAM, disks, NICs, PCI, BIOS, OS, kernel, packages, services. Text or JSON output |
| `generate-soc-report.sh` | SOC/compliance report — user accounts, privileged access, packages, open ports, firewall, SELinux, failed logins, cron jobs, mounts. HTML output |
| `uptime-report.sh` | Uptime tracking — current uptime, last boot, reboot history, unplanned shutdowns, average uptime over configurable period |
| `compare-systems.sh` | System profile comparison — captures packages, services, firewall rules, kernel params, users into a profile file. Diff two profiles |
| `change-tracker.sh` | Configuration drift detection — uses `rpm -V` to find modified config files, compares against RPM database, flags unowned files |

---

## Common Features

All scripts share these production-quality characteristics:

- **`#!/bin/bash`** with **`set -euo pipefail`** for robust error handling
- **Header comment blocks** with description, usage examples, author, and RHEL compatibility notes
- **Color-coded output** — green (success), yellow (warning), red (error), blue (info)
- **Root privilege checking** where operations require it
- **RHEL version detection** — automatically uses the right commands for RHEL 7, 8, or 9
- **Help flags** (`-h`, `--help`) with usage documentation on every script
- **Logging** — operations logged with timestamps for audit trails
- **Dry-run modes** on destructive operations (`--dry-run`, `--audit-only`)
- **Backup before modify** — scripts that change configs create backups first

## Quick Start

```bash
# Clone the repository
git clone https://github.com/adroiteck/RHEL-Admin-Scripts.git
cd RHEL-Admin-Scripts

# Make all scripts executable
find . -name "*.sh" -exec chmod +x {} \;

# Run a quick system health check
sudo ./Monitoring-Logging/system-health-check.sh

# Check available security updates
sudo ./Package-Management/check-updates.sh --security-only

# Audit user accounts
sudo ./User-Group-Management/audit-users.sh --csv /tmp/user-audit.csv

# Run a full security audit with HTML report
sudo ./Security-Hardening/security-audit.sh --output /tmp/security-report.html

# Get full system inventory in JSON
sudo ./System-Reporting/system-inventory.sh --format json --output /tmp/inventory.json

# Audit firewall rules
sudo ./Networking-Firewall/firewall-audit.sh --output /tmp/firewall-report.txt

# Apply CIS Level 1 benchmark (audit only, no changes)
sudo ./Security-Hardening/apply-cis-benchmark.sh --audit-only
```

## RHEL Version Compatibility

| Feature | RHEL 7 | RHEL 8 | RHEL 9 |
|---------|--------|--------|--------|
| Package manager | yum | dnf | dnf |
| Firewall | firewalld | firewalld | firewalld |
| Network config | network-scripts | NetworkManager | NetworkManager |
| Init system | systemd | systemd | systemd |
| SELinux | ✓ | ✓ | ✓ |
| Password quality | pam_cracklib | pam_pwquality | pam_pwquality |

Scripts automatically detect the RHEL version and use the appropriate commands and paths.

## Contributing

Feel free to submit issues or pull requests. When adding new scripts, please follow the existing conventions: header comment blocks, `set -euo pipefail`, color output functions, root checks, and RHEL version detection.

## License

MIT License — free to use, modify, and distribute.
