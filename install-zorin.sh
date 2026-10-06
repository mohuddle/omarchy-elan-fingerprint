#!/usr/bin/env bash
# Elan 04f3:0c4b fingerprint reader on Ubuntu 22.04, Ubuntu 24.04, and Zorin OS.
#
# One file is enough. From your normal user account:
#   chmod +x install-zorin.sh
#   ./install-zorin.sh
#
# The script installs Ubuntu's TOD host, the Lenovo Elan module from
# ppa:libfprint-tod1-group/ppa, then the autosuspend rule and resume hook.
# It does not enroll a finger. Zorin 17 follows jammy; Zorin 18 follows noble.

set -euo pipefail

log() { printf '>> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

[[ -r /etc/os-release ]] || die "/etc/os-release is missing"
# shellcheck disable=SC1091
. /etc/os-release

codename="${UBUNTU_CODENAME:-}"
if [[ -z "$codename" ]]; then
  case "${VERSION_CODENAME:-}" in
    jammy|noble) codename="${VERSION_CODENAME}" ;;
  esac
fi
case "$codename" in
  jammy|noble) ;;
  *)
    die "Need Ubuntu 22.04 (jammy) or 24.04 (noble). This is ${PRETTY_NAME:-unknown} (VERSION_CODENAME=${VERSION_CODENAME:-none}, UBUNTU_CODENAME=${UBUNTU_CODENAME:-none})."
    ;;
esac

command -v apt-get >/dev/null || die "apt-get is required"

export DEBIAN_FRONTEND=noninteractive
key_id="9C091A0C4927FF4DD696F0D4026499DF7CF44261"
keyring="/etc/apt/keyrings/libfprint-tod1-group.gpg"
list="/etc/apt/sources.list.d/libfprint-tod1-group.list"
rule_path="/etc/udev/rules.d/99-elan-fingerprint.rules"
hook_path="/usr/lib/systemd/system-sleep/elan-fingerprint"

log "Elan 04f3:0c4b installer for Ubuntu 22.04/24.04 and Zorin"
log "Ubuntu series: ${codename} (${PRETTY_NAME:-unknown})"
log "Installing fprintd, the TOD host, curl, and gnupg"
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  fprintd \
  gnupg \
  libfprint-2-2 \
  libfprint-2-tod1 \
  libpam-fprintd \
  usbutils

if ! lsusb -d 04f3:0c4b >/dev/null 2>&1; then
  log "04f3:0c4b is not on the USB bus. Install continues; enable the reader in the BIOS if enroll finds no device."
fi

log "Adding the Elan driver archive for ${codename}"
install -d -m 0755 /etc/apt/keyrings
key_tmp="$(mktemp)"
trap 'rm -f "$key_tmp"' EXIT
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${key_id}&options=mr" -o "$key_tmp"
got="$(gpg --show-keys --with-colons "$key_tmp" | awk -F: '/^fpr:/ { print $10; exit }')"
[[ "$got" == "$key_id" ]] || die "PPA signing key fingerprint was ${got:-missing}"
gpg --batch --yes --dearmor -o "$keyring" "$key_tmp"
chmod 0644 "$keyring"

cat >"$list" <<EOF
deb [signed-by=${keyring}] https://ppa.launchpadcontent.net/libfprint-tod1-group/ppa/ubuntu ${codename} main
EOF

apt-get update
apt-get install -y libfprint-2-tod1-elan

shopt -s nullglob
modules=(/usr/lib/*/libfprint-2/tod-1/libfprint-2-tod1-elan*.so)
(( ${#modules[@]} > 0 )) || die "libfprint-2-tod1-elan installed, but no module was found under /usr/lib"
log "Elan module: ${modules[0]}"

log "Installing the autosuspend rule and the resume hook"
cat >"$rule_path" <<'EOF'
# ELAN 04f3:0c4b: USB autosuspend leaves the TOD reader asleep after
# idle/screensaver, and fprintd cannot wake it for lock-screen verify.
# The packaged driver rule (60-libfprint-2-tod1-elan.rules) sets
# power/control=auto. This file is named 99- so it wins on add and change.
SUBSYSTEM=="usb", ATTR{idVendor}=="04f3", ATTR{idProduct}=="0c4b", TEST=="power/control", ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF
chmod 0644 "$rule_path"

cat >"$hook_path" <<'EOF'
#!/bin/bash
# After suspend the ELAN TOD reader re-enumerates (ID_PERSIST=0) while
# fprintd still holds the old USB claim. Restart the daemon once the
# device is back, and keep USB runtime PM off.
if [[ $1 != post ]]; then
  exit 0
fi

waited=0
while ! lsusb -d 04f3:0c4b >/dev/null 2>&1; do
  if (( waited >= 10 )); then
    logger -t elan-fingerprint "reader did not reappear after resume"
    exit 0
  fi
  sleep 0.5
  waited=$((waited + 1))
done

for d in /sys/bus/usb/devices/*; do
  if [[ -f $d/idVendor && $(<"$d/idVendor") == 04f3 && -f $d/idProduct && $(<"$d/idProduct") == 0c4b ]]; then
    echo on >"$d/power/control" 2>/dev/null || true
    echo -1 >"$d/power/autosuspend" 2>/dev/null || true
  fi
done

systemctl restart fprintd.service >/dev/null 2>&1 || true
logger -t elan-fingerprint "reset reader after resume"
EOF
chmod 0755 "$hook_path"

udevadm control --reload
udevadm trigger -s usb --attr-match=idVendor=04f3 --attr-match=idProduct=0c4b || true
systemctl restart fprintd.service || true

if [[ -f /usr/share/pam-configs/fprintd ]]; then
  pam-auth-update --enable fprintd
fi

awake=""
for d in /sys/bus/usb/devices/*; do
  if [[ -f $d/idVendor && $(<"$d/idVendor") == 04f3 && -f $d/idProduct && $(<"$d/idProduct") == 0c4b && -f $d/power/control ]]; then
    awake="$(<"$d/power/control")"
    log "Reader power/control is ${awake} (${d})"
  fi
done
if [[ -n "$awake" && "$awake" != on ]]; then
  die "Reader power/control is ${awake}. The 99- udev rule did not override autosuspend."
fi

cat <<'EOF'

Installed. Enroll as your normal user, with a tap rather than a hold:

  fprintd-enroll
  fprintd-verify

GNOME can also enroll under Settings, Users, Fingerprint Login.
Prints from the other Linux install are not reused.

Wake the screen before tapping. A long verify makes this sensor shut
itself off until it cools. If a tap then does nothing:

  sudo systemctl restart fprintd
EOF
