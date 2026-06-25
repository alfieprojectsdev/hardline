# hardline

> *"There's a hardline out. ... It's an old exit."* — bring up a **direct cable link** between two machines, no network required.

`hardline` is a zero-config bootstrap for a **direct Ethernet connection** between two computers — laptop ↔ server, two desktops, whatever. Plug a cable between them, run the same script on both ends, and you get a working IPv4 link-local connection with the peer discovered for you. No router, no DHCP server, no Wi-Fi, no manual IP config.

It's the out-of-band escape hatch for when you can't trust (or don't have) the managed network: jack the two boxes straight together over copper and work.

## Why

Modern Linux *can* auto-assign a link-local address on a direct cable — but in practice you still end up: figuring out which NIC has the cable, forcing the interface up, hunting the peer's address, and remembering the syntax to connect. `hardline` does all of that in one command, symmetrically, on both ends.

## The stack

`hardline` is only the **transport bootstrap**. It pairs with standard tools for the rest:

```
  hardline           →  bring up the wire + find the peer
  mDNS (avahi)       →  reach the peer as  <host>.local  (no chasing IPs)
  ssh / rsync / croc →  shell + file transfer
  dual-pane FM       →  Total-Commander-style local ↔ remote over SFTP
```

## Quick start

On **both** machines, with the cable plugged in:

```bash
chmod +x direct_link.sh
sudo ./direct_link.sh
```

Output tells you the peer's address (and `.local` name if avahi is up), then prints ready-to-use commands. Whichever box you `ssh` *from* is the client — both run `sshd`, so either direction works.

Force a specific interface if needed:

```bash
sudo ./direct_link.sh eth0
```

## Total Commander over a cable

The original itch: a dual-pane (orthodox) file manager with **one pane local, one pane on the other machine**, over the direct link. You don't build it — point an off-the-shelf FM at the peer over SFTP:

| File manager | How |
|---|---|
| **Double Commander** | add an SFTP connection → `sftp://<user>@peer.local` |
| **Krusader** (KDE) | type `sftp://<user>@peer.local` in a panel (KIO) |
| **muCommander** | built-in SFTP connect |
| **Midnight Commander** (`mc`, terminal) | `cd sh://<user>@peer.local` (FISH VFS) |

So: `hardline` brings the wire up → `peer.local` resolves via mDNS → the FM gives you the two-pane view.

## How it works

1. **Picks the cabled NIC** — the physical interface with `carrier=1` (excludes `docker`/`veth`/`br-`/bridges/VPNs). Falls back to the first physical interface if no carrier yet.
2. **Brings up link-local** (`169.254.0.0/16`) via NetworkManager if it's running, else `avahi-autoipd` (RFC 3927 with conflict defence), else a pseudo-random address as a last resort.
3. **Waits** for the address to actually appear (polls, no blind sleep).
4. **Ensures `sshd`** is running so the box can accept connections. It will *not* try to install packages over the link — a direct cable has no internet.
5. **Ensures avahi** so the box is reachable as `<hostname>.local`.
6. **Discovers the peer** via broadcast ping + ARP, then prefers an mDNS name (`avahi-resolve` / browsing `_ssh._tcp`) over the raw address.

## Requirements

- Linux with `iproute2` (always present), `bash`, root for interface config.
- Optional but recommended:
  - `openssh-server` — to accept connections
  - `avahi-daemon` + `avahi-utils` — for `<host>.local` names
  - `arp-scan` — more reliable peer detection
  - `croc` — easy encrypted transfers ([schollz/croc](https://github.com/schollz/croc))

## Caveats

- **A multi-NIC machine stays online while link-local'd.** A rack server with several ports keeps its uplink (internet) on one port and the direct cable on another — both at once. The gateway-less link-local on the direct port doesn't touch the default route, so `apt` keeps working. Only a **single-NIC** box with no other uplink goes offline on the direct cable — there, install the optional tools first.
- Link-local addresses are dynamic; use the `.local` mDNS name for stable references.
- A direct point-to-point cable is physically trusted, but `sshd` is exposed on the link — fine for two boxes you own.
- This is a personal ops convenience tool, not a network framework. For persistent setups, a `systemd-networkd` profile + avahi is cleaner; for pure transfers, `croc` alone may be enough.

## License

MIT — see [LICENSE](LICENSE).
