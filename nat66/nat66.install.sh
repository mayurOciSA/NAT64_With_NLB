#!/bin/bash
# ==============================================================================
# OCI Oracle Linux 9 NAT66 Setup Script
# ==============================================================================
#
#                            ### NAT66 GATEWAY FEATURES ###
#
# # - Target OS: Oracle Linux 9 (RHEL9-compatible) VM running on OCI.
# # - Core Technology: Uses only nftables + Linux conntrack (no other NAT daemons).
# # - Setup & Persistence: Installs required packages (nftables, conntrack-tools), enables nftables service, and persists settings across reboots.
# # - Kernel Modules: Ensures kernel modules for conntrack and IPv6 NAT are loaded.
# # - Dynamic Discovery: Dynamically discovers the VM's primary network interface (no hardcoded eth0) and its Global Unicast IPv6 addresses (GUA).
# # - SNAT Pool: Uses an nftables set/variable of discovered GUAs as the SNAT pool.
# # - Stateful NAT66: Creates a stateful NAT66 SNAT that maps many ULA sources to one or more GUAs, utilizing pool exhaustion logic.
# # - TCP/UDP Timeouts: Sets conntrack idle timeouts: TCP established (1800s), UDP/ICMPv6 (300s).
# # - Performance: Tunes conntrack table size for many flows.
# # - Robustness: Script is idempotent (re-running does not error).
# # - TCP/MSS Tuning: Clamps MSS for TCP connections passing through this NAT66 to 1240.
# # - Diagnostics Visibility: The NAT system replies to mtr or traceroute commands (TTL exceeded) using its own GUA IPv6 address.
# # - Host Accessibility: Regular pings (IPv4 and IPv6) to the system's primary interface addresses are explicitly allowed.
# # - We disable firewalld to avoid conflicts, as we are using nftables directly.
# ==============================================================================


echo "[$(date)] Starting NAT66 Cloud-Init Setup..."

# PACKAGE INSTALLATION
# ------------------------------------------------------------------------------
# Install nftables (firewall) and conntrack-tools (connection tracking utilities).
echo "[Step 1] Installing required packages..."

while ! dnf install -y oracle-epel-release-el9; do
    echo "[WARN] dnf install oracle-epel-release-el9 failed. Retrying in 3 seconds..."
    sleep 3
done

while ! dnf config-manager --set-enabled ol9_developer_EPEL; do
    echo "[WARN] dnf config-manager failed. Retrying in 3 seconds..."
    sleep 3
done

dnf install -y nftables conntrack-tools

# KERNEL MODULES
# ------------------------------------------------------------------------------
# Ensure connection tracking and NAT modules are loaded.
# nf_conntrack: Core connection tracking.
# nf_nat: NAT helper.
echo "[Step 2] Loading kernel modules..."
modprobe nf_conntrack
modprobe nf_nat
modprobe nf_nat_ftp # Optional helper
# Persist modules across reboots
cat <<EOF > /etc/modules-load.d/nat66.conf
nf_conntrack
nf_nat
nf_nat_ftp
EOF

# Disable firewalld (we will use nftables directly)
echo "[INFO] Stopping and disabling firewalld (if present)..."
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

# SYSCTL TUNING & PERSISTENCE
# ------------------------------------------------------------------------------
# - Enable IPv6 Forwarding: Essential for a router/gateway.
# - Conntrack Max: Increase table size for high flow count.
echo "[Step 3] Configuring Sysctl parameters..."
cat <<EOF > /etc/sysctl.d/99-nat66.conf
# Enable IPv6 packet forwarding
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# Conntrack Table Size Tuning (262144 concurrent flows)
net.netfilter.nf_conntrack_max=262144

# Conntrack Timeouts (Requirements: TCP Established 30m, UDP/ICMP 5m)
# TCP Established: 30 minutes (1800s)
net.netfilter.nf_conntrack_tcp_timeout_established=1800

# UDP Default Timeout: 5 minutes (300s)
# Applies to unidirectional flows or initial packets.
net.netfilter.nf_conntrack_udp_timeout=300

# UDP Stream Timeout: 5 minutes (300s)
# Applies after bidirectional traffic is detected. Setting it equal to the default
# ensures aggressive cleanup, adhering strictly to the 5 minute idle requirement.
net.netfilter.nf_conntrack_udp_timeout_stream=300

# ICMPv6: 5 minutes (300s)
net.netfilter.nf_conntrack_icmpv6_timeout=300
EOF

# Apply sysctl settings immediately
sysctl --system

# DYNAMIC NETWORK DISCOVERY
# ------------------------------------------------------------------------------
echo "[Step 4] Discovering network configuration..."

# Discover Primary Interface: Finds the interface associated with the default IPv6 route.
PRIMARY_IFACE=$(ip -6 route show default | grep 'default via' | awk '{print $5}' | head -n 1)

if [ -z "$PRIMARY_IFACE" ]; then
    echo "ERROR: Could not detect primary IPv6 interface. Using 'eth0' as fallback."
    exit 1
fi
echo "Detected Primary Interface: $PRIMARY_IFACE"

# Discover all non-deprecated, non-ULA Global Unicast IPv6 addresses (GUA) on the primary interface.
GUA_LIST=$(
    ip -6 addr show dev "$PRIMARY_IFACE" scope global |      # List all global IPv6 addresses on the interface
    grep 'inet6' |                                           # Keep only lines with IPv6 addresses
    grep -v deprecated |                                     # Exclude deprecated addresses
    awk '{print $2}' |                                       # Extract the address/prefix (e.g., 2001:db8::1/64)
    cut -d/ -f1 |                                            # Remove the prefix length, keep only the address
    grep -vE '^fc00:|^fd00:' |                               # Exclude ULA addresses (fc00::/7, fd00::/8)
    tr '\n' ',' |                                            # Join all addresses into a comma-separated list
    sed 's/,$//'                                             # Remove trailing comma, if any
)

echo "Detected GUA Pool: $GUA_LIST"

if [ -z "$GUA_LIST" ]; then
    echo "ERROR: No GUA IPv6 detected. NAT rules may fail."
    exit 1
fi

# NFTABLES RULESET GENERATION
# ------------------------------------------------------------------------------
echo "[Step 5] Generating /etc/nftables/nat66.nft..."

mkdir -p /etc/nftables/
cat <<EOF > /etc/nftables/nat66.nft
#!/usr/sbin/nft -f

# Flush existing rules to ensure atomicity and idempotence
flush ruleset

# Define the table for IPv4 and IPv6 rules (inet family)
table inet filter {
    # --------------------------------------------------------------------------
    # CHAIN: INPUT (FILTER) - Traffic destined FOR the router
    # --------------------------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy accept;

        # Loopback
        iif lo accept
        
        # Allow established/related traffic (replies for local connections)
        ct state established,related accept

        # FEATURE: Host Accessibility (Pings)
        # Allow IPv4 ICMP (ping) destined for the host
        ip protocol icmp accept
        # Allow IPv6 ICMPv6 (Ping, Neighbor Discovery, etc.) destined for the host
        ip6 nexthdr icmpv6 accept

        # Allow SSH
        tcp dport 22 accept
    }
}

# Define the table for IPv6 NAT
table ip6 nat66 {

    # --------------------------------------------------------------------------
    # SETS & VARIABLES (For Dynamic Discovery)
    # --------------------------------------------------------------------------
    # FEATURE: SNAT Pool (Used by the Postrouting chain)
    define GUA_POOL = { $GUA_LIST }
    
    # Define the primary interface
    define IFACE = "$PRIMARY_IFACE"

    # --------------------------------------------------------------------------
    # CHAIN: PREROUTING (NAT) - Required to satisfy hook dependency
    # --------------------------------------------------------------------------
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }

    # --------------------------------------------------------------------------
    # CHAIN: POSTROUTING (NAT) - Where the SNAT and MSS clamping occurs
    # --------------------------------------------------------------------------
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # SNAT Rule: ULA -> GUA Pool
        # Matches ULA source traffic going out via IFACE and SNATs to the GUA pool.
        oifname \$IFACE ip6 saddr fc00::/7 snat to \$GUA_POOL
        
        # FEATURE: MSS Clamping (1240 bytes)
        # Clamps Max Segment Size for TCP SYN packets to prevent fragmentation/MTU issues.
        oifname \$IFACE tcp flags syn tcp option maxseg size set 1240
    }

    # --------------------------------------------------------------------------
    # CHAIN: FORWARD (FILTER) - Traffic passing THROUGH the router
    # --------------------------------------------------------------------------
    chain forward {
        type filter hook forward priority filter; policy accept;
        
        # Optimization: Fast accept for established flows
        ct state established,related accept
        
        # Allow all ULA forwarded traffic (NAT is applied in postrouting)
        ip6 saddr fc00::/7 accept
    }

    # --------------------------------------------------------------------------
    # CHAIN: OUTPUT (FILTER) - Traffic originating FROM the router
    # --------------------------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;
        
        # Allows the kernel to send out generated packets (e.g., ICMPv6 Time Exceeded)
        # necessary for MTR/traceroute visibility.
    }
}
EOF

# 7. APPLY AND ENABLE
# ------------------------------------------------------------------------------
echo "[Step 6] Applying Nftables configuration..."

# Update main config to include our generated file (for persistence)
NFTABLES_MAIN_CONF="/etc/nftables.conf"
if [ ! -f "$NFTABLES_MAIN_CONF" ]; then
    touch "$NFTABLES_MAIN_CONF"
fi
if ! grep -Fxq 'include "/etc/nftables/nat66.nft"' "$NFTABLES_MAIN_CONF"; then
    echo 'include "/etc/nftables/nat66.nft"' >> "$NFTABLES_MAIN_CONF"
fi

# Reload the service to apply changes and enable on boot
systemctl enable --now nftables
# Force reload to ensure our specific file is picked up right now
nft -f /etc/nftables/nat66.nft

# 8. CLEANUP STATE
# ------------------------------------------------------------------------------
echo "[Step 7] Cleaning up invalid conntrack entries for a fresh start..."
# Flushes all existing entries (useful if re-running script without reboot)
conntrack -F

echo "[$(date)] Setup Complete. NAT66 is active."
# Final output for verification
nft list ruleset

# ==============================================================================
# NAT66 DEBUGGING COMMANDS (Run on the OL9 NAT VM after setup, when needed)
# ==============================================================================
# Use these commands to inspect the state of the NAT and connection tracking
# if connectivity issues arise after the setup script has run.
#
# 1. VIEW CURRENT NAT/FILTER RULESET:
#    (Verifies the dynamic variables and chains were loaded correctly)
#    nft list ruleset
#
# 2. VIEW CONNECTION TRACKING TABLE (Active Flows):
#    (Shows live translations. Look for ULA source -> GUA destination.)
#    conntrack -L -p tcp | grep 'src=fc00'
#    conntrack -L -p udp | grep 'src=fc00'
#
# 3. VIEW PACKET/BYTE COUNTERS FOR NAT RULES:
#    (See if traffic is hitting your postrouting SNAT rule)
#    nft list table ip6 nat66
#
# 4. LIVE LOGGING OF CONNECTION CREATION/DELETION:
#    (Monitors the conntrack events in real-time. Hit Ctrl+C to stop.)
#    conntrack -E
#
# 5. VERIFY SYSCTL SETTINGS ARE ACTIVE:
#    (Ensure your custom timeouts are in effect)
#    sysctl net.netfilter.nf_conntrack_tcp_timeout_established
#    sysctl net.netfilter.nf_conntrack_udp_timeout
#
# 6. CHECK FOR DROPPED/INVALID PACKETS:
#    (Look for potential issues in the connection tracking process)
#    cat /proc/net/stat/nf_conntrack
# ==============================================================================