# BrightSync

A small macOS menu bar app that keeps the brightness of your external monitors
in step: pick one display as the source, and the others follow it over DDC/CI.

Useful when one monitor changes brightness on its own or by itself — an ambient
light sensor doing its thing, or the keyboard brightness keys only reaching one
screen — and you want the rest of the desk to match.

- One source display, any number of followers
- The source can be any connected display, not just the main one
- Checks every 2–60 seconds (your choice)
- Proportional, not literal: a panel whose range is 0–80 is set to the same
  *percentage*, not the same raw number
- No Accessibility permission, no Dock icon, one small binary

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Displays reachable over DDC/CI. DisplayPort, USB-C and Thunderbolt are the
  reliable paths. Over a Mac's built-in HDMI port, DDC *reads* fail on some
  Mac and monitor combinations even though writes succeed — if a display shows
  as `unreadable`, try connecting it over USB-C/Thunderbolt instead.

## Build and install

No Xcode needed, just the Swift toolchain that ships with the Command Line
Tools:

```sh
./build.sh
cp -R BrightSync.app /Applications/
open /Applications/BrightSync.app
```

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
`app.brightsync.BrightSync` (source display, interval, enabled, deadband).
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
