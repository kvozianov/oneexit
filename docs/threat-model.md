# Threat model

This page says what oneexit is meant to protect, from whom, by which mechanism, and
where it stops. If a statement here and the code disagree, the code is wrong; please
open an issue.

## What oneexit is

A macOS installation on an external SSD whose network access is restricted by `pf` to
one WireGuard tunnel to a server you control. The rules, the daemons that load them and
the leak test are described in [architecture.md](architecture.md).

## Assets

1. **Your real network location.** The public IP address of the network you are on, and
   what it reveals (city, venue, employer, home).
2. **What you do online, as seen from the network you are on.** Destinations, DNS names
   and traffic metadata visible to the Wi-Fi operator and the ISP.
3. **Your DNS queries.** Which names you resolve and when.
4. **The separation of this environment** from the host Mac's internal disk, from the
   local network, and from other devices on it.
5. **The WireGuard private key** of each Mac, which is what lets a device use your
   server.

## Adversaries considered

| Adversary | Capability | Goal |
|---|---|---|
| **Local network operator** (hotel, café, airport, campus, conference Wi-Fi) | Sees and can modify all traffic on the network; runs the DHCP server and the default DNS resolver; may run a captive portal | Log or profile visitors, inject content, sell data |
| **ISP or national network** | Sees all traffic leaving the local network; may filter | Logging, profiling, filtering by destination or DNS name |
| **Websites and online services** | See the source IP of each connection | Geolocate you by IP, link visits from the same network |
| **Opportunistic attackers on the LAN** | Same Wi-Fi: rogue access points, ARP or DHCP spoofing, mDNS probing, scanning for open services | Find and attack devices, learn device names and owners |

## What is protected, and how

Each leak class is closed by a specific mechanism, and most of them are checked by
`oneexit leak-test` (check numbers refer to the leak test contract in
[architecture.md](architecture.md#leak-test-contract-scriptsleak-testsh)).

| Leak class | What could go wrong | Mechanism | Checked by |
|---|---|---|---|
| Traffic outside the tunnel | An app sends traffic before the tunnel is up, while it is down, or after it fails | pf `block all`; on physical interfaces only DHCP and UDP to `VPS_IP:VPS_PORT` pass | 1, 3, 6 |
| Apps binding to the physical interface | Software that ignores the routing table and uses `en0` directly | Same rule: pf filters by interface and destination, not by route | 6 |
| IPv6 | Traffic goes out over IPv6, which the IPv4-only tunnel does not cover | IPv6 turned off on every network service (`networksetup -setv6off`) and `block quick inet6 all` in pf | 4 |
| DNS | Queries go to the network's resolver or a hard-coded public resolver | DNS of every network service set to `10.66.0.1`, which exists only inside the tunnel; UDP/TCP 53 to anything else is dropped; the resolver on the VPS is recursive, so no third-party resolver sees the queries either | 5 |
| Bonjour / mDNS | The Mac announces its name and services to the local network | pf drops all non-tunnel traffic on physical interfaces, including multicast DNS | 7 (sanity check only) |
| AirDrop and peer-to-peer Wi-Fi | Discovery and transfers with nearby devices | Dropped by the same rules; AirDrop uses IPv6 link-local addresses, which are blocked | |
| Inbound connections from the LAN | Scans or connection attempts reach services on the Mac | `block all` applies in both directions; nothing inbound is allowed on physical interfaces except DHCP replies | |
| pf disabled or anchor flushed | macOS, another program, or a reload of `/etc/pf.conf` disables pf or removes the rules | `oneexit-firewalld` checks every 5 s that pf is enabled and the anchor has rules, and reloads them if not | 1 |
| Tunnel stalls after a network change | The tunnel looks up but no traffic flows | `oneexit-tunneld` checks the handshake every 10 s and restarts the tunnel if it is older than 180 s or the default route interface changed. While the tunnel is down, traffic is dropped, not leaked | 2 |
| Exceptions left open | A temporary opening is forgotten | `portal` and `unlock` write an expiry time; the firewall daemon reloads the locked ruleset when it passes | |
| Geolocation by IP | Websites place you at the network you are on | All traffic exits from the VPS address | 3 |

The kill switch fails closed: if the server is unreachable, the network blocks
WireGuard, or the tunnel daemon crashes, the Mac is offline, not exposed.

## What is not protected

Be clear about these before you rely on oneexit.

- **Your VPS provider.** It sees all traffic leaving the tunnel: destinations, timing,
  volume, and the content of anything not encrypted end to end. It sees the queries
  unbound sends to authoritative DNS servers. It has access to the server's disk,
  including the client configs (with private keys) in `/etc/wireguard/peers/`.
- **A compromised VPS.** Whoever controls the server has the same view as the provider
  and can also tamper with unencrypted traffic and DNS answers. DNSSEC validation
  happens on that server, so it does not help against it.
- **Your identity in accounts.** An Apple ID, iCloud, email, social networks and any
  other account you sign in to identify you directly. The IP address does not matter
  once you have logged in.
- **Browser fingerprinting.** Websites can recognise a browser by its configuration,
  fonts, screen and hardware characteristics, across IP addresses.
- **Traffic analysis and timing correlation.** An adversary that sees both your local
  network and your VPS's traffic can match them by timing and volume.
- **Censorship of WireGuard.** WireGuard is easy to identify on the wire and oneexit
  does no obfuscation. A network that blocks it leaves you offline. `--port 443`
  changes only the port number.
- **The boot window.** pf rules do not survive a reboot: pf is off until the first pass
  of `oneexit-firewalld`, which launchd starts early but with no ordering guarantee
  against Wi-Fi auto-join. If the Mac joins a known network first, a few seconds of early
  system traffic (mDNS, NTP, Apple push, the captive-portal probe) can leave with the
  network's real address before the anchor is loaded. To see how wide the window was on
  a given boot, compare the first timestamp in `/var/log/oneexit/firewall.log` with the
  network events in `log show --last boot`.
- **Reloads are fixed within 5 seconds, not instantly.** If something disables pf or
  flushes the anchor, traffic can flow unfiltered until the next watchdog check, up to
  about 5 seconds later.
- **The portal and unlock windows.** During `oneexit portal` (default 3 minutes) any app
  can reach any host on TCP 80/443 and DNS on port 53 directly. During `oneexit unlock`
  (default 10 minutes) everything is allowed.
- **Malware with root on the Mac.** Root can unload the daemons, rewrite the rules or
  read the private key. oneexit is a network policy, not malware protection.
- **Compromised Mac firmware or hardware.** The external system trusts the Mac it runs
  on. A Mac with tampered firmware, a hardware keylogger or a malicious peripheral can
  observe everything. On a borrowed Mac, you are trusting its owner.
- **Physical access to the SSD without FileVault.** Anyone who holds an unencrypted SSD
  can read everything on it, including the WireGuard key.
- **WebRTC and in-browser leaks.** The leak test prints a page to check by hand. Public
  traffic, including STUN, goes through the tunnel, but a browser may still expose
  local addresses to websites through WebRTC.

## Residual risks and mitigations

| Risk | Mitigation |
|---|---|
| Lost or stolen SSD | Turn on FileVault for the external volume ([install guide](install-macos-external.md)). If the SSD is lost, revoke its peer: `sudo server/peer.sh revoke NAME`. |
| Identity through Apple services | Do not sign in with an Apple ID or iCloud on this system. If you need the App Store, accept that Apple links this system to you. |
| Boot window | Turn Wi-Fi off (and unplug Ethernet) before you shut down, so the next boot does not join a network until you turn it on, by which time the firewall is loaded. Check with `oneexit status` before turning Wi-Fi on. To verify a past boot, compare the first line of `/var/log/oneexit/firewall.log` with `log show --last boot`. |
| Portal window | Open the captive portal page first, finish the login, and close the window early with `sudo oneexit lock` once the tunnel is up. Do not use other apps during the window. |
| Browser fingerprinting and cross-site tracking | Use a browser profile dedicated to this system, with no synced account, and sign in only where you need to. |
| Server compromise | Keep the server updated (unattended-upgrades), SSH with keys only ([vps.md](vps.md#hygiene-the-installer-does-not-do)). Rebuilding the server is cheap; do it if in doubt. |
| A key copied off the server | Each device has its own peer. Revoke a single peer without affecting the others. |

## What we deliberately did not do in v1

- **IPv6 inside the tunnel.** v1 turns IPv6 off on the Mac and blocks it in pf, and the
  server hands out no IPv6 addresses. This removes a whole class of leaks at the cost of
  no IPv6 connectivity. Adding it properly means an IPv6 subnet on the server, `::/0`
  in the client config and IPv6 rules in pf, and testing all of that.
- **`--allow-lan`.** No exception for printers, NAS or other local devices. The product
  is one exit; a LAN exception is also the most common way kill switches leak in
  practice.
- **Obfuscation.** No traffic shaping, no wrapping WireGuard in TLS or another protocol.
  It would add a large dependency and a different threat model.

## Reporting a security problem

If you find a way to get traffic out of a locked oneexit system other than through the
tunnel, please report it privately through GitHub's "Report a vulnerability" button on
the repository's Security tab, rather than in a public issue.
