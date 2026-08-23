# ELAN fingerprint reader on Omarchy Quattro

Notes from getting an **Elan `04f3:0c4b`** reader working on [Omarchy](https://omarchy.org/) Linux **Quattro** (4.0). Stock `libfprint` does not drive this chip. After the TOD driver was in place, screensaver and sleep still left the reader dead on the lock screen.

I worked through both layers with [Grok](https://x.ai/grok) in the Omarchy terminal: first the driver/PAM stack, then why a tap did nothing after the panel went black.

This is a field note, not an Omarchy support document. It is written for the same USB id (`04f3:0c4b`). Other Elan readers need different modules.

## Hardware

```
lsusb | grep -i elan
# Bus 003 Device 004: ID 04f3:0c4b Elan Microelectronics Corp. ELAN:Fingerprint
```

Use: **tap, don’t hold.** If the sensor is left in a verify-wait, firmware disables it with `Device disabled to prevent overheating`.

Packages that actually talk to this chip (as of Omarchy 4.0.0, 2026-08-23):

| Package | Role |
| --- | --- |
| `libfprint-tod` (AUR) | Replaces stock `libfprint` with the Touch OEM Driver host |
| `libfprint-2-tod1-elan` (AUR) | Lenovo E14/E15 Gen 4 proprietary module |
| `openssl-1.1` | The `.so` needs `libcrypto.so.1.1` |
| `fprintd` | D-Bus daemon + PAM |

The module lands at `/usr/lib/libfprint-2/tod-1/libfprint-2-tod1-elan.so`. If openssl 1.1 is missing, fprintd logs that it cannot load that file.

## What was broken

1. **No driver.** `omarchy setup security fingerprint` installs stock `libfprint`. Calibration fails; the device never enrolls.
2. **USB autosuspend.** systemd-hwdb sets `ID_AUTOSUSPEND=1` and a 2s delay. After screensaver the chip stays asleep, so a tap does nothing.
3. **Stale claim after sleep.** The reader re-enumerates on resume (`ID_PERSIST=0`) while `fprintd` still holds the old USB claim. Later locks get `Device was already claimed`. A wedged daemon may ignore SIGTERM.
4. **Lock-screen retry storm.** Omarchy’s lock plugin retries fingerprint PAM every **250ms**. After overheat or a stuck claim that becomes a 4 Hz `Claim` flood, and the finger never gets the device. `fprintd-list` on every lock also claims the reader and races PAM.

Password still worked the whole time. The finger did not.

## 1. TOD driver and enroll

```bash
# Confirm the USB id first.
lsusb | grep -i elan

# AUR: replace stock libfprint with TOD + the Elan module + openssl 1.1.
# Example with yay; use your AUR helper.
yay -S libfprint-tod libfprint-2-tod1-elan openssl-1.1 fprintd
```

Enroll, then verify. This reader wants a **tap**:

```bash
fprintd-enroll
fprintd-verify
```

Then run Omarchy’s fingerprint setup so sudo, polkit, and the lock PAM service exist:

```bash
omarchy setup security fingerprint
```

If you already enrolled by hand, that command still wires PAM.

## 2. PAM: sudo, polkit, lock

Omarchy inserts `pam_fprintd.so` as sufficient on sudo and polkit, **after** a lid gate (`omarchy-hw-laptop-closed`) so a closed lid skips the reader instead of blocking until timeout.

Lock-screen fingerprint is `/etc/pam.d/omarchy-lock-fingerprint`. For this chip, shorten the listen window so the TOD firmware can cool. Copy the file from this repo:

```bash
sudo install -m 644 files/omarchy-lock-fingerprint /etc/pam.d/omarchy-lock-fingerprint
```

That is `pam_fprintd.so timeout=15 max-tries=1`. Password remains the fallback on the separate `omarchy-lock-password` stack.

## 3. Keep the reader awake (screensaver / idle)

```bash
sudo install -m 644 files/99-elan-fingerprint.rules /etc/udev/rules.d/99-elan-fingerprint.rules
sudo udevadm control --reload
sudo udevadm trigger -s usb --attr-match=idVendor=04f3 --attr-match=idProduct=0c4b
```

Check:

```bash
# Adjust the sysfs path if lsusb bus/port differs.
cat /sys/bus/usb/devices/*/idVendor
# For the 04f3 device:
cat /sys/bus/usb/devices/<that-dir>/power/control
# should print: on
```

The rule sets `power/control=on` and `power/autosuspend=-1` so idle does not USB-sleep the chip.

## 4. Recover after real sleep / suspend

```bash
sudo install -m 755 files/elan-fingerprint /usr/lib/systemd/system-sleep/elan-fingerprint
```

On resume (`post`) the hook waits until `lsusb -d 04f3:0c4b` sees the device, forces USB runtime PM off, and restarts `fprintd`.

## 5. Stop the lock-screen claim storm

Do not edit `/usr/share/omarchy/` — Omarchy updates overwrite it. Clone the lock plugin, then patch the clone:

```bash
omarchy plugin clone omarchy.lock
# → ~/.config/omarchy/plugins/$USER.lock  (here: anon.lock)
# omarchy.lock is disabled; the clone is enabled.
```

In `~/.config/omarchy/plugins/$USER.lock/Service.qml`:

**Skip `fprintd-list` on lock once a print is known enrolled.** Replace `refreshFingerprintStatus`:

```qml
  function refreshFingerprintStatus() {
    // fprintd-list claims the ELAN reader. On lock that races pam_fprintd
    // and leaves the device "already claimed", so skip the list once we
    // already know a print is enrolled.
    if (root.lockRequested && root.fingerprintConfigured) {
      root.startFingerprint()
      return
    }
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }
```

**Retry every 15s, not 250ms.** Find `fingerprintRetryTimer` and set:

```qml
    interval: 15000
```

Saving under `~/.config/omarchy/plugins/` reloads the shell. If it does not:

```bash
omarchy-shell shell rescanPlugins
```

## How to unlock

- Panel still up: **tap**.
- Screen black: **wake first** (Enter, a key, or the mouse), **then tap**.
- Full suspend: wake the panel, then tap. The sleep hook should already have reset the reader.

The lock listens for 15 seconds, rests 15 seconds, then listens again. Miss the window: wait, or type the password.

## If it wedges again

```bash
sudo systemctl restart fprintd
```

If stop hangs (the daemon ignored SIGTERM here and had to be killed):

```bash
sudo systemctl kill -s KILL fprintd
sudo systemctl start fprintd
```

Then:

```bash
fprintd-list "$USER"
journalctl -u fprintd --since '5 minutes ago'
```

Look for `already claimed` or `overheating`. A healthy verify starts without `efd_init return -1`:

```bash
timeout 5 fprintd-verify
# "Verify started!" is enough; Ctrl+C or the timeout is fine.
```

## Files in this repo

| Path | Installs to |
| --- | --- |
| [`files/99-elan-fingerprint.rules`](files/99-elan-fingerprint.rules) | `/etc/udev/rules.d/99-elan-fingerprint.rules` |
| [`files/elan-fingerprint`](files/elan-fingerprint) | `/usr/lib/systemd/system-sleep/elan-fingerprint` |
| [`files/omarchy-lock-fingerprint`](files/omarchy-lock-fingerprint) | `/etc/pam.d/omarchy-lock-fingerprint` |

The lock-plugin edits stay in your clone under `~/.config/omarchy/plugins/`. This repo does not ship Omarchy’s `Service.qml`.

## Credits

- Omarchy fingerprint setup and lid gate: [basecamp/omarchy](https://github.com/basecamp/omarchy)
- TOD host: [libfprint-tod](https://gitlab.freedesktop.org/3v1n0/libfprint)
- Elan module: AUR [`libfprint-2-tod1-elan`](https://aur.archlinux.org/packages/libfprint-2-tod1-elan) (Lenovo E14/E15 Gen 4 Linux driver)
- Working session: Grok on Omarchy Quattro, August 2026
