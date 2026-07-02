#!/bin/bash
# Automated installation of software for Linux router (Debian 12)
# Components: nftables, BIND 9, Suricata (IPS mode via NFQUEUE)
#
# IMPORTANT: Review ALL variables in the CONFIGURATION block below before running.
# This script will reconfigure networking and firewall rules on this host.
# Run in a console with physical/out-of-band access (not solely over SSH),
# in case a misconfiguration cuts off remote access.

set -euo pipefail # Stop on error, unset var use, or failed pipe

# ============================================================
# CONFIGURATION - edit these before running
# ============================================================
SURICATA_VERSION="7.0.16"          # Suricata version to build
SURICATA_INTERFACE="eth0"         # External (WAN) interface
INTERNAL_INTERFACE="eth1"         # Internal (LAN) interface

USERNAME_SUDO="admin"             # User to add to sudo group

PRIMARY_NAMESERVER="8.8.8.8"      # Temporary resolver used only during install
SECONDARY_NAMESERVER="1.1.1.1"    # Temporary resolver used only during install

MIN_RUST_VERSION="1.63.0"

# Real network addressing - YOU MUST SET THESE CORRECTLY FOR YOUR NETWORK
WAN_ADDRESS="10.0.0.2"
WAN_NETMASK="255.255.255.0"
WAN_GATEWAY="10.0.0.1"
LAN_ADDRESS="192.168.1.1"
LAN_NETMASK="255.255.255.0"

# Restrict SSH management access to this source (CIDR). Set to your admin
# workstation/LAN subnet, not 0.0.0.0/0.
SSH_ALLOWED_SOURCE="192.168.1.0/24"

# Suricata official download & checksum verification
SURICATA_TARBALL="suricata-${SURICATA_VERSION}.tar.gz"
SURICATA_URL="https://www.openinfosecfoundation.org/download/${SURICATA_TARBALL}"
SURICATA_SHA256_URL="${SURICATA_URL}.sha256"
# ============================================================

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (sudo)."
   exit 1
fi

# Simple confirmation gate since this rewrites networking/firewall
read -r -p "This will reconfigure networking, firewall and DNS on this host. Continue? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 1
fi

echo "=== Step 1: Preparing repositories and updating system ==="
sed -i '/cdrom/d' /etc/apt/sources.list
echo "CD-ROM removed from sources.list."

apt update && apt upgrade -y
apt install -y sudo curl git wget gnupg ca-certificates ifupdown
id -u "$USERNAME_SUDO" &>/dev/null && usermod -aG sudo "$USERNAME_SUDO" \
    || echo "[WARNING] User '$USERNAME_SUDO' does not exist, skipping sudo group add."

echo "=== Step 2: Checking basic network components ==="
# Disable NetworkManager if present (avoid conflict with ifupdown)
if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
    systemctl --now mask NetworkManager
fi

# Mask systemd-resolved to avoid conflicting with resolvconf/BIND9
if systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
    systemctl --now mask systemd-resolved
    echo "[OK] systemd-resolved masked to avoid DNS conflicts."
fi

if systemctl is-active --quiet networking; then
    echo "[OK] The networking.service is active."
else
    echo "[WARNING] The networking.service is not active or missing."
fi

if dpkg -s nftables &>/dev/null; then
    echo "[OK] nftables is already installed."
else
    echo "[INFO] nftables not found. Installing..."
    apt install -y nftables
fi
systemctl enable nftables

echo "=== Step 3: Installation of BIND 9 ==="
apt install -y bind9 bind9-doc resolvconf

echo "[INFO] Setting temporary public resolvers to continue script execution..."
mkdir -p /etc/resolvconf/resolv.conf.d
echo "nameserver ${PRIMARY_NAMESERVER}" > /etc/resolvconf/resolv.conf.d/head
echo "nameserver ${SECONDARY_NAMESERVER}" >> /etc/resolvconf/resolv.conf.d/head
resolvconf -u
sleep 2
echo "[OK] Temporary name resolution active."

echo "=== Step 4: Preparing for Suricata build ==="
apt install -y autoconf automake build-essential \
    cbindgen libjansson-dev libpcap-dev libpcre2-dev libtool \
    libyaml-dev make pkg-config zlib1g-dev \
    libcap-ng-dev libmagic-dev liblz4-dev libunwind-dev \
    libnetfilter-queue-dev libnfnetlink-dev python3-yaml \
    python3-setuptools

# --- Rust installation: try Debian backports first, fall back to rustup ---
# Some networks/providers block CDN of static.rust-lang.org (Fastly) 
# while leaving ICMP and the rest of the internet reachable, which
# breaks rustup. Backports uses the same deb.debian.org mirrors already 
# required for apt, so it's a more reliable first attempt; rustup remains as 
# a fallback for when backports doesn't carry a new-enough rustc.

version_ge() {
    # Returns success if $1 >= $2 (simple dotted version compare)
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

RUST_OK=0

if command -v rustc &>/dev/null; then
    CURRENT_VER="$(rustc --version | awk '{print $2}')"
    if version_ge "$CURRENT_VER" "$MIN_RUST_VERSION"; then
        echo "[OK] rustc $CURRENT_VER already installed and meets minimum version."
        RUST_OK=1
    fi
fi

if [[ "$RUST_OK" -eq 0 ]]; then
    echo "=== Attempting Rust install via Debian backports ==="
    DEBIAN_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    BACKPORTS_LINE="deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-backports main"

    if ! grep -qF "$BACKPORTS_LINE" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        echo "$BACKPORTS_LINE" > /etc/apt/sources.list.d/backports.list
        echo "[INFO] Added ${DEBIAN_CODENAME}-backports repository."
    fi

    apt update
    if apt install -y -t "${DEBIAN_CODENAME}-backports" rustc cargo; then
        CURRENT_VER="$(rustc --version | awk '{print $2}')"
        if version_ge "$CURRENT_VER" "$MIN_RUST_VERSION"; then
            echo "[OK] Installed rustc $CURRENT_VER from ${DEBIAN_CODENAME}-backports."
            RUST_OK=1
        else
            echo "[WARNING] ${DEBIAN_CODENAME}-backports only offers rustc $CURRENT_VER,"
            echo "          which is below the required $MIN_RUST_VERSION. Removing it"
            echo "          and falling back to rustup."
            apt remove -y rustc cargo
        fi
    else
        echo "[WARNING] rustc/cargo not available (or failed to install) from"
        echo "          ${DEBIAN_CODENAME}-backports. Falling back to rustup."
    fi
fi

if [[ "$RUST_OK" -eq 0 ]]; then
    echo "=== Falling back to rustup (unattended) ==="
    # Force IPv4 and bound the connect/overall time so a selectively-blocked
    # path fails fast instead of hanging for the default multi-minute
    # timeout; retry a couple of times in case of transient failures.
    if curl --proto '=https' --tlsv1.2 -4 --connect-timeout 10 --max-time 120 \
            --retry 2 --retry-delay 5 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh; then
        sh /tmp/rustup-init.sh -y
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
        RUST_OK=1
    else
        echo "[ERROR] rustup download failed (network to static.rust-lang.org"
        echo "        appears blocked). Options:"
        echo "          1. Download rust-${MIN_RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
        echo "             from a host with working access and scp it to"
        echo "             /usr/local/src on this machine, then run its"
        echo "             install.sh manually."
        echo "          2. Retry with an HTTPS proxy: https_proxy=http://<proxy>:<port>"
        echo "          3. Check whether ${DEBIAN_CODENAME}-backports carries a"
        echo "             newer rustc in the future and retry that path."
        exit 1
    fi
fi

if ! command -v rustc &>/dev/null; then
    echo "[ERROR] rustc still not on PATH after installation attempts. Aborting."
    exit 1
fi
echo "[OK] Using $(rustc --version)"

echo "=== Step 5: Downloading and verifying Suricata source ==="
mkdir -p /usr/local/src
cd /usr/local/src
wget -O "$SURICATA_TARBALL" "$SURICATA_URL"

# Verify checksum if the upstream checksum file is available
if wget -q -O "${SURICATA_TARBALL}.sha256" "$SURICATA_SHA256_URL"; then
    echo "$(cat "${SURICATA_TARBALL}.sha256")  $SURICATA_TARBALL" | sha256sum -c - \
        || { echo "[ERROR] Checksum verification failed. Aborting."; exit 1; }
    echo "[OK] Suricata tarball checksum verified."
else
    echo "[WARNING] Could not fetch checksum file; skipping verification."
    echo "          Verify $SURICATA_TARBALL manually before trusting this build."
fi

tar xzvf "$SURICATA_TARBALL"
cd "suricata-${SURICATA_VERSION}"

echo "=== Step 6: Building and installing Suricata (with NFQUEUE support) ==="
./configure --enable-nfqueue
make -j"$(nproc)"
make install-full
ldconfig

# Sanity check: confirm NFQUEUE support actually got compiled in
if ! /usr/local/bin/suricata --build-info | grep -qi "NFQUEUE"; then
    echo "[ERROR] Suricata was built WITHOUT NFQUEUE support. IPS mode will not work."
    echo "        Check that libnetfilter-queue-dev/libnfnetlink-dev were installed correctly."
    exit 1
fi
echo "[OK] Suricata built with NFQUEUE support."

echo "=== Step 7: Configuring kernel parameters for routing ==="
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

echo "=== Step 8: Creating /etc/network/interfaces ==="
if [[ -f /etc/network/interfaces && ! -f /etc/network/interfaces.bak ]]; then
    cp /etc/network/interfaces /etc/network/interfaces.bak
    echo "[OK] Backed up existing interfaces file to interfaces.bak."
else
    echo "[INFO] Backup already exists or no prior file found; not overwriting backup."
fi

cat <<EOF > /etc/network/interfaces
# Basic network interface configuration for the router
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# External network (WAN - static addressing)
auto ${SURICATA_INTERFACE}
iface ${SURICATA_INTERFACE} inet static
    address ${WAN_ADDRESS}
    netmask ${WAN_NETMASK}
    gateway ${WAN_GATEWAY}

# Internal network (LAN - static addressing)
auto ${INTERNAL_INTERFACE}
iface ${INTERNAL_INTERFACE} inet static
    address ${LAN_ADDRESS}
    netmask ${LAN_NETMASK}
EOF

echo "[INFO] Interfaces file written with configured addresses. It will NOT be"
echo "       applied automatically; review it, then run 'systemctl restart networking'"
echo "       or reboot when ready."

echo "=== Step 9: Configuring nftables (SNAT / Masquerading & IPS) ==="
if [[ -f /etc/nftables.conf ]]; then
    cp /etc/nftables.conf /etc/nftables.conf.bak
fi

cat << EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # Allow loopback
        iif "lo" accept

        # Allow established and related connections
        ct state established,related accept

        # Drop invalid packets
        ct state invalid drop

        # Allow SSH management only from the configured admin source.
        # Tighten SSH_ALLOWED_SOURCE at the top of this script before running.
        ip saddr ${SSH_ALLOWED_SOURCE} tcp dport 22 accept

        # Allow DNS queries from the internal network to this router (BIND9)
        iifname "${INTERNAL_INTERFACE}" udp dport 53 accept
        iifname "${INTERNAL_INTERFACE}" tcp dport 53 accept

        # Allow DHCP if this router also serves DHCP (uncomment if needed)
        # iifname "${INTERNAL_INTERFACE}" udp dport 67 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # IPS: send transit traffic on the external interface to Suricata (NFQUEUE 0)
        # NOTE: "bypass" means traffic is fail-open (passes uninspected) if
        # Suricata is not running. Remove "bypass" for fail-closed behavior
        # once you have verified Suricata is stable, so traffic is dropped
        # instead of passing uninspected if the IPS process is down.
        iifname "${SURICATA_INTERFACE}" counter queue num 0 bypass
        oifname "${SURICATA_INTERFACE}" counter queue num 0 bypass

        # Allow forwarding from the internal network to the external network
        iifname "${INTERNAL_INTERFACE}" oifname "${SURICATA_INTERFACE}" accept

        # Allow return traffic from the internet back to the LAN
        iifname "${SURICATA_INTERFACE}" oifname "${INTERNAL_INTERFACE}" ct state established,related accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;

        # Enable masquerading (SNAT) for outgoing traffic through the WAN interface
        oifname "${SURICATA_INTERFACE}" masquerade
    }
}
EOF

systemctl restart nftables
echo "[OK] Firewall and NAT rules successfully applied."

echo "=== Step 10: Configuring Suricata in IPS mode (NFQUEUE) ==="
mkdir -p /etc/systemd/system/suricata.service.d
cat <<EOF > /etc/systemd/system/suricata.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/local/bin/suricata -c /etc/suricata/suricata.yaml -q 0 --pidfile /run/suricata.pid
EOF

systemctl daemon-reload
systemctl enable suricata

if systemctl start suricata; then
    echo "[OK] Suricata started and enabled in IPS mode."
else
    echo "[WARNING] Suricata failed to start. Check 'journalctl -u suricata' and"
    echo "          /etc/suricata/suricata.yaml (HOME_NET, interface names, etc.)"
    echo "          before relying on the fail-open forward rules above."
fi

echo "=== Step 11: Switching DNS resolution to local BIND9 ==="
systemctl enable --now bind9
echo "nameserver 127.0.0.1" > /etc/resolvconf/resolv.conf.d/head
rm -f /etc/resolvconf/resolv.conf.d/head- 2>/dev/null || true
resolvconf -u
sleep 1
if host -W2 example.com 127.0.0.1 &>/dev/null; then
    echo "[OK] Local BIND9 resolver is answering queries; DNS switched to 127.0.0.1."
else
    echo "[WARNING] Local BIND9 did not answer a test query. Falling back to"
    echo "          public resolvers so the system doesn't lose DNS entirely."
    echo "nameserver ${PRIMARY_NAMESERVER}" > /etc/resolvconf/resolv.conf.d/head
    echo "nameserver ${SECONDARY_NAMESERVER}" >> /etc/resolvconf/resolv.conf.d/head
    resolvconf -u
    echo "          Fix BIND9 configuration, then re-run Step 11 manually."
fi

echo "---"
echo "Installation completed! Basic NGFW components are ready."
echo ""
echo "Before rebooting, please verify:"
echo "  1. /etc/network/interfaces has the CORRECT addressing for your network"
echo "     (WAN_ADDRESS/WAN_GATEWAY/LAN_ADDRESS at the top of this script)."
echo "  2. SSH_ALLOWED_SOURCE reflects your actual admin network, not 0.0.0.0/0."
echo "  3. /etc/suricata/suricata.yaml HOME_NET and interface settings match"
echo "     ${SURICATA_INTERFACE}/${INTERNAL_INTERFACE}."
echo "  4. Suricata is actually running (systemctl status suricata) before"
echo "     trusting the 'bypass' forward rules — otherwise traffic passes"
echo "     uninspected if Suricata is down."
echo "  5. BIND9 is resolving correctly for LAN clients (port 53 is now open"
echo "     only to ${INTERNAL_INTERFACE})."
