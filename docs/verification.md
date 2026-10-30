# Verification log

What has actually been run, where, and what it showed. Numbers below are from the
runs themselves, not estimates.

## Continuous integration (every push)

| Job | Runner | What it proves |
|---|---|---|
| shellcheck 0.11 + `bash -n` | ubuntu | every script parses and is lint-clean |
| bats | ubuntu and macos | 92 unit tests: config rendering, pf rule text, parsers, dry runs of every installer with stubbed system tools |
| macOS dry run + pf syntax | macos | `client/setup.sh --dry-run`, `pfctl -nvf` on the locked, portal and unlocked rulesets, `plutil -lint` on the launchd plists, CLI smoke |
| server install | ubuntu | `server/install.sh` runs for real as root; `tests/server/integration.sh` then asserts `wg show`, the nftables tables, unbound on `10.66.0.1:53`, the systemd units, peer add / list / revoke and an idempotent second run (40 checks) |

## End-to-end run in a macOS virtual machine (2026-10-30)

Setup: a macOS 15.7 virtual machine (Virtualization.framework, Apple silicon host) as the
client; the oneexit server installed unmodified by `server/install.sh` in a privileged
Ubuntu 24.04 container with systemd on the same host, reachable from the VM on the
host's bridge address. Everything below was run inside the VM as root through the
hypervisor's guest agent, because the kill switch also blocks inbound SSH.

| Step | Result | Evidence |
|---|---|---|
| External-disk safeguard | pass | the VM disk reports `Device Location: Internal`; setup exits 1 with an explanation; `--allow-internal-disk` proceeds |
| Install | pass | `setup.sh` exit 0 in 34 s; Homebrew packages installed as the invoking user; 13 anchor rules loaded on `en0`, `en1` and the live `utunN`; DNS `10.66.0.1`; IPv6 off; both daemons running |
| Traffic through the tunnel | pass | 5,000,000-byte download: client `wg show` receive counter +5.34 MB, server `wg show wg0` sent 5.27 MiB; server-side `tcpdump -ni wg0` shows the VM's DNS queries answered by unbound |
| Leaks | pass | `curl --interface en0` fails; `curl -6` gets no IPv6 answer; a query to `1.1.1.1` leaves only inside the tunnel (seen on the server's `wg0`) |
| Kill switch | pass | `oneexit down`: direct traffic times out within 5 s; `pkill -9 wireguard-go`: tunnel back in 3 s |
| Watchdog | pass | anchor flushed by hand: rules back in 2 s; `pfctl -d`: pf re-enabled in 5 s; main ruleset reloaded without the `com.apple/*` hook: repaired in 4 s |
| Portal window | pass | tunnel down, DHCP resolver, `captive.apple.com/hotspot-detect.html` reachable directly, IPv6 still blocked; locked ruleset, tunnel DNS and tunnel back 13 s after expiry |
| Unlock window | pass | expiry and an early `oneexit lock` both restore the locked state |
| Reboot | pass | daemons spawned 9.4 s after kernel boot; locked ruleset in place 13.5 s before the router was known; direct traffic blocked, tunnel up |
| Uninstall, reinstall | pass | anchor empty, pf back to disabled, plists gone, DHCP DNS and automatic IPv6 restored, direct traffic works; a second `setup.sh` run installs again cleanly |

Bugs found by this run and fixed in v0.1.1: a daemon restart killed the tunnel (launchd
killed the whole process group); the direct-interface leak check passed even with pf wide
open (the kernel refused to route the bound socket before pf saw it); the IPv6 check
failed on every correct install (IPv4-mapped answers); `--expect-ip` was ignored by the
DNS check; `status` reported the public IP as unreachable; pfctl warnings flooded the log.

Lab-only effects, not oneexit behaviour: the container's exit address is the host's own
public IP, so the IPv4 check needs `--expect-ip`; the container host intercepts DNS, so
unbound could not recurse and the DNS resolver check fails there; TCP through the tunnel
needed a checksum fix on the container's `wg0` (`tc ... action csum`) because the
container runtime delivers packets with offloaded checksums.

## Not yet verified

- A physical Mac booted from an external SSD (Apple silicon or Intel): boot timing on real
  hardware, Wi-Fi association, sleep and wake, a real captive portal.
- A real VPS at a hosting provider (the server has only run in CI runners and containers).
- Long sessions: days of uptime, macOS updates while installed.
