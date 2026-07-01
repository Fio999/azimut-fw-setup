#!/bin/bash
# Automated installation of software for Linux router (Debian 12)
# Components: nftables, BIND 9, Suricata

set -e # Stop script on any error

# Suricata version to build (change to actual if needed)
SURICATA_VERSION="8.0.5"
USERNAME_SUDO="admin" # Replace with the name of your user that needs to be added to sudo

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)."
   exit 1
fi

echo "=== Step 1: Preparing repositories and updating system ==="
# Removing cdrom from sources.list
sed -i '/cdrom/d' /etc/apt/sources.list
echo "CD-ROM removed from sources.list."

apt update && apt upgrade -y
apt install -y sudo curl git wget
usermod -aG sudo "$USERNAME_SUDO" || true

echo "=== Step 2: Checking basic network components ==="
# Disabling NetworkManager
systemctl --now mask NetworkManager

# Checking networking service (ifupdown)
if systemctl is-active --quiet networking; then
    echo "[OK] The networking.service is active."
else
    echo "[WARNING] The networking.service is not active or missing."
fi

# Checking and installing nftables
if dpkg -l | grep -q nftables; then
    echo "[OK] nftables is already installed."
else
    echo "[INFO] nftables not found. Installing..."
    apt install -y nftables
    systemctl enable --now nftables
fi

echo "=== Step 3: Installation of BIND 9 ==="
apt install -y bind9 bind9-doc resolvconf

echo "=== Step 4: Preparing for Suricata build ==="
apt install -y autoconf automake build-essential cargo \
    cbindgen libjansson-dev libpcap-dev libpcre2-dev libtool \
    libyaml-dev make pkg-config rustc zlib1g-dev \
    libcap-ng-dev libmagic-dev liblz4-dev libunwind-dev

# Unattended installation of Rust
echo "Installing Rust (unattended)..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# Applying cargo environment for the current script session
source "$HOME/.cargo/env"

echo "=== Step 5: Building and Installing Suricata ==="
cd /usr/local/src
wget "https://www.openinfosecfoundation.org/download/suricata-${SURICATA_VERSION}.tar.gz"
tar xzvf "suricata-${SURICATA_VERSION}.tar.gz"
cd "suricata-${SURICATA_VERSION}"

./configure
make
make install-full
ldconfig # Updating library cache after installation

echo "=== Step 6: Configuring kernel parameters for routing ==="
# Enabling IP forwarding (net.ipv4.ip_forward=1)
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

echo "=== Step 7: Creating template /etc/network/interfaces ==="
# Creating a backup of the old file
cp /etc/network/interfaces /etc/network/interfaces.bak

# Warning: replace the values of address, netmask and gateway with the actual ones for your network!
cat <<EOF > /etc/network/interfaces
# Basic network interface configuration for the router
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# External network (WAN - static addressing)
auto eth0
iface eth0 inet static
    address 10.0.0.2       # Your IP address in the external (but local to you) network
    netmask 255.255.255.0  # Mask of the external subnet
    gateway 10.0.0.1       # IP address of the upstream router

# Internal network (LAN - static addressing)
auto eth1
iface eth1 inet static
    address 192.168.1.1    # IP address of our server in the isolated local network
    netmask 255.255.255.0
EOF

echo "=== Step 8: Configuring nftables (SNAT / Masquerading) ==="
cp /etc/nftables.conf /etc/nftables.conf.bak

# Usage of 'EOF' in braces prevents insertion of bash variables in block, 
# allowing the use of $ in nftables rules without escaping.
cat << 'EOF' > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

# Basic firewall ruleset for a Linux router with NAT (Masquerading)

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow loopback
        iif "lo" accept
        
        # Allow established and related connections
        ct state established,related accept
        
        # Drop invalid packets
        ct state invalid drop
        
        # Allow SSH connections for server management
        # REMOVE WHEN CONFIGURATION IS COMPLETE, OR RESTRICT TO SPECIFIC IPs
        tcp dport 22 accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
        
        # Allow forwarding of traffic from the internal network (eth1) to the external network (eth0)
        iifname "eth1" oifname "eth0" accept
        
        # Allow reply traffic from the internet back to the local network
        iifname "eth0" oifname "eth1" ct state established,related accept
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

# Network address translation (NAT) table
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        
        # Enable masquerading (SNAT) for all outgoing traffic through the external interface eth0
        oifname "eth0" masquerade
    }
}
EOF

# Restarting nftables to apply the new rules
systemctl restart nftables
echo "[OK] Firewall and NAT rules successfully applied."

echo "---"

echo "Installation completed! Basic NGFW components are ready."
echo "Please check and finalize the /etc/network/interfaces file before rebooting."
