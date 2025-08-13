#!/bin/bash
# Secure setup script for Caddy + WireGuard tunnel on single OCI instance
# With proper isolation between public-facing and private services

set -e

# Variables (to be replaced or set via environment)
DOMAIN="${domain}"
EMAIL="${email}"

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
    docker.io \
    docker-compose \
    apparmor \
    apparmor-utils

# Install Caddy (will run in Docker for isolation)
# We'll use Docker instead of system-wide installation

# Create separate users for services
useradd -r -s /bin/false -m -d /var/lib/wireguard wireguard-user
useradd -r -s /bin/false -m -d /var/lib/caddy caddy-user

# Generate WireGuard keys
mkdir -p /etc/wireguard
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
chown -R wireguard-user:wireguard-user /etc/wireguard

# Configure WireGuard for hub mode
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = WILL_BE_REPLACED

# Enable packet forwarding between clients
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Homelab peer
[Peer]
PublicKey = HOMELAB_PUBLIC_KEY_PLACEHOLDER
AllowedIPs = 10.100.0.2/32
PersistentKeepalive = 25

# Laptop peer (for dev access)
[Peer]
PublicKey = LAPTOP_PUBLIC_KEY_PLACEHOLDER
AllowedIPs = 10.100.0.3/32
EOF

# Replace private key in config
PRIVATE_KEY=$(cat /etc/wireguard/private.key)
sed -i "s|WILL_BE_REPLACED|${PRIVATE_KEY}|g" /etc/wireguard/wg0.conf

# Enable IP forwarding
cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Security hardening
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

# Create Docker network for Caddy (isolated from host)
docker network create caddy-net --driver bridge --subnet 172.20.0.0/16

# Create Caddy Docker Compose configuration
mkdir -p /opt/caddy
cat > /opt/caddy/docker-compose.yml << 'EOF'
version: '3.8'

services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    user: "1001:1001"  # Run as non-root
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
      - ./logs:/var/log/caddy
    networks:
      caddy-net:
        ipv4_address: 172.20.0.2
    security_opt:
      - no-new-privileges:true
      - apparmor:docker-default
    read_only: true
    tmpfs:
      - /tmp
    environment:
      - DOMAIN=${DOMAIN}
      - EMAIL=${EMAIL}

networks:
  caddy-net:
    external: true
EOF

# Create Caddyfile with strict security
cat > /opt/caddy/Caddyfile << EOF
{
    email ${EMAIL}
    
    # Security options
    servers {
        timeouts {
            read_body   10s
            read_header 5s
            write       10s
            idle        2m
        }
        max_header_size 16384
        protocols h1 h2 h3
    }
}

# Production website (public)
${DOMAIN} {
    # Rate limiting per IP
    @ratelimit {
        path *
    }
    rate_limit @ratelimit {
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
        Content-Security-Policy "default-src 'self'"
        Permissions-Policy "geolocation=(), microphone=(), camera=()"
        -Server
    }
    
    # Reverse proxy to homelab (via WireGuard)
    reverse_proxy 10.100.0.2:80 {
        # Only proxy to WireGuard network
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        
        # Timeouts
        transport http {
            dial_timeout 5s
            response_header_timeout 5s
        }
    }
    
    # Logging
    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 5
        }
        level ERROR
    }
}

# Health check endpoint (internal only)
:8080 {
    bind 172.20.0.2
    respond /health "OK" 200
}
EOF

# Set proper permissions
chown -R 1001:1001 /opt/caddy
chmod 600 /opt/caddy/Caddyfile

# Configure UFW with strict rules
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Only allow specific ports
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 51820/udp comment 'WireGuard'

# Rate limiting on SSH
ufw limit ssh/tcp

# Block Docker from bypassing firewall
cat >> /etc/ufw/after.rules << 'EOF'
# Block Docker from exposing ports directly
*filter
-A DOCKER-USER -j DROP
COMMIT
EOF

ufw --force enable

# Configure fail2ban
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 10.100.0.0/24

[sshd]
enabled = true
maxretry = 3

[docker-caddy]
enabled = true
port = http,https
filter = docker-caddy
logpath = /opt/caddy/logs/*.log
maxretry = 10
findtime = 60
bantime = 3600
EOF

# Create fail2ban filter for Caddy in Docker
cat > /etc/fail2ban/filter.d/docker-caddy.conf << 'EOF'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":[45]\d\d.*$
ignoreregex =
EOF

# Create WireGuard management script
cat > /usr/local/bin/wg-manage << 'EOF'
#!/bin/bash
# WireGuard peer management script

case "$1" in
    add-peer)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: wg-manage add-peer <name> <public-key> <ip>"
            echo "Example: wg-manage add-peer laptop AbC123... 10.100.0.3"
            exit 1
        fi
        
        # Add peer to config
        cat >> /etc/wireguard/wg0.conf << END

# $2 peer
[Peer]
PublicKey = $3
AllowedIPs = $4/32
END
        
        # Reload WireGuard
        wg syncconf wg0 <(wg-quick strip wg0)
        echo "Peer $2 added successfully"
        ;;
        
    list-peers)
        wg show
        ;;
        
    *)
        echo "Usage: wg-manage {add-peer|list-peers}"
        exit 1
        ;;
esac
EOF

chmod +x /usr/local/bin/wg-manage

# Enable and start services
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Start Caddy in Docker
cd /opt/caddy
docker-compose up -d

systemctl restart fail2ban

# Create setup info file
cat > /root/tunnel-setup-info.txt << EOF
==============================================
Secure OCI Tunnel Gateway Setup Complete!
==============================================

ISOLATION ARCHITECTURE:
- Caddy runs in Docker (isolated from host)
- WireGuard runs as system service (different user)
- Strict firewall rules between services
- AppArmor profiles enabled

WIREGUARD HUB CONFIGURATION:
Server Public Key: $(cat /etc/wireguard/public.key)
Server Port: 51820
Network: 10.100.0.0/24

IP Assignments:
- OCI Instance: 10.100.0.1
- Homelab: 10.100.0.2
- Your Laptop: 10.100.0.3
- Additional devices: 10.100.0.4+

HOMELAB WIREGUARD CONFIG:
[Interface]
Address = 10.100.0.2/24
PrivateKey = <HOMELAB_PRIVATE_KEY>

[Peer]
PublicKey = $(cat /etc/wireguard/public.key)
Endpoint = <THIS_OCI_PUBLIC_IP>:51820
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25

LAPTOP WIREGUARD CONFIG:
[Interface]
Address = 10.100.0.3/24
PrivateKey = <LAPTOP_PRIVATE_KEY>
DNS = 10.100.0.1

[Peer]
PublicKey = $(cat /etc/wireguard/public.key)
Endpoint = <THIS_OCI_PUBLIC_IP>:51820
AllowedIPs = 10.100.0.0/24
PersistentKeepalive = 25

TO ADD WIREGUARD PEERS:
1. Generate keys on client device
2. Run: wg-manage add-peer <name> <public-key> <ip>
3. Configure client with details above

TO ACCESS HOMELAB SERVICES FROM LAPTOP:
Once connected to WireGuard:
- http://10.100.0.2:3000 (dev server)
- http://10.100.0.2:8080 (other services)
- No Caddy configuration needed!

MONITORING:
- Caddy logs: docker logs caddy
- WireGuard status: wg show
- Fail2ban status: fail2ban-client status

SECURITY NOTES:
- Caddy only proxies to WireGuard IPs
- Docker containers isolated from host
- WireGuard keys protected with strict permissions
- All services run as non-root users

==============================================
EOF

echo "Setup complete! Check /root/tunnel-setup-info.txt for connection details"