# BrightSync

A small macOS menu bar app that keeps the brightness of your external monitors
in step: pick one display as the source, and the others follow it over DDC/CI.

Useful when one monitor changes brightness on its own or by itself — an ambient
light sensor doing its thing, or the keyboard brightness keys only reaching one
screen — and you want the rest of the desk to match.

- One source display, any number of followers
- Optionally mirrors the color preset (color temperature) as well
- The source can be any connected display, not just the main one
- Checks every 10 seconds to 2 minutes (your choice; 30 seconds by default)
- Stays off the display bus while displays sleep, wake or change (see
  [Staying out of the way](#staying-out-of-the-way))
- Proportional, not literal: a panel whose range is 0–80 is set to the same
  *percentage*, not the same raw number
- No Dock icon, no permissions of any kind, one small binary

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Displays reachable over DDC/CI. DisplayPort, USB-C and Thunderbolt are the
  reliable paths. Over a Mac's built-in HDMI port, DDC *reads* fail on some
  Mac and monitor combinations even though writes succeed — if a display shows
  as `unreadable`, try connecting it over USB-C/Thunderbolt instead. BrightSync
  backs off from a display it cannot read, so an unreadable display costs a
  read every half hour at most, not one per round.

## Install

Build it from source. No Xcode needed, just the Swift toolchain that ships
with the Command Line Tools (`xcode-select --install`):

```sh
git clone https://github.com/m-torun/brightsync.git
cd brightsync
./build.sh
cp -R BrightSync.app /Applications/
open /Applications/BrightSync.app
```

An app built on your own Mac opens without any Gatekeeper prompt.

The [latest release](https://github.com/m-torun/brightsync/releases/latest)
has the same app prebuilt. It is signed ad hoc rather than with an Apple
Developer ID and is not notarized, so macOS refuses to open it, saying it
cannot verify that the app is free of malware. If you would rather not build,
allow it once under System Settings → Privacy & Security → **Open Anyway**.

## Using it

A sun icon appears in the menu bar. Open it to choose the source display, set
the interval, pause syncing, or enable **Start at login**.

The first line of the menu says when BrightSync is holding off, for example
`Paused: displays asleep` or `Waiting for displays to settle (42 s)`. It waits
a minute after launch before talking to any display.

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

Each round, BrightSync reads VCP feature `0x10` (brightness) from the source,
converts it to a fraction of that display's maximum, and writes the equivalent
value to each other display. The other displays are read once, after they
appear and settle, to learn their range; after that they are only written to,
and only when the value moves by more than one point. Monitors persist
brightness to internal storage, which has a finite number of write cycles.

In a steady state that is one DDC read per round (two with color sync on) and
no writes. With a single display, or with sync switched off, BrightSync sends
nothing at all.

All DDC traffic runs on a background queue; a single read takes roughly 100 ms.

## Staying out of the way

On Apple Silicon every DDC transaction goes through the display coprocessor
(DCP), the same firmware that handles display sleep, wake and mode changes.
DDC traffic at those moments has been linked to display hangs and system
freezes ([Lunar FAQ](https://lunar.fyi/faq#apply-wake),
[BetterDisplay discussion](https://github.com/waydabber/BetterDisplay/discussions/2622)).
So BrightSync holds off:

- **While the displays or the Mac sleep**, or another user's session is
  active. No timer runs at all while held.
- **Around any display change.** macOS calls BrightSync before and after every
  reconfiguration (plugging, unplugging, mode changes, the reconnects some
  monitors go through on wake). Each one restarts a 60-second quiet period,
  and nothing is sent until it ends. The same quiet period follows wake and
  launch.
- **Mid-round.** The checks run before every single transaction, so an event
  that arrives during a round stops the rest of it.
- **For a display macOS reports as asleep or offline**, even when the others
  are awake.
- **After a failure.** Nothing is retried on the spot. That display is left
  alone for twice the interval, then four times, up to half an hour; a
  successful transaction or **Sync now** resets it.

macOS cannot announce a monitor that drops off by itself (a cable pulled
mid-transaction, say), so a transaction already under way can still meet one.

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
  unplugged — BrightSync notices and resumes a minute after it comes back.

## Log

`~/Library/Logs/BrightSync.log` (**Reveal log in Finder** in the menu) records
every DDC transaction (display, VCP code, read or write, result and how long
it took) and every sleep, wake and display change BrightSync saw. That is the
only way to tell a quietly ignored DDC write from one that took, and it shows
what was last sent if a display ever hangs. Past 1 MB the file moves to
`BrightSync.log.1`.

```
2026-10-21T21:14:03Z  event: displays woke
2026-10-21T21:15:03Z  displays settled: STUDIO DISPLAY, ACME 27
2026-10-21T21:15:03Z  ddc read  STUDIO DISPLAY 0x10 → 61/100 (98 ms)
2026-10-21T21:15:03Z  ddc read  ACME 27 0x10 → 40/100 (97 ms)
2026-10-21T21:15:03Z  ddc write ACME 27 0x10 = 61 → sent (23 ms)
```

## Tests

```sh
./test.sh
```

The tests drive the sync engine against a fake set of displays and a fake
clock, and check the exact DDC transactions sent: none before the launch quiet
period ends, none while displays sleep, one read per round in a steady state,
backing off after failures, and so on.

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
