#!/bin/bash
# WireGuard client setup for homelab (runs on your Synology/homelab)

set -e

# Variables - MUST BE CONFIGURED
OCI_PUBLIC_IP="${OCI_PUBLIC_IP:-YOUR_OCI_INSTANCE_IP}"
OCI_WG_PUBLIC_KEY="${OCI_WG_PUBLIC_KEY:-YOUR_OCI_WG_PUBKEY}"

echo "Setting up WireGuard client for homelab..."

# Install WireGuard (adjust for your OS)
# For Ubuntu/Debian:
apt-get update && apt-get install -y wireguard

# For Synology DSM 7+, install via Package Center or:
# See: https://github.com/runfalk/synology-wireguard

# Generate client keys
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

# Create WireGuard config
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.100.0.2/24
PrivateKey = $(cat /etc/wireguard/private.key)

# For routing all homelab services through tunnel:
PostUp = iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE

[Peer]
PublicKey = ${OCI_WG_PUBLIC_KEY}
Endpoint = ${OCI_PUBLIC_IP}:51820
AllowedIPs = 10.100.0.1/32
PersistentKeepalive = 25
EOF

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "==============================================="
echo "WireGuard Client Setup Complete!"
echo "==============================================="
echo ""
echo "Your Homelab WireGuard Public Key:"
cat /etc/wireguard/public.key
echo ""
echo "IMPORTANT: Add this public key to your OCI instance"
echo "Edit /etc/wireguard/wg0.conf on OCI and update the [Peer] section"
echo ""
echo "Test connection: ping 10.100.0.1"
echo "Check status: wg show"
echo "==============================================="

# Create systemd service for Docker containers to wait for WireGuard
cat > /etc/systemd/system/wait-for-wireguard.service << 'EOF'
[Unit]
Description=Wait for WireGuard tunnel
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'until ping -c1 10.100.0.1 &>/dev/null; do sleep 1; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wait-for-wireguard.service