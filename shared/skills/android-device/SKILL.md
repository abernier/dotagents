---
name: android-device
description: Install or update an APK on an Android phone, and reach the phone with adb. Use when installing a build on a phone; when connecting adb over the network (wireless debugging, Tailscale); or when a phone shows `offline` or `unauthorized` in `adb devices`.
---

# Android device

`adb-tailnet`, in this skill's `bin/`, finds a phone's wireless debugging port
over Tailscale and connects to it; `adb-tailnet --help` and its header comment
are the reference.

## Install a build

1. **Find the phone.** Discover it at run time, every time: `adb devices -l`
   lists what adb already reaches (USB or network), and `tailscale status`
   lists the tailnet, a phone being a row with OS `android`. The tailnet name
   or address is the phone's stable address. On macOS the Tailscale CLI may
   exist only as `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
2. **Connect.** Over USB the phone is already listed. Over the network, run
   `adb-tailnet connect <tailnet name or address>`: it prints the serial
   (`<address>:<port>`) to pass as `adb -s`. Wireless debugging changes port
   every time it is turned on, and the script finds the port. What its
   failures mean: "Reach the phone" below.
3. **Check freshness.** Right before installing a build of a branch, fetch
   the branch and compare its tip to the commit the APK was built from;
   rebuild when the tip moved.
4. **Check the installed app.** `adb -s <serial> shell dumpsys package <id>`
   shows whether the app is there, its version and its signing. A debug
   build cannot update over a release-signed app: the install fails on a
   signature mismatch. Uninstalling wipes the app's data, so ask the user
   before uninstalling.
5. **Install.** `adb -s <serial> install -r <apk>`: an update keeps the app's
   data. Done when `dumpsys package <id>` shows a `lastUpdateTime` from just
   now. Report the commit installed.

## Reach the phone

**Wi-Fi.** Wireless debugging runs only while the phone is on Wi-Fi; on
cellular its screen says "Unavailable (not allowed)". Any Wi-Fi works, a
tether included, and then the phone listens on its Tailscale address too.

**`offline` right after connecting** means this computer is not paired with
the phone. Confirm with `ADB_TRACE=all`: the adb server log,
`$TMPDIR/adb.$(id -u).log`, shows `SSLV3_ALERT_CERTIFICATE_UNKNOWN`.

**Pairing** needs the user, once per computer: pairing persists, and next time
connecting is enough.

1. Ask the user to open Wireless debugging, then "Pair device with pairing
   code", and to keep that dialog open; ask for the IP:port and the 6-digit
   code it shows.
2. Run `adb pair <IP:port> <code>`, then connect again.
3. Over Tailscale, `adb pair` can fail with `protocol fault (couldn't read
   status message)` several times, then succeed. Retry with a fresh code,
   on the tailnet IPv4 and IPv6 addresses (`tailscale ip <name>`), before
   calling pairing impossible.

**`unauthorized`** over USB: the user unlocks the phone and accepts the USB
debugging prompt, with "Always allow" ticked.

## Getting an APK there without adb

Prefer adb: it installs even where opening an APK on the phone is blocked
(Android Advanced Protection shows "Managed by Advanced Protection"). When adb
is out of reach, serve the APK over HTTP bound to this machine's Tailscale
address (`tailscale ip -4`) and open that URL on the phone. Chat upload tools
cap file size around 30 MB, and Taildrop to Android can hang awaiting
acceptance.
