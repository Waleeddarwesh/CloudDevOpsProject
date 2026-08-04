#!/usr/bin/env bash
# ==============================================================================
# Jenkins server bootstrap
# ==============================================================================
# Runs once, as root, on first boot.
#
# This script deliberately does the ABSOLUTE MINIMUM. It does not install Java,
# Jenkins, Docker or Trivy — that is Ansible's responsibility in Phase 3.
#
# Why the split matters:
#   * user_data runs exactly once. Fixing a mistake in it means destroying and
#     recreating the instance, losing all Jenkins build history.
#   * Ansible is idempotent and re-runnable. Adding a tool later is a playbook
#     edit and a 30-second re-run, not a rebuild.
#   * Provisioning (Terraform) and configuration (Ansible) stay separable, which
#     is the whole reason both tools exist.
#
# So all this does is make the instance reachable and ready for Ansible.
#
# Output is captured to /var/log/user-data.log — check there first if Ansible
# cannot connect after `terraform apply`.
# ==============================================================================

set -euo pipefail
# -e  exit on any command failure
# -u  treat unset variables as an error
# -o pipefail  a failure anywhere in a pipeline fails the whole pipeline

exec > >(tee -a /var/log/user-data.log) 2>&1

echo "=== [$(date -Is)] Jenkins server bootstrap starting ==="

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 1. Patch the base image
# ------------------------------------------------------------------------------
# The AMI is only as current as Canonical's last publish. Applying pending
# security updates on first boot closes that window.
echo "--- Updating APT cache and applying security updates"
apt-get update -y
apt-get upgrade -y

# ------------------------------------------------------------------------------
# 2. Install the Ansible control requirements
# ------------------------------------------------------------------------------
# Ansible needs Python 3 on the managed node. Ubuntu 22.04 ships it, but
# python3-apt is required by the ansible.builtin.apt module and is not always
# present in the minimal cloud image.
echo "--- Installing Python and base utilities"
apt-get install -y --no-install-recommends \
    python3 \
    python3-apt \
    python3-pip \
    curl \
    ca-certificates \
    gnupg \
    unzip \
    jq

# ------------------------------------------------------------------------------
# 3. Hostname
# ------------------------------------------------------------------------------
# A meaningful hostname makes `ansible-playbook` output and Jenkins agent logs
# readable, instead of showing ip-10-0-1-217.
echo "--- Setting hostname"
hostnamectl set-hostname jenkins-ci
# The loopback entry stops sudo from emitting "unable to resolve host" on every
# single command once the hostname no longer matches /etc/hosts.
echo "127.0.1.1 jenkins-ci" >> /etc/hosts

# ------------------------------------------------------------------------------
# 4. Enlarge the swap file
# ------------------------------------------------------------------------------
# t3.medium has 4 GiB of RAM. A Maven build of the roadmap-service plus a Trivy
# filesystem scan can briefly exceed that; without swap the kernel OOM-killer
# terminates the Jenkins JVM and the build dies with a confusing exit code 137.
# 2 GiB of swap absorbs the spike. This is a safety net, not a substitute for
# sizing the instance correctly.
echo "--- Creating 2G swap file"
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Prefer reclaiming page cache over swapping out live processes.
    sysctl -w vm.swappiness=10
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

# ------------------------------------------------------------------------------
# 5. Marker file
# ------------------------------------------------------------------------------
# The Ansible playbook waits on this before starting, which prevents the two
# from fighting over the APT lock — a race that otherwise produces the
# intermittent "Could not get lock /var/lib/dpkg/lock-frontend" failure.
echo "--- Writing completion marker"
cat > /etc/ivolve-bootstrap-complete <<EOF
bootstrap_completed_at=$(date -Is)
ami_id=$(cloud-init query -f '{{ ds.meta_data.ami_id }}' 2>/dev/null || echo unknown)
instance_id=$(cloud-init query -f '{{ ds.meta_data.instance_id }}' 2>/dev/null || echo unknown)
EOF

echo "=== [$(date -Is)] Bootstrap complete — ready for Ansible ==="
