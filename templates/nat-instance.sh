#!/bin/bash
# NAT instance (Amazon Linux 2023): forwards and masquerades only what comes from the VPC range; anything else that
# tries to cross it is dropped, and nothing on the instance itself accepts connections. Security updates install
# themselves every day.
set -euo pipefail

# Amazon Linux 2023 locks its repositories to the AMI's release; "latest" lets the daily updates reach new releases.
echo latest > /etc/dnf/vars/releasever
dnf install -y nftables dnf-automatic

echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-aedis-nat.conf
sysctl --system

iface="$(ip -4 route show default | awk '{print $5; exit}')"
cat > /etc/sysconfig/nftables.conf <<EOF
table ip aedis_nat {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    udp sport 67 udp dport 68 accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ip saddr ${vpc_cidr} oifname "$iface" accept
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    ip saddr ${vpc_cidr} oifname "$iface" masquerade
  }
}
EOF
systemctl enable --now nftables

sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer
