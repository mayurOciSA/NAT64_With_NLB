#!/bin/bash
# Script to setup NAT66 Gateway onOracle Linux 9 Compute running on OCI

# Shell strict mode with logging
set -euo pipefail
set -x

# Core Technology: Uses only nftables and Linux kernel conntrack. Disable firewalld.
# Installation & Modules: Install nftables/conntrack-tools, load nf_conntrack/nf_nat.
# Dynamic Discovery: Detect primary interface and GUA IPv6 addresses dynamically.
# SNAT Pool Handling: Handle non-contiguous IPs and use kernel port exhaustion logic.
# NAT Logic: SNAT all ULA ingress traffic (fc00::/7) to the all GUA IPs of the host's primary interface.
# Conntrack Tuning: Table size 262144, TCP Idle 30m, UDP/ICMP 5m.
# Idempotency & Persistence: Script is re-runnable; configs should survive reboot(but not tested).
# Host Connectivity: Allow Host SSH, Ping (v4/v6), and Loopback.
# Traceroute Visibility: Allow TTL exceeded replies from Gateway.

echo ">>> Preparing System: Installing packages and disabling firewalld..."

# Install networking tools.
dnf install -y nftables conntrack-tools iproute python3

# Disable firewalld to prevent conflict with nftables
systemctl disable --now firewalld || true
systemctl mask firewalld || true

# Load kernel modules explicitly
modprobe nf_conntrack
modprobe nf_nat

# Persist modules
cat <<EOF > /etc/modules-load.d/nat66_modules.conf
nf_conntrack
nf_nat
EOF

echo ">>> Dynamic Discovery: Identifying Interface and IPs via Python..."

# Python script to generate a MAP for load balancing SNAT
PYTHON_DISCOVERY_SCRIPT=$(cat <<'EOF'
import json
import subprocess
import sys

def get_network_info():
    try:
        # Get default route interface
        cmd_route = ["ip", "-6", "-j", "route", "show", "default"]
        route_out = subprocess.check_output(cmd_route).decode("utf-8")
        routes = json.loads(route_out)
        
        if not routes:
            print("ERROR: No default IPv6 route found.", file=sys.stderr)
            sys.exit(1)
            
        primary_iface = routes[0]['dev']
        
        # Get addresses
        cmd_addr = ["ip", "-6", "-j", "addr", "show", "dev", primary_iface]
        addr_out = subprocess.check_output(cmd_addr).decode("utf-8")
        addrs = json.loads(addr_out)
        
        gua_list = []
        
        # Filter for Global Unicast (2000::/3)
        for iface in addrs:
            for addr_info in iface.get('addr_info', []):
                ip = addr_info['local']
                scope = addr_info['scope']
                if scope == 'global' and not addr_info.get('deprecated', False):
                    if not ip.lower().startswith('fc') and not ip.lower().startswith('fd'):
                        gua_list.append(ip)

        if not gua_list:
            print("ERROR: No Global IPv6 addresses found.", file=sys.stderr)
            sys.exit(1)

        # Output Primary Interface
        print(f"PRIMARY_IFACE='{primary_iface}'")
        
        # Generate SNAT Map for nftables
        # Format: { 0 : 2001:db8::1, 1 : 2001:db8::2 }
        # This allows us to use 'jhash mod N' to pick an IP.
        map_elements = []
        for index, ip in enumerate(gua_list):
            map_elements.append(f"{index} : {ip}")
        
        nft_map_str = ", ".join(map_elements)
        print(f"GUA_MAP='{nft_map_str}'")

        gua_list_str = ",".join(gua_list)
        print(f"GUA_IP_LIST='{gua_list_str}'")

        print(f"GUA_COUNT='{len(gua_list)}'")

    except Exception as e:
        print(f"Python Error: {e}", file=sys.stderr)
        sys.exit(1)

get_network_info()
EOF
)

eval "$(python3 -c "$PYTHON_DISCOVERY_SCRIPT")"

echo "Interface: $PRIMARY_IFACE"
echo "GUA Count: $GUA_COUNT"
echo "GUA IP List: $GUA_IP_LIST"
echo "GUA Map:   $GUA_MAP"

echo ">>> Conntrack Tuning & Persistence..."

cat <<EOF > /etc/sysctl.d/99-nat66-tuning.conf
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_icmpv6_timeout = 300
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
EOF

# Apply sysctl settings immediately
sysctl --system

# OCI VNICs have MTU of 9000. For internet traffic MTU is 1500.
# For internet bound traffic as OCI IGW itself replies with ICMPv6 Too Big messages for packets > 1500 bytes.
# But subnet SL for backend NAT66 NVA, does not allow ICMPv6 ingress. You can optionally enable it, as per this TF setup. You can optionally enable it.

# Assuming it is not enabled, we need to set MTU of primary interface to 1500 for MTU policing of internet bound traffic.
# This ensure PMTUD works for internet bound traffic from ULA clients. As NAT66 NVAs will respond with  ICMPv6 'Packets to Too Big' messages to ULA clients sending bigger packets.
ip link set dev "$PRIMARY_IFACE" mtu 1500 type ethernet 

# In all cases, ensure ULA client's VNICs don't block ICMPv6 'Packets to Too Big' messages, for internet bound traffic.
# This ensures PMTUD works for internet bound traffic from ULA clients.

echo ">>> Generating NFTables Ruleset..."

cat <<EOF > /etc/nftables/nat66.nft
#!/usr/sbin/nft -f

# Clear existing rules for idempotency
flush ruleset

table inet nat66_gateway {

    chain input {
        type filter hook input priority filter; policy drop;

        # [Req 9] Accept established/related traffic
        ct state established,related accept

        # [Req 9] Accept all Loopback traffic
        iifname "lo" accept

        # [Req 9] Accept ICMPv6 (Ping, ND, Router Advertisements, etc.)
        # Essential for IPv6 network operations, SLAAC, and host reachability.
        ip6 nexthdr icmpv6 accept

        # [Req 9] Accept ICMP (IPv4 Ping)
        ip protocol icmp accept

        # [Req 9] Accept SSH
        tcp dport 22 accept
        
        # [Req 10] Traceroute Visibility (Target Reached)
        # Allow UDP traceroute ports (standard range 33434-33524) destined to THIS host
        # so we can reply with "Port Unreachable" (Target Reached).
        udp dport 33434-33524 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        # [Req 9] Accept established/related forwarding
        ct state established,related accept

        # Allow forwarding from Internal ULA clients to anywhere
        # ULA Range: fc00::/7 (covers fc00 and fd00)
        ip6 saddr fc00::/7 accept
        
        # [Req 10] Traceroute Visibility (Transit)
        # We must allow UDP traceroute probes passing THROUGH the gateway
        # so they can eventually time out or reach destination.
        udp dport 33434-33524 accept
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # [Req 4 & 5] NAT Logic
        # SNAT all traffic from ULA (fc00::/7) going out the primary interface
        # to the detected GUAs of this nodes, 
        # load balanced in sticky manner as per jhash of (Source IP of your ULA clients + Destination GUA IP of Internet).
        # example for node with primary interface enp0s6 
        # and 2 GUAs assigned to it (2603:c020:400c:fb01:0:53a5:3798:7101 and 2603:c020:400c:fb01:0:4cef:a823:e101) -
        # ip6 saddr fc00::/7 oifname "enp0s6" \
        #   snat ip6 to jhash ip6 saddr . ip6 daddr mod 2 \
        #     map { 0 : 2603:c020:400c:fb01:0:53a5:3798:7101, 1 : 2603:c020:400c:fb01:0:4cef:a823:e101 }

        ip6 saddr fc00::/7 oifname "$PRIMARY_IFACE" \
            snat ip6 to jhash ip6 saddr . ip6 daddr mod $GUA_COUNT \
              map { $GUA_MAP }
          
    }
}
EOF

echo ">>> Applying and Enabling NFTables..."

# Load the ruleset
nft -f /etc/nftables/nat66.nft

# --- START: Conditional Backup and Persistence of default nftables config ---
NFT_CONFIG_FILE="/etc/sysconfig/nftables.conf"
NFT_BACKUP_FILE="${NFT_CONFIG_FILE}.orig.bak"

echo "Attempting to backup original $NFT_CONFIG_FILE..."
# Check if the original file exists AND the backup does NOT exist
if [ -f "$NFT_CONFIG_FILE" ] && [ ! -f "$NFT_BACKUP_FILE" ]; then
    cp "$NFT_CONFIG_FILE" "$NFT_BACKUP_FILE"
    echo "Original configuration backed up to $NFT_BACKUP_FILE"
else
    echo "Backup already exists or original file not found, skipping initial backup."
fi
# --- END: Conditional Backup and Persistence ---

# Save rules to system default location to ensure survival on reboot
# (On OL9, the service loads from /etc/sysconfig/nftables.conf usually, 
# but we can point the service to our file or include it).
# Best practice for OL9:
echo "include \"/etc/nftables/nat66.nft\"" > "$NFT_CONFIG_FILE"

# Enable and restart service
systemctl enable --now nftables

nft list ruleset

echo "=============================================================================="
echo ">>> CONFIGURATION COMPLETE"
echo "=============================================================================="
echo "Gateway Interface: $PRIMARY_IFACE (MTU 1500)"
echo "NAT Strategy:      jhash load balancing over $GUA_COUNT GUA IPv6s"
echo "GUA IP List:       $GUA_IP_LIST"
echo "NAT Pool of GUA IPv6s : $GUA_MAP"
echo ""
echo ">>> Verification Commands:"
echo "1. View Ruleset:          nft list ruleset"
echo "2. View Conntrack Table:  conntrack -L -f ipv6"
echo "=============================================================================="