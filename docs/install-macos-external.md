# Install macOS on an external SSD

This page gets you from an empty SSD to a Mac booted from it, ready for
`client/setup.sh`. Nothing here is specific to oneexit except the checklist at the end;
it is the standard macOS procedure, written down in one place.

Apple changes these screens between releases. If a label differs on your version, the
step is usually still there under a similar name.

## What you need

- **An SSD, not a flash drive.** Use an SSD in a USB 3.1 Gen 2 (10 Gb/s) or Thunderbolt
  enclosure, or a portable SSD with the same interface. macOS on a slow USB stick is
  painful to use and installs can fail. 256 GB is comfortable; macOS itself needs a few
  tens of GB.
- **A macOS installer that is not older than the Mac.** A Mac cannot start up from a
  macOS version older than the one it shipped with. Use the same major version as the
  Mac's internal disk or newer. oneexit needs macOS 13 Ventura or later.
- **A Mac you are allowed to set up.** On Apple silicon, an administrator of the Mac's
  internal disk has to authorize the external system (see below). On a borrowed or
  shared Mac, you need the owner for that step.
- **A network for the install.** The macOS installer downloads and verifies components
  during installation.

Find out which kind of Mac you have: Apple menu > About This Mac. "Chip: Apple M..." is
Apple silicon. "Processor: Intel" is Intel; to see whether it has a T2 chip, hold Option
and choose Apple menu > System Information, then look under Hardware > Controller (or
iBridge on older versions) for "Apple T2 Security Chip".

## 1. Erase the SSD

1. Connect the SSD and open Disk Utility (Applications > Utilities).
2. Choose View > Show All Devices, so you can select the physical device and not only
   a volume on it.
3. Select the SSD device (the top-level entry), click Erase and choose:
   - Name: anything, for example `oneexit`;
   - Format: APFS;
   - Scheme: GUID Partition Map.
4. Click Erase. Everything on the SSD is lost.

## 2. Allow the Mac to start up from the SSD

### Apple silicon

Nothing to change. On Apple silicon, booting from an external disk is allowed at the
default security level (Full Security), as long as the disk holds a macOS that Apple
signs.

What happens instead: when you install macOS on the external disk, the installer asks
you to select an administrator account of the internal disk and enter its password.
This authorizes the external system to start up on this Mac. If you later take the SSD
to a different Apple silicon Mac, expect macOS to ask for an administrator of that Mac
before it starts up from the SSD for the first time.

### Intel with a T2 chip

By default, T2 Macs refuse to start up from external media. Change that once:

1. Shut down. Turn the Mac on and immediately hold Command-R until the Apple logo
   appears, to start macOS Recovery.
2. Choose Utilities > Startup Security Utility from the menu bar and authenticate as an
   administrator.
3. Under External Boot, select **Allow booting from external or removable media**.
4. Secure Boot can stay at **Full Security**. Full Security accepts a current, signed
   macOS on an external disk; you only need a lower setting for old or unsigned systems.
5. Quit and restart.

### Intel without a T2 chip

Nothing to change. These Macs start up from any bootable external disk.

## 3. Install macOS onto the SSD

You do not need `createinstallmedia` or a bootable USB installer. Run the normal
installer and point it at the SSD.

1. On the Mac's current system, download the macOS installer: Software Update or the App
   Store page for the macOS version you want. The download lands in Applications as
   "Install macOS <name>". If it starts by itself, let it open; do not choose your
   internal disk.
2. Open the installer and continue through the licence.
3. At the disk selection step ("Select the disk where you want to install macOS"),
   choose the SSD. On some versions you have to click **Show All Disks** first.
4. On Apple silicon, select an administrator of the internal disk and enter its password
   when asked (see step 2).
5. The Mac restarts a few times. Leave the SSD connected the whole time. When it is
   done, it starts up into Setup Assistant on the SSD.

Alternative: install from macOS Recovery (on Apple silicon, hold the power button and
choose Options; on Intel, hold Command-R), choose Reinstall macOS and select the SSD.

## 4. Choose the SSD at startup

| Mac | How to pick the SSD |
|---|---|
| Apple silicon | Shut down. Press and hold the power button until "Loading startup options" appears. Select the SSD, then click Continue. |
| Intel (with or without T2) | Shut down. Turn the Mac on and immediately hold Option (Alt) until the Startup Manager appears. Select the SSD and press Return. |

In the startup options on Apple silicon you can hold Option when you click the disk
("Always Use") to make it the default. Leave the internal disk as the default on a Mac
that is not yours.

## 5. Setup Assistant: first-boot checklist

The point of this system is to be separate from your identity and from the host Mac.
Choose accordingly:

- [ ] **Apple ID: skip it.** Choose "Set Up Later" (or "Not Now") at the Apple ID step.
      If you sign in, accept that Apple, and every service that sees your Apple ID,
      knows this system is yours regardless of the IP address you use.
- [ ] **Local account:** create a new local account with a strong password that you do
      not use anywhere else.
- [ ] **Location Services: off.**
- [ ] **Analytics: off** (Share Mac Analytics and share crash data with app developers).
- [ ] **Siri: off.**
- [ ] **Screen Time: skip.**
- [ ] **FileVault: on.** If Setup Assistant offers it, accept; otherwise turn it on now
      in System Settings > Privacy & Security > FileVault, while booted from the SSD.
      Without FileVault, anyone who picks up the SSD can read everything on it. Store
      the recovery key somewhere other than the SSD.
- [ ] **Do not sign in to iCloud** later either, for the same reason as the Apple ID.
- [ ] **Software Update: later.** Install updates once oneexit is set up, so they come
      through the tunnel. You will need the network once more before that, for Homebrew
      and the repository (step 4 of the README).

After setup, also consider:

- System Settings > General > AirDrop & Handoff: turn Handoff off and set AirDrop to
  "No One". The firewall blocks AirDrop traffic anyway; this also stops the Mac from
  advertising itself over Bluetooth.
- System Settings > General > Sharing: leave every sharing service off.
- System Settings > Siri & Spotlight (or Spotlight on older versions): turn off
  suggestions that send queries to Apple.
- Use a separate browser profile for this system, with no synced account.

Now continue with step 2 of the [README](../README.md#install-in-5-steps) (the VPS) or,
if the server is ready, step 3.

## Going back to the internal disk

- **Once:** shut down and pick the internal disk at startup (hold the power button on
  Apple silicon, hold Option on Intel).
- **Permanently:** in the system you want to leave, open System Settings > General >
  Startup Disk, select the internal disk and click Restart.
- **Before you shut down on a network you do not trust,** turn Wi-Fi off. The firewall is
  loaded a few seconds after boot; with Wi-Fi off the next boot does not join a network
  before that happens. See [threat-model.md](threat-model.md).

## Trying oneexit in a virtual machine

`client/setup.sh` refuses to run when macOS is not on an external disk. A macOS virtual
machine (for example one made with UTM or tart on Apple silicon) looks internal to it:
`diskutil info /` reports `Device Location: Internal`, `Removable Media: Fixed` and an
empty `Protocol:` for the virtual disk. In a throwaway VM, run setup with
`--allow-internal-disk`; `oneexit doctor` then lists the boot volume as its one FAIL.

The kill switch blocks inbound connections too, so an SSH session into the VM stops
working once setup has run. Use the VM's own window, or the hypervisor's guest agent
(for example `tart exec`), which does not go through the network.
