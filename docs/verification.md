# Verification log

What has actually been run, where, and what it showed. Numbers below are from the
runs themselves, not estimates.

## Continuous integration (every push)

| Job | Runner | What it proves |
|---|---|---|
| shellcheck 0.11 + `bash -n` | ubuntu | every script parses and is lint-clean |
| bats | ubuntu and macos | 178 unit tests: config rendering, pf rule text, parsers, dry runs of every installer with stubbed system tools |
| macOS dry run + pf syntax | macos | `client/setup.sh --dry-run`, `oneexit init --dry-run`, `pfctl -nvf` on the locked, portal and unlocked rulesets, `plutil -lint` on the launchd plists, CLI smoke |
| server install | ubuntu | `server/install.sh` runs for real as root; `tests/server/integration.sh` then asserts `wg show`, the nftables tables, unbound on `10.66.0.1:53`, the systemd units, peer add / list / revoke and an idempotent second run (43 checks) |

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

## `oneexit init`, server half, against a container (2026-11-03)

Setup: the same kind of privileged Ubuntu 24.04 container with systemd as above, with sshd
on a forwarded port, a root login and a non-root login `ops` with passwordless sudo, key
logins only, time zone `Europe/Amsterdam`. Steps 1-3 of `oneexit init` (pre-flight, ssh
reachability, upload, remote `server/install.sh`, peer config fetch) were run for real from
a Mac through a harness that sources the client libraries and calls the step functions;
steps 4-6 (client setup, hardening, leak test) were not run because they change the Mac
they run on.

| Check | Result |
|---|---|
| `--server root@HOST:2222 --ssh-key KEY` | pass: login, server time zone read (`Europe/Amsterdam`, region `NL` derived), `server/` uploaded with ustar tar, `install.sh --endpoint HOST --port 51820 --peer mac --timezone Europe/Amsterdam` ran and installed WireGuard, unbound and nftables, peer config fetched into a mode-0600 temporary file with `# oneexit-timezone = Europe/Amsterdam` and `Endpoint = HOST:51820`; 41 s in all |
| `--server ops@HOST:2222` (non-root) | pass: `sudo -n` checked, every remote command prefixed with `sudo -n`, same result |
| Second run (idempotence) | pass: the server key, `wg0.conf` and the peer list were byte-identical before and after; `install.sh` reported "keeping the existing server key" and "peer mac already exists" |
| Server after the run | `wg-quick@wg0`, `unbound` and `oneexit-nft` active; `wg show wg0` listening on 51820 with the peer's allowed IP; one masquerade rule; `peer.sh list` shows the peer |
| Private keys in the output | the streamed installer output hides `PrivateKey` lines; the first peer's QR code was still printed by `install.sh` (fixed after this run: `init` now asks the installer for a quiet first peer) |

Lab-only: the container's outbound UDP was blocked by the container runtime during this
run, so the installer's DNS self-check warned (as designed, warning only) and unbound's
recursion could not be re-checked; it was checked on 2026-10-30.

## Bootstrap and hardening on a GitHub macOS runner (2026-11-03)

A manual workflow ([.github/workflows/macos-real.yml](../.github/workflows/macos-real.yml),
`workflow_dispatch` only) runs on a GitHub-hosted `macos-15` runner (macOS 15.8.2,
arm64, passwordless sudo, no tunnel). Final run: 124 PASS, 0 FAIL, 15 INFO over 139 checks.

| Check | Result |
|---|---|
| README one-liner (`install.sh` from `bash -c`) | pass: tarball of the pinned release downloaded, SHA-256 verified, unpacked to `/usr/local/share/oneexit/<version>` (root:wheel), `/usr/local/bin/oneexit` symlink chain resolves, `oneexit version` prints the pinned version |
| `harden --timezone Europe/Berlin --region DE` | pass: `/etc/localtime` → `Europe/Berlin`, `date +%Z` CET, automatic time zone 1 → 0, Location Services 1 → 0 at the path privacy.sh writes and as read with `defaults -currentHost`, as CoreLocation reports it and as locationd logged at its restart; ComputerName / HostName / LocalHostName → `Mac`; `AppleLocale` en_US → en_DE, `AppleLanguages` en-US → en; WebRTC policy written for Chrome, Brave, Edge, Chromium; Firefox `policies.json` written; Lookup and Safari suggestions off; state file mode 0600 root; `status` shows `privacy: hardened` |
| Leak test checks 9-12 | pass (time zone, Location Services, computer name, region), read from `--json`; checks 1-8 fail as expected without a tunnel |
| `unharden` | pass: every value back to the baseline, including settings that were absent before (absent again); state file removed; `status` shows `off` |
| Idempotence | pass: a second `harden` reads the zone and region from the config, a third prints "keeping" and leaves the state file byte-identical, a second `unharden` restores the baseline again, `unharden` with nothing to do exits 0 |

Bug found by this run and fixed in v0.2.2: the runner's zone was UTC (`/etc/localtime` →
`zoneinfo/UTC`), `systemsetup -gettimezone` reported it as `GMT`, so `harden` recorded
`GMT` and `unharden` moved the Mac to the GMT zone; `systemsetup -settimezone UTC` is
refused outright. The recorded zone now comes from the `/etc/localtime` link, and a zone
that `systemsetup` refuses but the zone database has is set by linking `/etc/localtime`
and posting `com.apple.system.timezone`.

Runner-specific, documented in the workflow: SIP is off there, so the locationd restart
and the write into the Firefox bundle were not tested under SIP; Location Services ship
off on the runner and are turned on first; the config file that `setup.sh` would write is
created with placeholder server values so that `harden` stores the zone and region.

## Not yet verified

- `oneexit init` steps 4-6 (client setup, hardening, leak test as one flow) against a
  reachable server: the hardening and the bootstrap have run for real on a macOS runner,
  the server half of `init` against a container, but the whole flow has not been run in
  one piece, and `setup.sh` has not been run on macOS since the v0.1.1 VM run.

- A physical Mac booted from an external SSD (Apple silicon or Intel): boot timing on real
  hardware, Wi-Fi association, sleep and wake, a real captive portal.
- A real VPS at a hosting provider (the server has only run in CI runners and containers).
- Long sessions: days of uptime, macOS updates while installed.
