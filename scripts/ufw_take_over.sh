#!/bin/bash
# Make ufw the only host firewall on an Oracle Cloud Ubuntu box.
#
# Oracle's images ship /etc/iptables/rules.v4, loaded at boot by
# netfilter-persistent, whose INPUT rules sit ahead of ufw's chains and end
# in a REJECT, so ufw never sees a packet. This script:
#   1. carries Oracle's InstanceServices chain (outbound link-local
#      hardening) into /etc/ufw/before.rules,
#   2. optionally adds WireGuard hub forwarding and NAT to ufw,
#   3. disables netfilter-persistent and removes the stock rule files.
# It does NOT enable ufw or touch the live tables: converting a running
# box in place has locked us out before. Add ufw rules, then reboot; ufw
# comes up clean at boot. Safe to run at first boot from cloud-init.
#
# Usage: ufw_take_over.sh [--hub <wan-interface> <wg-subnet>]
set -euo pipefail
HUB_IF=""; WG_NET=""
if [ "${1:-}" = "--hub" ]; then HUB_IF="$2"; WG_NET="$3"; fi

BEFORE=/etc/ufw/before.rules
RULES=/etc/iptables/rules.v4
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p /root/firewall-backup-$TS
cp -a /etc/iptables /root/firewall-backup-$TS/ 2>/dev/null || true
cp -a $BEFORE /root/firewall-backup-$TS/

if [ -f "$RULES" ] && ! grep -q '^:InstanceServices' $BEFORE; then
  CHAIN=$(sed -n '/^-A InstanceServices/p' $RULES)
  python3 - "$CHAIN" <<'PY'
import sys
chain = sys.argv[1]
p = "/etc/ufw/before.rules"
s = open(p).read()
s = s.replace(":ufw-not-local - [0:0]\n", ":ufw-not-local - [0:0]\n:InstanceServices - [0:0]\n", 1)
block = ("\n# Oracle Cloud instance services: only these link-local destinations are\n"
         "# allowed; everything else to 169.254.0.0/16 is rejected. Carried over\n"
         "# from the stock /etc/iptables/rules.v4 so ufw owns the whole table.\n"
         "-A ufw-before-output -d 169.254.0.0/16 -j InstanceServices\n" + chain + "\n")
idx = s.rfind("\nCOMMIT")
s = s[:idx] + block + s[idx:]
open(p, "w").write(s)
PY
fi

if [ -n "$HUB_IF" ] && ! grep -q '^\*nat' $BEFORE; then
  # NAT for peers that use the hub as their exit; must precede the *filter block.
  python3 - "$HUB_IF" "$WG_NET" <<'PY'
import sys
wan, net = sys.argv[1], sys.argv[2]
p = "/etc/ufw/before.rules"
s = open(p).read()
nat = ("# WireGuard hub: masquerade peer traffic leaving via the WAN interface\n"
       "*nat\n:POSTROUTING ACCEPT [0:0]\n"
       f"-A POSTROUTING -s {net} -o {wan} -j MASQUERADE\nCOMMIT\n\n")
s = s.replace("*filter\n", nat + "*filter\n", 1)
open(p, "w").write(s)
PY
  sed -i 's|^#net/ipv4/ip_forward=1|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
  grep -q '^net/ipv4/ip_forward=1' /etc/ufw/sysctl.conf || echo 'net/ipv4/ip_forward=1' >> /etc/ufw/sysctl.conf
  ufw route allow in on wg0 comment 'wireguard hub forwarding' >/dev/null
fi

iptables-restore --test $BEFORE
systemctl disable netfilter-persistent >/dev/null 2>&1 || true
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
echo "ufw take-over prepared; backup in /root/firewall-backup-$TS. Enable ufw (if not already) and reboot."
