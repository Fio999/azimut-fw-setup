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
SURICATA_INTERFACE="enp0s3"        # External (WAN) interface
INTERNAL_INTERFACE="enp0s8"        # Internal (LAN) interface

USERNAME_SUDO="john"               # User to add to sudo group

PRIMARY_NAMESERVER="8.8.8.8"       # Temporary resolver used only during install
SECONDARY_NAMESERVER="1.1.1.1"     # Temporary resolver used only during install

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

# Local DNS zone served by BIND9 for the LAN. Clients using this router as
# their resolver will be able to resolve "<name>.$LOCAL_DOMAIN" to the IPs
# listed in LOCAL_DNS_RECORDS below. Everything else is forwarded upstream
# to PRIMARY_NAMESERVER/SECONDARY_NAMESERVER.
LOCAL_DOMAIN="lan.local"
# Add one "hostname:ip" entry per line for every host you want resolvable
# by name on the LAN. The router itself is included by default.
LOCAL_DNS_RECORDS=(
    "router:${LAN_ADDRESS}"
    # "nas:192.168.1.10"
    # "printer:192.168.1.20"
)
# NOTE: the reverse (PTR) zone generated below assumes a /24 LAN
# (255.255.255.0). If LAN_NETMASK is different, adjust REVERSE_ZONE
# generation in Step 3b manually.

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

echo "=== Step 0: Verifying required network interfaces are present ==="
# Must run before ANY changes are made - installing/removing NICs later is
# not possible, and every later step (routing, nftables, Suricata queue
# binding) assumes both interfaces already exist and are distinct.
MISSING_IFACE=0
 
if [[ "$SURICATA_INTERFACE" == "$INTERNAL_INTERFACE" ]]; then
    echo "[ERROR] SURICATA_INTERFACE and INTERNAL_INTERFACE are set to the"
    echo "        same value ('$SURICATA_INTERFACE'). They must be two"
    echo "        distinct physical/virtual NICs. Fix the CONFIGURATION"
    echo "        block at the top of this script."
    MISSING_IFACE=1
fi
 
for IFACE in "$SURICATA_INTERFACE" "$INTERNAL_INTERFACE"; do
    if [[ -d "/sys/class/net/$IFACE" ]]; then
        echo "[OK] Interface '$IFACE' found."
    else
        echo "[ERROR] Interface '$IFACE' not found on this system."
        MISSING_IFACE=1
    fi
done
 
if [[ "$MISSING_IFACE" -eq 1 ]]; then
    echo ""
    echo "Available network interfaces on this system:"
    ip -o link show | awk -F': ' '{print "  - "$2}' | grep -v '^  - lo$'
    echo ""
    echo "Update SURICATA_INTERFACE / INTERNAL_INTERFACE in the CONFIGURATION"
    echo "block to match real interface names, then re-run this script."
    echo "(Common causes: predictable naming like enp0s3/enp1s0 instead of"
    echo "eth0/eth1, a missing/disconnected second NIC, or a NIC not yet"
    echo "recognized because a driver/module isn't loaded.)"
    exit 1
fi
 
# Count physical/virtual NICs excluding loopback, to catch the case where
# only one interface exists at all (e.g. single-NIC VM or bare install)
NIC_COUNT="$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | wc -l)"
if [[ "$NIC_COUNT" -lt 2 ]]; then
    echo "[ERROR] Only $NIC_COUNT non-loopback network interface(s) detected"
    echo "        on this system, but a router setup requires at least two"
    echo "        (WAN + LAN). Add a second NIC (physical or virtual) before"
    echo "        continuing."
    exit 1
fi
echo "[OK] At least two network interfaces are present ($NIC_COUNT detected)."
 
echo ""
echo "=== Step 0b: Verifying sudo target user exists ==="
if id -u "$USERNAME_SUDO" &>/dev/null; then
    echo "[OK] User '$USERNAME_SUDO' exists and will be added to the sudo group."
else
    echo "[WARNING] User '$USERNAME_SUDO' does not exist on this system yet."
    echo "          Step 1 will skip adding it to the sudo group; you can"
    echo "          create the account and run 'usermod -aG sudo $USERNAME_SUDO'"
    echo "          manually afterwards, or fix USERNAME_SUDO in the"
    echo "          CONFIGURATION block and re-run this script."
    read -r -p "Continue anyway without a valid sudo user? [y/N] " CONFIRM_USER
    if [[ ! "$CONFIRM_USER" =~ ^[Yy]$ ]]; then
        echo "Aborted by user."
        exit 1
    fi
fi
 
echo ""
echo "=== Step 0c: Verifying configured DNS servers are reachable ==="
# These resolvers are relied on for apt/curl/wget throughout the rest of
# the script (Step 3 points resolv.conf at them). If neither is reachable
# now, every later network-dependent step will fail, so check up front.
DNS_OK=0
for DNS_IP in "$PRIMARY_NAMESERVER" "$SECONDARY_NAMESERVER"; do
    if timeout 3 bash -c "echo > /dev/udp/${DNS_IP}/53" 2>/dev/null; then
        echo "[OK] DNS server $DNS_IP is reachable on port 53/udp."
        DNS_OK=1
    elif ping -c 2 -W 2 "$DNS_IP" &>/dev/null; then
        echo "[OK] DNS server $DNS_IP responds to ping (port 53 reachability"
        echo "     could not be confirmed directly, but host is up)."
        DNS_OK=1
    else
        echo "[WARNING] DNS server $DNS_IP is not reachable (no response to"
        echo "          UDP/53 probe or ping)."
    fi
done
 
if [[ "$DNS_OK" -eq 0 ]]; then
    echo "[ERROR] Neither PRIMARY_NAMESERVER ($PRIMARY_NAMESERVER) nor"
    echo "        SECONDARY_NAMESERVER ($SECONDARY_NAMESERVER) is reachable."
    echo "        apt update, package downloads, and the Suricata/Rust"
    echo "        download steps will fail without working DNS/internet"
    echo "        access. Check WAN connectivity, or update these variables"
    echo "        in the CONFIGURATION block to resolvers reachable from"
    echo "        this network, then re-run."
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
apt install -y bind9 bind9-doc bind9-utils bind9-dnsutils resolvconf

echo "[INFO] Setting temporary public resolvers to continue script execution..."
mkdir -p /etc/resolvconf/resolv.conf.d
echo "nameserver ${PRIMARY_NAMESERVER}" > /etc/resolvconf/resolv.conf.d/head
echo "nameserver ${SECONDARY_NAMESERVER}" >> /etc/resolvconf/resolv.conf.d/head
resolvconf -u
sleep 2
echo "[OK] Temporary name resolution active."

echo "=== Step 3b: Configuring BIND9 local zone (${LOCAL_DOMAIN}) ==="
# Only /24 LAN netmasks are handled automatically for the reverse zone.
if [[ "$LAN_NETMASK" != "255.255.255.0" ]]; then
    echo "[WARNING] LAN_NETMASK is $LAN_NETMASK, not 255.255.255.0. The"
    echo "          reverse (PTR) zone generated below assumes a /24 and"
    echo "          will likely be WRONG. Adjust it manually afterwards."
fi
 
IFS='.' read -r OCT1 OCT2 OCT3 OCT4 <<< "$LAN_ADDRESS"
LAN_SUBNET="${OCT1}.${OCT2}.${OCT3}.0/24"
REVERSE_ZONE="${OCT3}.${OCT2}.${OCT1}.in-addr.arpa"
ZONE_SERIAL="$(date +%Y%m%d)01"
 
mkdir -p /etc/bind
[[ -f /etc/bind/named.conf.options ]] && cp /etc/bind/named.conf.options /etc/bind/named.conf.options.bak
[[ -f /etc/bind/named.conf.local ]] && cp /etc/bind/named.conf.local /etc/bind/named.conf.local.bak
 
# named.conf.options: forward everything not covered by our local zone to
# the configured upstream resolvers, and only answer LAN clients.
cat <<EOF > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
 
    // Only resolve for the LAN and the router itself.
    listen-on { 127.0.0.1; ${LAN_ADDRESS}; };
    allow-query { localhost; ${LAN_SUBNET}; };
    allow-recursion { localhost; ${LAN_SUBNET}; };
 
    // Anything outside our local zone is forwarded upstream.
    forwarders {
        ${PRIMARY_NAMESERVER};
        ${SECONDARY_NAMESERVER};
    };
    forward only;
 
    recursion yes;
    dnssec-validation auto;
    listen-on-v6 { none; };
};
EOF
 
# named.conf.local: declare the forward and reverse zones for the LAN.
cat <<EOF > /etc/bind/named.conf.local
zone "${LOCAL_DOMAIN}" {
    type master;
    file "/etc/bind/db.${LOCAL_DOMAIN}";
    allow-update { none; };
};
 
zone "${REVERSE_ZONE}" {
    type master;
    file "/etc/bind/db.${REVERSE_ZONE}";
    allow-update { none; };
};
EOF
 
# Forward zone file: A record per entry in LOCAL_DNS_RECORDS.
{
    echo "\$TTL    604800"
    echo "@       IN      SOA     router.${LOCAL_DOMAIN}. admin.${LOCAL_DOMAIN}. ("
    echo "                          ${ZONE_SERIAL}   ; Serial"
    echo "                             28800   ; Refresh"
    echo "                              7200   ; Retry"
    echo "                            604800   ; Expire"
    echo "                             86400 ) ; Negative Cache TTL"
    echo ";"
    echo "@       IN      NS      router.${LOCAL_DOMAIN}."
    echo "router  IN      A       ${LAN_ADDRESS}"
    for ENTRY in "${LOCAL_DNS_RECORDS[@]}"; do
        NAME="${ENTRY%%:*}"
        IP="${ENTRY##*:}"
        [[ "$NAME" == "router" ]] && continue # already added above
        echo "${NAME}    IN      A       ${IP}"
    done
} > "/etc/bind/db.${LOCAL_DOMAIN}"
 
# Reverse zone file: PTR record per entry in LOCAL_DNS_RECORDS.
{
    echo "\$TTL    604800"
    echo "@       IN      SOA     router.${LOCAL_DOMAIN}. admin.${LOCAL_DOMAIN}. ("
    echo "                          ${ZONE_SERIAL}   ; Serial"
    echo "                             28800   ; Refresh"
    echo "                              7200   ; Retry"
    echo "                            604800   ; Expire"
    echo "                             86400 ) ; Negative Cache TTL"
    echo ";"
    echo "@       IN      NS      router.${LOCAL_DOMAIN}."
    for ENTRY in "${LOCAL_DNS_RECORDS[@]}"; do
        NAME="${ENTRY%%:*}"
        IP="${ENTRY##*:}"
        LAST_OCTET="${IP##*.}"
        echo "${LAST_OCTET}    IN      PTR     ${NAME}.${LOCAL_DOMAIN}."
    done
} > "/etc/bind/db.${REVERSE_ZONE}"
 
chown -R bind:bind "/etc/bind/db.${LOCAL_DOMAIN}" "/etc/bind/db.${REVERSE_ZONE}"
 
# Validate configuration and zone files BEFORE restarting, so a mistake
# here doesn't take down a previously-working BIND9 instance.
CONFIG_VALID=1
named-checkconf /etc/bind/named.conf.options || CONFIG_VALID=0
named-checkconf /etc/bind/named.conf.local || CONFIG_VALID=0
named-checkzone "${LOCAL_DOMAIN}" "/etc/bind/db.${LOCAL_DOMAIN}" || CONFIG_VALID=0
named-checkzone "${REVERSE_ZONE}" "/etc/bind/db.${REVERSE_ZONE}" || CONFIG_VALID=0
 
if [[ "$CONFIG_VALID" -eq 1 ]]; then
    systemctl restart bind9
    sleep 1
    if dig @127.0.0.1 "router.${LOCAL_DOMAIN}" +short &>/dev/null && \
       [[ -n "$(dig @127.0.0.1 "router.${LOCAL_DOMAIN}" +short)" ]]; then
        echo "[OK] BIND9 local zone '${LOCAL_DOMAIN}' active; router.${LOCAL_DOMAIN} -> ${LAN_ADDRESS}"
    else
        echo "[WARNING] BIND9 restarted but did not answer a test query for"
        echo "          router.${LOCAL_DOMAIN}. Check 'journalctl -u bind9 -e'."
    fi
else
    echo "[ERROR] BIND9 configuration/zone check failed; NOT restarting bind9"
    echo "        to avoid breaking the existing service. Review the errors"
    echo "        above, fix /etc/bind/named.conf.* or the zone files, then"
    echo "        run 'named-checkconf' and 'systemctl restart bind9' manually."
fi
 
echo "[INFO] To add more LAN hosts later: edit LOCAL_DNS_RECORDS in this"
echo "       script's CONFIGURATION block and re-run Step 3b, or edit"
echo "       /etc/bind/db.${LOCAL_DOMAIN} and /etc/bind/db.${REVERSE_ZONE}"
echo "       directly, bump the Serial number, then 'systemctl reload bind9'."

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
# 'make install-full' (source build) does NOT install a systemd unit - only
# the Debian package (apt install suricata) does. Since we build from
# source, create the unit file ourselves rather than assuming one exists.
mkdir -p /var/log/suricata /var/lib/suricata /var/run/suricata

SURICATA_BIN="$(command -v suricata || echo /usr/local/bin/suricata)"

if systemctl list-unit-files | grep -q '^suricata\.service'; then
    # A suricata.service already exists (e.g. installed from a .deb
    # package previously) - override its ExecStart instead of replacing
    # the whole unit, so we don't clobber packaging-provided settings.
    echo "[INFO] Existing suricata.service detected; adding drop-in override."
    mkdir -p /etc/systemd/system/suricata.service.d
    cat <<EOF > /etc/systemd/system/suricata.service.d/override.conf
[Service]
ExecStart=
ExecStart=${SURICATA_BIN} -c /usr/local/etc/suricata/suricata.yaml -q 0 --pidfile /run/suricata/suricata.pid
EOF
else
    # No unit file at all (typical for a source build) - create one from
    # scratch so Suricata runs as a proper daemon and starts on boot.
    echo "[INFO] No suricata.service found; creating a new systemd unit."
    cat <<EOF > /etc/systemd/system/suricata.service
[Unit]
Description=Suricata IDS/IPS daemon (NFQUEUE mode)
Documentation=https://docs.suricata.io/
# Must come up after networking and after nftables has created the queue
# that Suricata attaches to; otherwise Suricata starts with nothing to read.
After=network-online.target nftables.service
Wants=network-online.target
Requires=nftables.service

[Service]
Type=simple
ExecStartPre=/usr/bin/env bash -c 'test -f /usr/local/etc/suricata/suricata.yaml'
ExecStart=${SURICATA_BIN} -c /usr/local/etc/suricata/suricata.yaml -q 0 --pidfile /run/suricata/suricata.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
RuntimeDirectory=suricata
RuntimeDirectoryMode=0755
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable suricata

if systemctl start suricata; then
    sleep 2
    if systemctl is-active --quiet suricata; then
        echo "[OK] Suricata started, enabled on boot, and running in IPS mode."
    else
        echo "[WARNING] Suricata reported start but is not active shortly after."
        echo "          Check 'systemctl status suricata' and 'journalctl -u suricata -e'."
    fi
else
    echo "[WARNING] Suricata failed to start. Check 'journalctl -u suricata -e' and"
    echo "          /usr/local/etc/suricata/suricata.yaml (HOME_NET, interface names, etc.)"
    echo "          before relying on the fail-open forward rules above."
fi

echo "=== Step 11: Switching DNS resolution to local BIND9 ==="
systemctl enable --now named
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
echo "  3. /usr/local/etc/suricata/suricata.yaml HOME_NET and interface settings match"
echo "     ${SURICATA_INTERFACE}/${INTERNAL_INTERFACE}."
echo "  4. Suricata is actually running (systemctl status suricata) before"
echo "     trusting the 'bypass' forward rules — otherwise traffic passes"
echo "     uninspected if Suricata is down."
echo "  5. BIND9 is resolving correctly for LAN clients (port 53 is now open"
echo "     only to ${INTERNAL_INTERFACE})."
