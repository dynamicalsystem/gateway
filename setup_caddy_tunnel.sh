#!/bin/bash
# Setup script for Caddy + WireGuard tunnel on OCI Ubuntu instance
# This script will be run as user-data when the instance launches

set -e

# Variables (to be replaced or set via environment)
DOMAIN="${DOMAIN:-yourdomain.com}"
DEV_DOMAIN="${DEV_DOMAIN:-dev.yourdomain.com}"
ALLOWED_IP="${ALLOWED_IP:-YOUR_IP_HERE}"
HOMELAB_WG_PUBLIC_KEY="${HOMELAB_WG_PUBLIC_KEY:-YOUR_HOMELAB_WG_PUBKEY}"
EMAIL="${EMAIL:-your-email@example.com}"

# Update system
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y \
    wireguard \
    ufw \
    fail2ban \
    htop \
    net-tools \
    curl \
    wget \
    qrencode

# Install Caddy
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update
apt-get install -y caddy

# Generate WireGuard keys for OCI instance
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

# Configure WireGuard
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/private.key)

# Homelab peer
[Peer]
PublicKey = ${HOMELAB_WG_PUBLIC_KEY}
AllowedIPs = 10.100.0.2/32
PersistentKeepalive = 25
EOF

# Substitute variables in WireGuard config
PRIVATE_KEY=$(cat /etc/wireguard/private.key)
sed -i "s|\$(cat /etc/wireguard/private.key)|${PRIVATE_KEY}|g" /etc/wireguard/wg0.conf
sed -i "s|\${HOMELAB_WG_PUBLIC_KEY}|${HOMELAB_WG_PUBLIC_KEY}|g" /etc/wireguard/wg0.conf

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p

# Configure Caddy
cat > /etc/caddy/Caddyfile << EOF
{
    email ${EMAIL}
    
    # Global options
    servers {
        timeouts {
            read_body   10s
            read_header 5s
            write       10s
            idle        2m
        }
        max_header_size 16384
    }
    
    # Rate limiting
    order rate_limit before basicauth
}

# Production website
${DOMAIN} {
    # Rate limiting
    rate_limit {
        zone dynamic {
            key {remote_host}
            events 100
            window 60s
        }
    }
    
    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    
    # Reverse proxy to homelab
    reverse_proxy 10.100.0.2:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        
        # Health check
        health_uri /health
        health_interval 30s
        health_timeout 5s
    }
    
    # Logging
    log {
        output file /var/log/caddy/production.log {
            roll_size 100mb
            roll_keep 5
            roll_keep_for 720h
        }
    }
}

# Development/test access (IP restricted)
${DEV_DOMAIN} {
    @allowed {
        remote_ip ${ALLOWED_IP}
    }
    
    handle @allowed {
        reverse_proxy 10.100.0.2:3000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
        }
    }
    
    # Block non-allowed IPs
    respond "Access Denied" 403
    
    log {
        output file /var/log/caddy/dev.log
    }
}

# Additional dev services (add more as needed)
# service1.${DEV_DOMAIN} {
#     @allowed {
#         remote_ip ${ALLOWED_IP}
#     }
#     handle @allowed {
#         reverse_proxy 10.100.0.2:3001
#     }
#     respond 403
# }
EOF

# Create log directory
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Configure UFW firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 51820/udp comment 'WireGuard'
ufw --force enable

# Configure fail2ban for Caddy
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[caddy-status]
enabled = true
port = http,https
filter = caddy-status
logpath = /var/log/caddy/*.log
maxretry = 10
findtime = 60
bantime = 3600

[caddy-4xx]
enabled = true
port = http,https
filter = caddy-4xx
logpath = /var/log/caddy/*.log
maxretry = 20
findtime = 60
bantime = 600
EOF

# Create fail2ban filters
cat > /etc/fail2ban/filter.d/caddy-status.conf << 'EOF'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":[45]\d\d.*$
ignoreregex =
EOF

cat > /etc/fail2ban/filter.d/caddy-4xx.conf << 'EOF'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":4\d\d.*$
ignoreregex =
EOF

# System tuning for DDoS protection
cat >> /etc/sysctl.conf << 'EOF'

# DDoS Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF

sysctl -p

# Enable and start services
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
systemctl restart caddy
systemctl restart fail2ban

# Create setup info file
cat > /root/tunnel-setup-info.txt << EOF
==============================================
OCI Tunnel Gateway Setup Complete!
==============================================

WireGuard Server Public Key:
$(cat /etc/wireguard/public.key)

WireGuard Port: 51820
WireGuard Network: 10.100.0.0/24
OCI Instance IP: 10.100.0.1
Homelab IP: 10.100.0.2

IMPORTANT - Configure your homelab WireGuard client:

[Interface]
Address = 10.100.0.2/24
PrivateKey = <YOUR_HOMELAB_PRIVATE_KEY>

[Peer]
PublicKey = $(cat /etc/wireguard/public.key)
Endpoint = <THIS_OCI_INSTANCE_PUBLIC_IP>:51820
AllowedIPs = 10.100.0.1/32
PersistentKeepalive = 25

Update DNS records:
- ${DOMAIN} → This OCI instance public IP
- ${DEV_DOMAIN} → This OCI instance public IP

To add more allowed IPs for dev access:
1. Edit /etc/caddy/Caddyfile
2. Update the @allowed block with additional IPs
3. Run: systemctl reload caddy

To monitor:
- Caddy logs: /var/log/caddy/
- WireGuard status: wg show
- Fail2ban status: fail2ban-client status

==============================================
EOF

echo "Setup complete! Check /root/tunnel-setup-info.txt for connection details"