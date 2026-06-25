#!/bin/bash
#
# direct_link.sh — bring up an IPv4 link-local (169.254.0.0/16) direct cable
# connection and discover the peer on the other end. Symmetric: run the SAME
# script on BOTH machines (e.g. laptop <-> server, two desktops). Whichever box
# you then `ssh` FROM is the client; both ends run sshd so either direction works.
#
# Auto-detects: the cabled ethernet interface (carrier up), NetworkManager vs
# raw-ip fallback, sshd presence, own + peer link-local IPs.
#
# Usage:  sudo ./direct_link.sh            (root needed to configure the iface)
#         sudo ./direct_link.sh eth0       (optional: force a specific iface)
#
set -u

PROFILE="Direct-Link"
LL_BCAST="169.254.255.255"

usage() {
cat <<'EOF'
hardline / direct_link.sh — direct cable link between two machines.

USAGE
  sudo ./direct_link.sh [IFACE]     bring up link-local + discover the peer
       ./direct_link.sh --help      this help (no root needed)

  IFACE is optional; auto-detected as the cabled (carrier-up) physical NIC.

============================================================================
 ONE-TIME SERVER SETUP  —  do this ONCE, with physical access to the server.
 The apt steps need internet. A MULTI-NIC server (rack server with several
 RJ45 ports) keeps its uplink on one port and the direct cable on a SECOND
 port — both at once: it never goes offline, apt works anytime, and the
 gateway-less link-local on the direct port won't disturb its default route.
 Only a SINGLE-NIC box with no other uplink loses internet on the direct
 cable; there, install everything first.
 After this you only ever run direct_link.sh on the LAPTOP.
============================================================================

 1. SSH server (so the box accepts connections):
      sudo apt update && sudo apt install -y openssh-server
      sudo systemctl enable --now ssh

 2. mDNS — reach it as <hostname>.local instead of chasing IPs:
      sudo apt install -y avahi-daemon avahi-utils
      sudo systemctl enable --now avahi-daemon

 3. (optional) encrypted transfers:
      sudo apt install -y croc            # or: github.com/schollz/croc

 4. Persistent link-local on the direct-cable port, so the server
    self-configures the moment a cable is plugged in (no login needed).

    First find the port name you'll use for the direct cable:
      ip -o link show | awk -F': ' '{print $2}'      # e.g. enp3s0f1

    Then ONE of the following (use the real iface in place of ENP_X):

    a) netplan (Ubuntu Server default):
         sudo tee /etc/netplan/99-hardline.yaml >/dev/null <<'YAML'
         network:
           version: 2
           ethernets:
             ENP_X:
               dhcp4: no
               link-local: [ ipv4 ]
         YAML
         sudo chmod 600 /etc/netplan/99-hardline.yaml
         sudo netplan apply

    b) systemd-networkd:
         sudo tee /etc/systemd/network/20-hardline.network >/dev/null <<'NET'
         [Match]
         Name=ENP_X
         [Network]
         LinkLocalAddressing=ipv4
         DHCP=no
         NET
         sudo systemctl enable --now systemd-networkd

    c) NetworkManager:
         sudo nmcli connection add type ethernet con-name hardline \
              ifname ENP_X ipv4.method link-local ipv6.method ignore \
              autoconnect yes

 NB: IPv6 link-local (fe80::) is ALWAYS on with carrier — so once sshd (step 1)
 is running, the laptop can already reach the server over IPv6 even before
 step 4. Step 4 just gives you a stable IPv4 link-local + a clean setup.

============================================================================
 LAPTOP-ONLY USAGE  (after the server is prepped, or even a bare server)
============================================================================
  Normal:
      sudo ./direct_link.sh                 # brings up the wire, finds peer
      ssh <user>@<server-hostname>.local    # if avahi installed on server

  Aggressive (zero server IP config — needs only server sshd up):
      ping6 -c3 -I <IFACE> ff02::1          # server kernel replies; note fe80
      ssh <user>@fe80::....%<IFACE>         # %iface scope is required

WARNING
  Never enable DHCP/NAT "shared" mode on a NIC attached to a managed LAN —
  it hands out rogue leases and breaks that network. Direct-cable iface only.
EOF
}

case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

# --- 0. must be root to reconfigure interfaces -----------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "This needs root (it reconfigures a network interface)."
    echo "Re-run:  sudo $0 $*"
    exit 1
fi

log() { printf '%s\n' "$*"; }

# --- 1. pick the interface --------------------------------------------------
# Prefer an interface that (a) is physical ethernet, (b) has a cable (carrier=1).
# Exclude virtual/bridge/container interfaces that also start with 'e'/'v'.
is_physical() {
    local d=$1
    case "$d" in
        lo|docker*|veth*|br-*|virbr*|bond*|tun*|tap*|wg*|vmnet*|cni*|flannel*) return 1 ;;
    esac
    # must be a real device with a driver (filters most virtual ifaces)
    [ -e "/sys/class/net/$d/device" ] || return 1
    return 0
}

IFACE="${1:-}"
if [ -z "$IFACE" ]; then
    # first: a physical iface WITH carrier (cable plugged + link up)
    for p in /sys/class/net/*; do
        d=$(basename "$p")
        is_physical "$d" || continue
        if [ "$(cat "$p/carrier" 2>/dev/null)" = "1" ]; then
            IFACE="$d"; break
        fi
    done
    # fallback: first physical iface even if carrier not up yet
    if [ -z "$IFACE" ]; then
        for p in /sys/class/net/*; do
            d=$(basename "$p")
            is_physical "$d" || continue
            IFACE="$d"; break
        done
    fi
fi

if [ -z "$IFACE" ]; then
    log "ERROR: no physical ethernet interface found."
    exit 1
fi

CARRIER="$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)"
log "Host      : $(hostname)"
log "Interface : $IFACE (carrier=$CARRIER)"
[ "$CARRIER" != "1" ] && log "  NOTE: no carrier yet — is the cable plugged into BOTH ends with link lights on?"

# --- 2. bring up link-local: NetworkManager path, else raw-ip fallback ------
ip link set "$IFACE" up 2>/dev/null

if command -v nmcli >/dev/null 2>&1 && nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
    log "Method    : NetworkManager (nmcli)"
    nmcli connection add type ethernet con-name "$PROFILE" ifname "$IFACE" \
        ipv4.method link-local ipv6.method ignore 2>/dev/null \
        || nmcli connection modify "$PROFILE" ifname "$IFACE" \
               ipv4.method link-local ipv6.method ignore
    nmcli connection up "$PROFILE" >/dev/null 2>&1
else
    log "Method    : raw ip + avahi-autoipd fallback (NetworkManager not active)"
    if command -v avahi-autoipd >/dev/null 2>&1; then
        # avahi handles RFC3927 negotiation/conflict-defence; run detached
        pkill -f "avahi-autoipd.*$IFACE" 2>/dev/null
        avahi-autoipd -D "$IFACE" >/dev/null 2>&1 || true
    else
        # last resort: pick a pseudo-random 169.254.x.y (no conflict defence)
        OCT3=$(( (RANDOM % 254) + 1 )); OCT4=$(( (RANDOM % 254) + 1 ))
        ip addr add "169.254.$OCT3.$OCT4/16" dev "$IFACE" 2>/dev/null || true
        log "  WARN: avahi-autoipd absent — assigned 169.254.$OCT3.$OCT4 with NO conflict defence."
    fi
fi

# --- 3. wait for a link-local address to appear (poll, don't fixed-sleep) ---
own_ll() { ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -oE '169\.254\.[0-9]+\.[0-9]+' | head -n1; }
LOCAL_IP=""
for _ in $(seq 1 15); do
    LOCAL_IP="$(own_ll)"
    [ -n "$LOCAL_IP" ] && break
    sleep 1
done

if [ -z "$LOCAL_IP" ]; then
    log "ERROR: no 169.254.x.x address assigned after 15s. Check cable/link, then re-run."
    exit 1
fi
log "My IP     : $LOCAL_IP"

# --- 4. ensure sshd is running (so this box can ACCEPT connections) ---------
# NB: do NOT blind apt-install over the link — a direct cable has no internet.
SSH_UNIT=""
for u in ssh sshd; do
    systemctl list-unit-files 2>/dev/null | grep -q "^$u\.service" && { SSH_UNIT="$u"; break; }
done
if [ -n "$SSH_UNIT" ]; then
    if systemctl is-active --quiet "$SSH_UNIT"; then
        log "sshd      : active ($SSH_UNIT)"
    elif systemctl enable --now "$SSH_UNIT" >/dev/null 2>&1; then
        log "sshd      : started ($SSH_UNIT)"
    else
        log "sshd      : present but failed to start ($SSH_UNIT) — check 'systemctl status $SSH_UNIT'"
    fi
else
    log "sshd      : NOT INSTALLED. Install it BEFORE going offline:"
    log "            sudo apt update && sudo apt install -y openssh-server   (needs internet — do on a normal network first)"
fi

# --- 4b. ensure avahi (mDNS) — makes this box reachable as <hostname>.local --
# so you can `ssh host.local` instead of chasing the dynamic 169.254 address.
if systemctl list-unit-files 2>/dev/null | grep -q '^avahi-daemon\.service'; then
    systemctl is-active --quiet avahi-daemon || systemctl enable --now avahi-daemon >/dev/null 2>&1
    log "mDNS      : avahi active — this box is '$(hostname).local'"
else
    log "mDNS      : avahi-daemon not installed (optional, enables <host>.local):"
    log "            sudo apt install -y avahi-daemon avahi-utils   (do on a normal network first)"
fi

# --- 5. discover the peer on the wire ---------------------------------------
log "Scanning  : pinging link-local broadcast to populate ARP..."
ping -c 3 -W 1 -b -I "$IFACE" "$LL_BCAST" >/dev/null 2>&1
# also nudge with arp-scan if available (more reliable than broadcast ping)
command -v arp-scan >/dev/null 2>&1 && arp-scan -l -I "$IFACE" >/dev/null 2>&1

PEER_IP="$(ip neighbor show dev "$IFACE" 2>/dev/null \
            | grep -E '169\.254\.' \
            | grep -viE 'FAILED|INCOMPLETE' \
            | awk '{print $1}' | grep -v "^$LOCAL_IP$" | head -n1)"

# Prefer an mDNS name if we can resolve one (stable across IP changes).
PEER_NAME=""
if command -v avahi-resolve >/dev/null 2>&1 && [ -n "$PEER_IP" ]; then
    PEER_NAME="$(avahi-resolve -a "$PEER_IP" 2>/dev/null | awk '{print $2}' | head -n1)"
fi
# Fallback: browse the link for any host advertising SSH over mDNS.
if [ -z "$PEER_NAME" ] && command -v avahi-browse >/dev/null 2>&1; then
    PEER_NAME="$(avahi-browse -rtp _ssh._tcp 2>/dev/null \
                 | awk -F';' '/^=/{print $7}' \
                 | grep -v "^$(hostname).local$" | head -n1)"
fi
PEER_TARGET="${PEER_NAME:-$PEER_IP}"

echo "------------------------------------------------------------"
if [ -z "$PEER_IP" ] && [ -z "$PEER_NAME" ]; then
    log "Peer      : not detected yet."
    log "  - confirm the OTHER machine also ran this script (or has link-local up)"
    log "  - re-check later:  ip neighbor show dev $IFACE"
    log "  - watch live:      watch -n1 ip neighbor show dev $IFACE"
else
    log "Peer found: ${PEER_NAME:-$PEER_IP}${PEER_NAME:+  ($PEER_IP)}"
    log ""
    log "  Shell :  ssh <user>@$PEER_TARGET"
    log "  Files :  rsync -ahvz --progress /path/ <user>@$PEER_TARGET:/dest/"
    if command -v croc >/dev/null 2>&1; then
        log "  Send  :  croc send <file>            (encrypted, auto peer discovery)"
    else
        log "  Send  :  install 'croc' for easy encrypted transfers (github.com/schollz/croc)"
    fi
    log "  GUI   :  dual-pane file manager (Total Commander style) over SFTP —"
    log "           Double Commander / Krusader / muCommander → sftp://<user>@$PEER_TARGET"
    log "           or terminal:  mc  then  cd sh://<user>@$PEER_TARGET"
fi
log "  This box accepts:  ssh <user>@${PEER_NAME:+$(hostname).local or }$LOCAL_IP   (from the peer)"
echo "------------------------------------------------------------"
