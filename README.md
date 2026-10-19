# BrightSync

A small macOS menu bar app that keeps the brightness of your external monitors
in step: pick one display as the source, and the others follow it over DDC/CI.

Useful when one monitor changes brightness on its own or by itself — an ambient
light sensor doing its thing, or the keyboard brightness keys only reaching one
screen — and you want the rest of the desk to match.

- One source display, any number of followers
- Optionally mirrors the color preset (color temperature) as well
- The source can be any connected display, not just the main one
- Checks every 2–60 seconds (your choice)
- Proportional, not literal: a panel whose range is 0–80 is set to the same
  *percentage*, not the same raw number
- No Dock icon, no permissions of any kind, one small binary

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Displays reachable over DDC/CI. DisplayPort, USB-C and Thunderbolt are the
  reliable paths. Over a Mac's built-in HDMI port, DDC *reads* fail on some
  Mac and monitor combinations even though writes succeed — if a display shows
  as `unreadable`, try connecting it over USB-C/Thunderbolt instead.

## Install

```sh
brew tap m-torun/tap
brew install --cask brightsync
```

BrightSync is signed ad hoc rather than with an Apple Developer ID, so macOS
blocks the first launch. Open it once with `open /Applications/BrightSync.app`,
then allow it under System Settings → Privacy & Security → **Open Anyway**.

Or [download the latest release](https://github.com/m-torun/brightsync/releases/latest)
and drag `BrightSync.app` to Applications.

### Building from source

No Xcode needed, just the Swift toolchain that ships with the Command Line
Tools:

```sh
./build.sh
cp -R BrightSync.app /Applications/
open /Applications/BrightSync.app
```

## Using it

A sun icon appears in the menu bar. Open it to choose the source display, set
the interval, pause syncing, or enable **Start at login**.

## Checking what it sees

```sh
/Applications/BrightSync.app/Contents/MacOS/BrightSync --list
```

```
STUDIO DISPLAY  id=1  brightness=72/100
  key: <EDID UUID>
ACME 27  id=2  brightness=58/100
  key: <EDID UUID>
```

Displays are remembered by EDID UUID, so your choice of source survives
reboots and reconnection, where display IDs do not.

## Color temperature

**Sync color temperature** in the menu is off by default. When on, BrightSync
also mirrors VCP `0x14` (select color preset) from the source.

This is best-effort by nature, and worth understanding before relying on it:

- A color preset is an *enumerated* value, so it is copied verbatim rather
  than scaled the way brightness is.
- Preset numbering is only nominally standard (`0x05` is 6500K, `0x08` is
  9300K, and so on). Vendors deviate, so the same number can mean different
  things on two monitors.
- Preset lists are often **sparse**. A display may ignore a value it does not
  implement, or silently substitute another one — in testing, one monitor
  accepted presets 5 and 8, ignored 4, and turned 6 into 1.

BrightSync therefore reads the value back after writing it. If the display
did not take it, that value is remembered as unsupported for that display and
is not written again, so an unsupported preset cannot cause an endless rewrite
loop. Reconnecting a display clears those memories.

Note that on some monitors each color preset carries its own brightness, so
changing the preset can change brightness too.

## How it works

Each tick, BrightSync reads VCP feature `0x10` (brightness) from the source,
converts it to a fraction of that display's maximum, and writes the equivalent
value to each other display. It writes only when a display is more than one
point away from the target value, so a panel is not rewritten constantly —
monitors persist brightness to internal storage, and that storage has a finite
number of write cycles.

All DDC traffic runs on a background queue; a single read takes roughly 150 ms.

## Settings and privacy

Settings are stored in your own `UserDefaults` under
`app.brightsync.BrightSync` (source display, interval, enabled, deadband,
color temperature syncing).
Nothing is written into this repository, and the app makes no network requests.

## Notes and limits

- A monitor's own auto-brightness feature keeps adjusting the panel. That is
  fine, and is in fact a nice way to use this: make that monitor the source and
  the others will follow its sensor.
- A monitor's auto-brightness switch is usually *not* a DDC feature. On Dell
  UltraSharps, for example, it is controlled over USB HID by Dell Display and
  Peripheral Manager, so BrightSync cannot turn it on or off — use the vendor's
  app or the monitor's own menu for that.
- When a display disappears — switched to another computer by a KVM, or
  unplugged — BrightSync notices and resumes when it comes back.

## Log

`~/Library/Logs/BrightSync.log` (**Reveal log in Finder** in the menu) records
what was read and written, which is the only way to tell a quietly ignored DDC
write from one that took.

## Credits

- Display matching over the IORegistry comes from
  [m1ddc](https://github.com/waydabber/m1ddc) by waydabber (MIT, see
  `LICENSE-m1ddc`); `Sources/DDCKit/ioregistry.m` is kept verbatim from it.
- The DDC reply framing — reading the reply at I2C offset 0 as 11 bytes and
  validating header and checksum — follows
  [MonitorControl](https://github.com/MonitorControl/MonitorControl)'s
  `Arm64DDC` (MIT), which is what works on displays whose replies are
  otherwise unreadable.

MIT licensed.
