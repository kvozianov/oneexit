# The VPS

oneexit's only exit is a small Linux server that you rent. This page covers choosing
one, installing the server side, getting the client config to your Mac, adding more
devices, and the maintenance the installer leaves to you.

## Choosing a provider

oneexit does not recommend a provider. Any of the large European hosting companies
sells a suitable server. Check these points:

| Criterion | Why |
|---|---|
| **KVM virtualisation** (or any full VM), not OpenVZ/LXC containers | The installer uses the in-kernel WireGuard module (`wg-quick@wg0`). Container platforms share the host kernel and usually cannot load it. |
| **Debian 12 or Ubuntu 24.04** image | The only systems the installer supports and CI tests. |
| **A public IPv4 address included** | The Mac connects to an IPv4 endpoint and pf rules are written for one IPv4 address. Some cheap plans are IPv6-only. |
| **1 vCPU and 1 GB RAM** | Enough for WireGuard and unbound for a few devices. |
| **Location** | Websites will place you where the server is. An EU location close to where you usually are keeps latency low and avoids surprises with region-locked sites. |
| **Traffic allowance** | Check the monthly transfer included and what happens above it. All your traffic passes through this server. |
| **Price** | Around 3-5 EUR per month is typical for this size. |
| **Payment and account** | The provider knows who pays. If that matters to you, read the [threat model](threat-model.md) first: the provider can see all of your exit traffic regardless. |

Avoid providers that block or rate-limit UDP, and note whether the provider has its own
cloud firewall in the control panel (see [Hygiene](#hygiene-the-installer-does-not-do)).

## Create the server

1. If you do not have an SSH key yet, create one on the machine you will administer
   the server from:

   ```bash
   ssh-keygen -t ed25519 -C "oneexit-vps"
   cat ~/.ssh/id_ed25519.pub
   ```

2. In the provider's panel, create a server with Debian 12 or Ubuntu 24.04, paste the
   public key into the SSH key field, and do not set a root password if the panel lets
   you skip it.
3. Note the server's public IPv4 address.

## First login

```bash
ssh root@YOUR_VPS_IP
```

Some images log you in as a regular user (`debian`, `ubuntu`) instead of root; use that
name and `sudo`. Bring the system up to date first:

```bash
apt update && apt -y full-upgrade
reboot   # if a new kernel was installed
```

Minimal images may lack `curl` or `git`: `apt -y install curl git`.

## Install

Clone the repository, read the installer (it is plain bash), try the dry run, then install:

```bash
git clone https://github.com/kvozianov/oneexit.git
cd oneexit
less server/install.sh
sudo bash server/install.sh --dry-run
sudo bash server/install.sh
```

If you are logged in as root and `sudo` is not installed (common on Debian), drop
`sudo` from the commands. Options go after the script name:

```bash
sudo bash server/install.sh --port 443 --peer travel-mac
```

`install.sh [--port N] [--endpoint HOST_OR_IP] [--peer NAME] [--dry-run]`

| Option | Default | Meaning |
|---|---|---|
| `--port N` | `51820` | UDP port WireGuard listens on |
| `--endpoint HOST_OR_IP` | | Address written into client configs: the server's public IPv4, or a DNS name that points to it |
| `--peer NAME` | `mac` | Name of the first client |
| `--dry-run` | | Print every command and every file, change nothing |

### What install.sh does

1. Installs the packages `wireguard`, `wireguard-tools`, `unbound`, `nftables`, `dnsutils` and
   `qrencode` with the system package manager.
2. Generates the server key pair: `/etc/wireguard/server.key` and `server.pub`.
3. Writes `/etc/wireguard/wg0.conf` (mode 0600): interface `wg0`, address `10.66.0.1/24`,
   the listen port.
4. Enables IPv4 forwarding with `net.ipv4.ip_forward=1` in
   `/etc/sysctl.d/99-oneexit.conf`.
5. Writes nftables rules: NAT (masquerade) for `10.66.0.0/24` out of the default
   interface, and an `input` accept rule for the WireGuard UDP port.
6. Configures `unbound` to listen on `10.66.0.1` port 53 and answer only
   `10.66.0.0/24`, as a recursive resolver with no forwarders, DNSSEC validation on and
   `qname-minimisation: yes`.
7. Runs `systemctl enable --now wg-quick@wg0 unbound nftables`.
8. Creates the first peer (default name `mac`, address `10.66.0.2`), saves its config
   as `/etc/wireguard/peers/mac.conf` (mode 0600), and prints the config and a QR code.

Re-running `install.sh` is safe: it keeps the existing keys and peers.

The client config looks like this:

```
[Interface]
PrivateKey = <peer private key>
Address = 10.66.0.2/32
DNS = 10.66.0.1

[Peer]
PublicKey = <server public key>
Endpoint = <endpoint>:<port>
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

There is no IPv6 in it on purpose; see the [FAQ](faq.md#why-no-ipv6).

## Getting the config to the Mac

The config contains the peer's private key. Treat it like a password.

**Copy the file (recommended for a Mac).** Before running `client/setup.sh`, the Mac
still has normal network access. From the Mac, booted from the SSD:

```bash
scp root@YOUR_VPS_IP:/etc/wireguard/peers/mac.conf ./mac.conf
```

Alternatively, select the config text that `install.sh` printed in your SSH session,
paste it into a new file `mac.conf`, and check that nothing was cut off.

**The QR code.** The QR code is the same config as text. The iPhone Camera app or the
WireGuard app on a phone can read it, which is the easiest way to add a phone as its
own peer. It is not a convenient way to get the config onto the Mac; use the file.
Print the QR code again at any time:

```bash
sudo server/peer.sh qr mac
```

After `setup.sh` has installed the config, delete your local copy (`mac.conf`). The
server keeps its own copy in `/etc/wireguard/peers/`.

## More devices: peer.sh

Run these from a clone of the repository on the server:

```bash
sudo server/peer.sh add laptop2   # allocate the next address, save and print the config
sudo server/peer.sh qr laptop2    # print the config as a QR code
sudo server/peer.sh list          # list peers
sudo server/peer.sh revoke laptop2
```

Addresses are allocated in order from `10.66.0.2`. Use one peer per device: two devices
sharing one key will knock each other off the tunnel.

## Port 443

```bash
sudo server/install.sh --port 443
```

Some networks (hotels, conferences, corporate guest Wi-Fi) only let through a few
well-known ports. UDP 443 is used by HTTP/3 and QUIC, so it is open more often than
51820. This is only a different port number. It is **not** obfuscation: the traffic is
still recognisably WireGuard, and a network that inspects packets or blocks WireGuard
as a protocol will still block it. oneexit has no obfuscation in v1.

Choose the port at the first install. Changing it later means every client config,
and the pf rules on each Mac, must change with it.

## Hygiene the installer does not do

`install.sh` sets up the tunnel and DNS and nothing else. Do these once:

**Automatic security updates.**

```bash
apt -y install unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

**SSH: keys only.** First confirm in a second terminal that you can log in with your
key. Then:

```bash
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/00-no-passwords.conf
systemctl restart ssh
```

Keep your current session open and check from a new terminal that key login still
works before you close it. Debian 12 and Ubuntu 24.04 include `sshd_config.d/*.conf`
at the top of the main file, and for each setting sshd uses the first value it reads,
so this file overrides a `PasswordAuthentication yes` added by the image.

**The provider's firewall.** If the control panel has a firewall, it sits in front of
the server's own rules. Allow inbound UDP on the WireGuard port (51820 or the one you
chose) and TCP 22 for SSH, or the Mac will never complete a handshake.

**Backups.** The only state worth keeping is `/etc/wireguard/`. If the server is lost,
a fresh install with new keys and new client configs takes a few minutes.

## Costs and trust

Expect around 3-5 EUR per month for a server this size, more if you need a lot of
traffic. In return you get an exit that is not shared with thousands of other users
and a resolver that is not run by a third party.

Be clear about what that does not change: the provider controls the machine. It can see
all traffic leaving the tunnel (encrypted HTTPS content stays encrypted, but the
destinations do not), it can see the queries unbound sends to authoritative DNS
servers, and it has access to the disk, including the copies of client configs in
`/etc/wireguard/peers/`. If you suspect the server is compromised, revoke the peers,
destroy the server and install a new one. See the [threat model](threat-model.md).
