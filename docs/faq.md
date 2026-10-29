# FAQ

- [Why not just the WireGuard app from the App Store?](#why-not-just-the-wireguard-app-from-the-app-store)
- [Why pf and not a Network Extension?](#why-pf-and-not-a-network-extension)
- [Will AirDrop or printing work?](#will-airdrop-or-printing-work)
- [How do captive portals work?](#how-do-captive-portals-work)
- [Can I use this on my internal disk?](#can-i-use-this-on-my-internal-disk)
- [What happens when the tunnel drops?](#what-happens-when-the-tunnel-drops)
- [Does my VPS see everything?](#does-my-vps-see-everything)
- [Can I use a commercial VPN endpoint instead of a VPS?](#can-i-use-a-commercial-vpn-endpoint-instead-of-a-vps)
- [Why no IPv6?](#why-no-ipv6)
- [Why unbound and not 1.1.1.1?](#why-unbound-and-not-1111)
- [How do I update macOS?](#how-do-i-update-macos)
- [Will macOS updates reset pf?](#will-macos-updates-reset-pf)
- [How do I add a second Mac?](#how-do-i-add-a-second-mac)
- [What about Time Machine and iCloud?](#what-about-time-machine-and-icloud)
- [Does it slow the connection?](#does-it-slow-the-connection)
- [My VPS got a new IP address. What now?](#my-vps-got-a-new-ip-address-what-now)

## Why not just the WireGuard app from the App Store?

The App Store app is a good WireGuard client, and if all you want is a tunnel, use it.
oneexit needs two things it does not provide: a firewall that is in place at boot,
before anyone logs in, that drops everything except the tunnel; and a tunnel managed by
the same root daemons that manage that firewall, so both can be restarted, checked and
scripted together. The command-line `wireguard-tools` and `wireguard-go` from Homebrew
fit that model.

## Why pf and not a Network Extension?

`pf` is the packet filter built into macOS. It needs no signed app, no developer
entitlements and no approval prompt in System Settings; it can be loaded by a launchd
daemon at boot; and its rules are plain text that you can read, test with
`pfctl -nvf`, and compare against [the exact rules in the contract](architecture.md).
A Network Extension filter would need a signed and notarised app with special
entitlements, a user approval step, and far more code to audit. For a policy as simple
as "one exit", pf is the smaller, more inspectable tool.

## Will AirDrop or printing work?

No. The firewall drops all local network traffic in both directions, so network
printers, AirDrop, AirPlay, file sharing, screen sharing and NAS access do not work
while it is locked. Printers connected by USB are not network traffic and are not
affected. If you need a local device briefly, `sudo oneexit unlock --minutes 5` allows
all traffic for that time and then locks again; remember that during those minutes
nothing is filtered.

## How do captive portals work?

A captive portal (hotel, café, airport Wi-Fi) blocks everything, including the
WireGuard handshake, until you accept terms on a web page. With the firewall locked,
that page cannot load. Run:

```bash
sudo oneexit portal
```

The tunnel goes down (while it is up, every packet is routed into it, so opening
ports alone would not help), DNS switches to the network's own resolver, and for
3 minutes (`--minutes N` to change it) the physical interface may also send TCP to
ports 80 and 443 and DNS to port 53, so the login page can load. Open it and log in.
When the time runs out, the daemons load the locked ruleset again, restore the tunnel
DNS and bring the tunnel back up by themselves; check with `oneexit status`.
`sudo oneexit lock` closes the window earlier. During the window, other apps can also
reach the web directly, so do the portal login first and nothing else.

## Can I use this on my internal disk?

`setup.sh` refuses by default and explains why: it checks the boot volume with
`diskutil info /` and stops if it is internal. You can override this with
`--allow-internal-disk`. Think about what that means first: your everyday system loses
all network access outside the tunnel, including printers, AirDrop and everything on
the local network, and when the server is down, the Mac is offline. To undo it, run
`sudo oneexit uninstall`.

The safeguard exists because the project is designed around a separate system on a
separate disk, and because a kill switch installed by mistake on your main Mac is an
unpleasant surprise.

## What happens when the tunnel drops?

Nothing leaks: the firewall still allows only DHCP and UDP to the server, so traffic
that would have gone through the tunnel is dropped and the Mac is offline. The tunnel
daemon checks the WireGuard handshake every 10 seconds; if the last handshake is older
than 180 seconds, or the Mac's default route moved to another interface (for example
after joining a different Wi-Fi network), it brings the tunnel down and up again. You
can do the same by hand with `sudo oneexit down` and `sudo oneexit up`.

## Does my VPS see everything?

It sees everything that leaves the tunnel: which hosts you connect to, when, and how
much data, plus the DNS queries unbound makes on your behalf. Content protected by
HTTPS or another end-to-end encryption stays encrypted. The provider also controls the
machine itself, including the stored client configs. That is the trade: instead of
trusting the local network and a commercial VPN, you trust one hosting company and
your own configuration. See the [threat model](threat-model.md).

## Can I use a commercial VPN endpoint instead of a VPS?

It is not supported or tested. `setup.sh` reads a standard wg-quick config, so a
commercial provider's WireGuard config with a single IPv4 endpoint might work, but
expect problems: many such configs include IPv6 addresses and `::/0`, which v1 does
not handle; the endpoint hostname is resolved only once at setup while providers rotate
server addresses; and the leak test's DNS check expects the resolver to answer from
your server's IP, so it will report `FAIL`. More importantly, it moves trust back to a
provider you do not control, which is what oneexit is designed to avoid.

## Why no IPv6?

To keep v1 simple and leak-free. The tunnel and the server are IPv4-only, so IPv6 is
turned off on every network service of the Mac and blocked in pf. Websites that are
IPv6-only will not load; in practice that is rare. Proper IPv6 support (an IPv6 subnet
on the server, `::/0` in the client config, IPv6 rules in pf) is a candidate for a
later version.

## Why unbound and not 1.1.1.1?

A public resolver sees every name you look up, tied to your server's IP. Running
`unbound` as a recursive resolver on the VPS means no single third party gets the full
list: unbound asks the root, TLD and authoritative servers itself, with QNAME
minimisation so each of them sees only the part of the name it needs, and validates
DNSSEC. It listens only on the tunnel address `10.66.0.1` and answers only
`10.66.0.0/24`, so it is not an open resolver. The trade-off is that the first lookup
of a name is slower than from a large shared cache.

## How do I update macOS?

Normally, through System Settings > General > Software Update. With oneexit running,
the download goes through the tunnel. After a major upgrade, run `oneexit doctor` and
`oneexit leak-test` to confirm everything is in place. Keep the SSD's macOS at least as
new as the macOS on the Macs you boot it on.

## Will macOS updates reset pf?

They can, and oneexit is built for that. macOS updates may rewrite `/etc/pf.conf`, which
is why oneexit never edits it. The rules live in their own anchor, `com.apple/oneexit`,
which the stock `/etc/pf.conf` includes through its `com.apple/*` anchor. The rules are
loaded at every boot by `oneexit-firewalld`, which also checks every 5 seconds that pf
is enabled and the anchor still has its rules, and reloads them if not. `oneexit
leak-test` checks the same thing.

## How do I add a second Mac?

Each device gets its own peer. On the server, from a clone of the repository:

```bash
sudo server/peer.sh add mac2
```

Copy the printed config to the second SSD and run `sudo client/setup.sh --config
mac2.conf` there. Do not reuse one config on two devices at the same time: WireGuard
identifies peers by key, and two devices with one key will keep displacing each other.

## What about Time Machine and iCloud?

Time Machine to a USB disk works. Time Machine to a network destination (a NAS or
another Mac on the local network) does not, because local network traffic is blocked.

iCloud would work through the tunnel, but signing in with your Apple ID ties this system
to you, which defeats much of the purpose. The recommendation is to leave iCloud off on
this system and keep files you need on the encrypted SSD or in a service you choose
deliberately.

## Does it slow the connection?

Some. Every packet travels to your VPS first, so latency grows by the round trip to the
server, and throughput is capped by the slower of your local network and the VPS's
connection. WireGuard's own overhead is small. A server in a nearby region keeps the
difference small for everyday browsing. The first DNS lookup of a name can take longer
than with a large public resolver, because unbound resolves it from scratch.

## How do I reach my VPS over SSH from the sealed Mac?

Through the tunnel: `ssh root@10.66.0.1` (or your admin user). The server's public
address is reachable from the Mac only on the WireGuard port, by design: wg-quick routes
that one address outside the tunnel (it is how the encrypted packets reach the server),
and pf lets only UDP to the WireGuard port take that path, so `ssh root@<public IP>`
simply times out. Using the tunnel address keeps SSH inside WireGuard and needs no
extra rule; make sure sshd on the server listens on all addresses or on `10.66.0.1`.

## My VPS got a new IP address. What now?

pf rules need an IP address, so `setup.sh` stores the server's IP at setup time, even
when the config uses a hostname. If the address changes, the firewall keeps allowing
only the old one and the Mac cannot connect. Remove oneexit while keeping the key, fix
the `Endpoint`, and set up again:

```bash
sudo client/uninstall.sh --keep-keys
# edit Endpoint in your copy of the config (or take the new one from the server)
sudo client/setup.sh --config mac.conf
```
