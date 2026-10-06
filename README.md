# Elan fingerprint reader `04f3:0c4b`

Stock `libfprint` does not drive this chip, so enrollment fails until a Touch OEM Driver (TOD) host and Lenovo's Elan module are installed. Idle and suspend can then leave the reader asleep or still claimed by `fprintd`. This repo covers both layers.

The USB id is the part that matters. Confirm it before installing:

```bash
lsusb | grep -i elan
# 04f3:0c4b Elan Microelectronics Corp. ELAN:Fingerprint
```

A different Elan id needs a different module. Stop here if `04f3:0c4b` is not what `lsusb` prints.

**Tap, do not hold.** If the sensor sits in a verify-wait, its firmware shuts it off and `fprintd` logs `Device disabled to prevent overheating`.

The Elan module is Lenovo's proprietary driver. This repo does not ship that `.so`. Ubuntu and Zorin install it from Launchpad. Arch installs it from the AUR. The scripts and the udev and sleep files here are MIT; see [LICENSE](LICENSE).

## Where this was used

- ThinkBook 13s G2 ITL, Zorin OS, October 2026. `install-zorin.sh` completed and the reader worked.
- The same laptop, Omarchy Quattro 4.0, August 2026. Driver, lock screen, and suspend.

The same USB id is on other Lenovo machines, including ThinkPad E14 and E15 Gen 4. Those machines were not part of this test. The packages match `04f3:0c4b`, not one product name.

## Ubuntu 22.04, Ubuntu 24.04, and Zorin

Zorin 17 is Ubuntu 22.04 (`jammy`). Zorin 18 is Ubuntu 24.04 (`noble`). [`install-zorin.sh`](install-zorin.sh) accepts either series, including plain Ubuntu. It refuses anything else.

Download that one file and run it from the account you enroll:

```bash
curl -fsSL -O https://raw.githubusercontent.com/mohuddle/omarchy-elan-fingerprint/master/install-zorin.sh
chmod +x install-zorin.sh
./install-zorin.sh
```

The script asks for your password through `sudo`. It then:

1. Installs `fprintd`, `libpam-fprintd`, `libfprint-2-2`, and `libfprint-2-tod1`.
2. Adds [ppa:libfprint-tod1-group/ppa](https://launchpad.net/~libfprint-tod1-group/+archive/ubuntu/ppa) and installs `libfprint-2-tod1-elan` (`0.1.0+2204` on jammy, `0.1.0+2404` on noble). This build links OpenSSL 3.
3. Enables the `fprintd` PAM profile, so login and sudo can use the reader.
4. Writes the autosuspend rule and the resume hook below.

The PPA package's own rule, `60-libfprint-2-tod1-elan.rules`, sets `power/control=auto`. That is the idle bug. The file this script writes is named `99-elan-fingerprint.rules` so it runs later and sets `power/control=on`.

Enroll after the script exits. Prints recorded on another Linux install are not reused.

```bash
fprintd-enroll
fprintd-verify
```

On GNOME, Settings, Users, Fingerprint Login enrolls the same way. A healthy verify logs `Verify started` and does not log `efd_init return -1`.

Wake the screen before you tap. A finger on the reader does not turn the panel back on. After a real suspend, the sleep hook waits until `04f3:0c4b` reappears, turns runtime power management back off, and restarts `fprintd`.

## If a tap does nothing

```bash
sudo systemctl restart fprintd
```

If stop hangs, the daemon has ignored SIGTERM:

```bash
sudo systemctl kill -s KILL fprintd
sudo systemctl start fprintd
```

Then:

```bash
fprintd-list "$USER"
journalctl -u fprintd --since '5 minutes ago'
```

`already claimed` means `fprintd` still holds a USB device that went away, usually across suspend. `overheating`, `efd_check_mean`, or `efd_init return -1` means the firmware disabled the sensor. Restart `fprintd`, wait a moment, and tap once.

```bash
timeout 5 fprintd-verify
```

`Verify started!` is enough. Ctrl+C or the timeout is fine.

Check that autosuspend lost. `on` is the working value:

```bash
for d in /sys/bus/usb/devices/*; do
  if [[ -f $d/idVendor && $(<"$d/idVendor") == 04f3 && $(<"$d/idProduct") == 0c4b ]]; then
    echo "$d $(<"$d/power/control")"
  fi
done
```

## Omarchy and Arch

Omarchy's `omarchy setup security fingerprint` installs stock `libfprint`. Calibration fails and the device never enrolls. The packages that talk to this chip on Omarchy 4.0.0 (August 2026) are:

| Package | Role |
| --- | --- |
| `libfprint-tod` (AUR) | Replaces stock `libfprint` with the TOD host |
| `libfprint-2-tod1-elan` (AUR) | Proprietary module. On Arch this copy needs `libcrypto.so.1.1` |
| `openssl-1.1` | Provides `libcrypto.so.1.1` for that module |
| `fprintd` | D-Bus daemon and PAM module |

```bash
lsusb | grep -i elan
yay -S libfprint-tod libfprint-2-tod1-elan openssl-1.1 fprintd
fprintd-enroll
fprintd-verify
omarchy setup security fingerprint
```

The module lands at `/usr/lib/libfprint-2/tod-1/libfprint-2-tod1-elan.so`. If OpenSSL 1.1 is missing, `fprintd` logs that it cannot load that file. `omarchy setup security fingerprint` still wires PAM when a print was enrolled by hand.

Four separate failures showed up after the driver was installed:

1. **No driver.** Stock `libfprint` cannot enroll `04f3:0c4b`.
2. **USB autosuspend.** After the screensaver the chip stays asleep, so a tap does nothing.
3. **Stale claim after sleep.** The reader re-enumerates on resume while `fprintd` still holds the old USB claim. Later locks get `Device was already claimed`.
4. **Lock-screen retry storm.** Omarchy's lock plugin retries fingerprint PAM every 250ms. After an overheat or a stuck claim, that becomes a claim flood, and the finger never gets the device. `fprintd-list` on every lock also claims the reader and races PAM.

Password still works through all of that.

### PAM

Omarchy inserts `pam_fprintd.so` as sufficient on sudo and polkit, after a lid gate, so a closed lid skips the reader. Lock-screen fingerprint is `/etc/pam.d/omarchy-lock-fingerprint`. Shorten the listen window so the firmware can cool:

```bash
sudo install -m 644 files/omarchy-lock-fingerprint /etc/pam.d/omarchy-lock-fingerprint
```

That is `pam_fprintd.so timeout=15 max-tries=1`. Password stays on the separate `omarchy-lock-password` stack.

### Keep the reader awake, and recover after suspend

```bash
sudo install -m 644 files/99-elan-fingerprint.rules /etc/udev/rules.d/99-elan-fingerprint.rules
sudo udevadm control --reload
sudo udevadm trigger -s usb --attr-match=idVendor=04f3 --attr-match=idProduct=0c4b
sudo install -m 755 files/elan-fingerprint /usr/lib/systemd/system-sleep/elan-fingerprint
```

The rule sets `power/control=on` and `power/autosuspend=-1`. On resume the hook waits until `lsusb -d 04f3:0c4b` sees the device, forces runtime power management off, and restarts `fprintd`. `power/control` for the `04f3` device should print `on`.

### Lock screen

Do not edit `/usr/share/omarchy/`. Omarchy updates overwrite it. Clone the lock plugin, then patch the clone:

```bash
omarchy plugin clone omarchy.lock
# ~/.config/omarchy/plugins/$USER.lock
```

In `Service.qml`:

Skip `fprintd-list` on lock once a print is known enrolled. Replace `refreshFingerprintStatus`:

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

Find `fingerprintRetryTimer` and set `interval: 15000`.

Pause verify while the panel is blank. The lock screen turns the panel off a few seconds after lock and otherwise leaves `pam_fprintd` armed. This chip then hits `Device disabled to prevent overheating`. Add `property bool fingerprintPaused: false`. Do not retry or start a verify while it is true. In `runBlank`, set the flag and stop the retry timers, and leave an in-flight verify alone. On wake (`runWake`, lid or screens change, panel back on), if it was paused, clear the flag and start a listen after about 600ms.

Saving under `~/.config/omarchy/plugins/` reloads the shell. If it does not:

```bash
omarchy-shell shell rescanPlugins
```

While the lock screen is visible, the reader listens for 15 seconds, rests 15 seconds, then listens again. After the panel blanks, listening stops so the firmware can cool. The next wake starts a fresh 15-second window. Miss it: nudge the mouse, or type the password. This repo does not ship Omarchy's `Service.qml`. The clone stays on your machine.

## Files

| Path | Installs to |
| --- | --- |
| [`install-zorin.sh`](install-zorin.sh) | Ubuntu 22.04, Ubuntu 24.04, and Zorin. Writes the next two rows |
| [`files/99-elan-fingerprint.rules`](files/99-elan-fingerprint.rules) | `/etc/udev/rules.d/99-elan-fingerprint.rules` |
| [`files/elan-fingerprint`](files/elan-fingerprint) | `/usr/lib/systemd/system-sleep/elan-fingerprint` |
| [`files/omarchy-lock-fingerprint`](files/omarchy-lock-fingerprint) | `/etc/pam.d/omarchy-lock-fingerprint` |

## Credits

- TOD host: [libfprint](https://gitlab.freedesktop.org/3v1n0/libfprint), Ubuntu package `libfprint-2-tod1`
- Elan module for Ubuntu and Zorin: [ppa:libfprint-tod1-group/ppa](https://launchpad.net/~libfprint-tod1-group/+archive/ubuntu/ppa), from Lenovo's Ubuntu driver for ThinkPad E14/E15 Gen 4
- Elan module for Arch: AUR [`libfprint-2-tod1-elan`](https://aur.archlinux.org/packages/libfprint-2-tod1-elan)
- Omarchy fingerprint setup: [basecamp/omarchy](https://github.com/basecamp/omarchy)
