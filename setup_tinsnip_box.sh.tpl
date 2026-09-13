#!/bin/bash
# Minimal first-boot setup for a tinsnip box: rootless podman for the
# ubuntu user, lingering so user units survive logout, and the firewall
# open for SSH, HTTP and HTTPS. Everything else is installed by cloning
# the tinsnip repo and running its install.sh as the ubuntu user.
#
# Terraform templatefile() substitutes $${...}; shell variables are
# escaped as $$ where needed. domain and email are accepted for
# interface parity with the gateway template and are unused here.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    podman \
    uidmap \
    slirp4netns \
    fuse-overlayfs \
    git \
    curl \
    ca-certificates \
    ufw \
    wireguard

# OCI Ubuntu images ship iptables rules that block everything but SSH;
# ufw manages them from here on. Private boxes expose only WireGuard, plus
# SSH until the tunnel is proven and the security list closes 22.
ufw allow OpenSSH
ufw allow 51820/udp
%{ if public ~}
ufw allow 80/tcp
ufw allow 443/tcp
%{ endif ~}
ufw --force enable

# Rootless podman needs the user's systemd instance to outlive logins.
loginctl enable-linger ubuntu

# Let rootless containers bind 80/443 for a reverse proxy.
cat > /etc/sysctl.d/99-rootless-ports.conf <<'SYSCTL'
net.ipv4.ip_unprivileged_port_start=80
SYSCTL
sysctl --system

# tinsnip identifies a box by its short hostname.
hostnamectl set-hostname "${hostname}"

echo "tinsnip box first boot complete" > /var/log/tinsnip-first-boot.done
